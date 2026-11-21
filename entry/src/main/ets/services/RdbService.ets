/** Pure KLayout report database interchange. No picker, editor, native service or check execution.
 * Format sources: klayout.de/rdb_format.html; KLayout src/rdb/rdb/{rdb.cc,rdbFile.cc}.
 * Unknown XML/value content fails the whole operation; the caller retains the original report.
 * Resource limits fail explicitly and never truncate values, items or frame paths. */
import type { RdbPoint, RdbTransform, RdbTag, RdbTagRef, RdbCategory, RdbReference, RdbCell,
  RdbValue, RdbItem, RdbDocument, RdbLimits, RdbReadResult, RdbWriteResult, RdbValueResult,
  RdbFramePath, RdbFrameResult, RdbBounds, RdbBoundsResult, RdbViolationReport,
  RdbItemQuery, RdbQueryResult } from '../models/RdbData';

export function defaultRdbLimits(): RdbLimits {
  return { maximumCharacters: 16777216, maximumNodes: 500000, maximumDepth: 64,
    maximumItems: 100000, maximumValues: 1000000, maximumPoints: 2000000,
    maximumFramePaths: 4096, maximumWork: 50000000 };
}
const RDB_YIELD_CHAR_SLICE: number = 131072;
const RDB_YIELD_NODE_SLICE: number = 2048;
const RDB_YIELD_ITEM_SLICE: number = 512;
function yieldRdbSlice(): Promise<void> {
  return new Promise<void>((resolve: () => void) => { setTimeout(resolve, 0); });
}
function fail(message: string): never { throw new Error('RDB：' + message); }
function errorMessage(error: Error): string { return error.message.startsWith('RDB：')?error.message:'RDB：'+error.message; }
function finite(value: number, name: string): void {
  if (typeof value !== 'number' || !Number.isFinite(value)) fail(name + '必须为有限数');
}
function stringValue(value: string, name: string): void {
  if (typeof value !== 'string') fail(name + '必须为字符串');
  for (let i: number = 0; i < value.length; i++) {
    const c: number = value.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const next: number = value.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) fail(name + '含无配对 Unicode 代理项');
    } else if (c >= 0xdc00 && c <= 0xdfff) fail(name + '含无配对 Unicode 代理项');
  }
}
function xmlCharacter(code: number): boolean {
  return code === 9 || code === 10 || code === 13 || (code >= 32 && code <= 0xd7ff) ||
    (code >= 0xe000 && code <= 0xfffd) || (code >= 0x10000 && code <= 0x10ffff);
}
function unicode(code: number): string {
  if (code <= 0xffff) return String.fromCharCode(code);
  const n: number = code - 0x10000;
  return String.fromCharCode(0xd800 + (n >> 10), 0xdc00 + (n & 1023));
}
function xmlEscape(text: string): string {
  stringValue(text, 'XML 文本');
  for (let i: number = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff) { i++; continue; }
    if (!xmlCharacter(code)) fail('XML 元数据含非法控制字符');
  }
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\r/g, '&#13;');
}
function xmlDecode(text: string): string {
  let out: string = '';
  for (let i: number = 0; i < text.length; i++) {
    if (text.charAt(i) !== '&') { out += text.charAt(i); continue; }
    const end: number = text.indexOf(';', i + 1);
    if (end < 0) fail('未闭合 XML 实体');
    const entity: string = text.substring(i + 1, end);
    if (entity === 'amp') out += '&';
    else if (entity === 'lt') out += '<';
    else if (entity === 'gt') out += '>';
    else if (entity === 'apos') out += "'";
    else if (entity === 'quot') out += '"';
    else if (/^#(?:[0-9]+|x[0-9a-fA-F]+)$/.test(entity)) {
      const code: number = entity.charAt(1) === 'x' ? parseInt(entity.substring(2), 16) : parseInt(entity.substring(1), 10);
      if (!xmlCharacter(code)) fail('非法 XML 字符实体');
      out += unicode(code);
    } else fail('未知 XML 实体 &' + entity + ';，原报告未导入');
    i = end;
  }
  return out;
}
class Budget {
  limits: RdbLimits;
  nodes: number = 0;
  values: number = 0;
  points: number = 0;
  work: number = 0;
  constructor(limits?: RdbLimits) {
    this.limits = limits === undefined ? defaultRdbLimits() : limits;
    const l: RdbLimits = this.limits;
    for (const value of [l.maximumCharacters,l.maximumNodes,l.maximumDepth,l.maximumItems,l.maximumValues,
      l.maximumPoints,l.maximumFramePaths,l.maximumWork]) {
      if (!Number.isSafeInteger(value) || value <= 0) fail('资源预算必须为正安全整数');
    }
    if (l.maximumDepth > 128) fail('深度预算上限为 128');
  }
  spend(amount: number = 1): void { this.work += amount; if (this.work > this.limits.maximumWork) fail('超过工作预算，未发布部分报告'); }
  node(depth: number): void {
    this.spend(); if (++this.nodes > this.limits.maximumNodes || depth > this.limits.maximumDepth) fail('超过节点/深度预算');
  }
  value(): void { this.spend(); if (++this.values > this.limits.maximumValues) fail('超过标记值预算'); }
  point(): void { this.spend(); if (++this.points > this.limits.maximumPoints) fail('超过几何点预算'); }
  text(text: string): void { stringValue(text, '文本'); this.spend(text.length); if (text.length > this.limits.maximumCharacters) fail('超过文本预算'); }
}
interface XmlNode { name: string; text: string; children: XmlNode[]; }
interface XmlYieldState {
  count: number;
}

class XmlReader {
  private source: string;
  private position: number = 0;
  private budget: Budget;
  constructor(source: string, budget: Budget, skipPreEscape: boolean = false) {
    if (!skipPreEscape) budget.text(source);
    this.source = source.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
    this.budget = budget;
    // Validate XML code points before parsing; semantic string escapes are parsed later.
    if (!skipPreEscape) xmlEscape(this.source);
  }
  static async createAsync(source: string, budget: Budget): Promise<XmlReader> {
    if (typeof source !== 'string') fail('文本必须为字符串');
    if (source.length > budget.limits.maximumCharacters) fail('超过文本预算');
    budget.spend(source.length);
    for (let offset: number = 0; offset < source.length; offset += RDB_YIELD_CHAR_SLICE) {
      let end: number = Math.min(source.length, offset + RDB_YIELD_CHAR_SLICE);
      if (end < source.length) {
        const trailing: number = source.charCodeAt(end - 1);
        if (trailing >= 0xd800 && trailing <= 0xdbff) end++;
      }
      const slice: string = source.substring(offset, end);
      stringValue(slice, 'XML 文本');
      for (let i: number = 0; i < slice.length; i++) {
        const code: number = slice.charCodeAt(i);
        if (code >= 0xd800 && code <= 0xdbff) { i++; continue; }
        if (!xmlCharacter(code)) fail('XML 元数据含非法控制字符');
      }
      if (end < source.length) await yieldRdbSlice();
    }
    return new XmlReader(source, budget, true);
  }
  async readAsync(): Promise<XmlNode> {
    if (this.starts('<?xml')) {
      const end: number = this.source.indexOf('?>', this.position + 5);
      if (end < 0) fail('未闭合 XML 声明');
      const declaration: string = this.source.substring(this.position, end + 2);
      if (!/^<\?xml[ \t\n\r]+version[ \t\n\r]*=[ \t\n\r]*(['"])1\.0\1(?:[ \t\n\r]+encoding[ \t\n\r]*=[ \t\n\r]*(['"])(?:utf-8|UTF-8)\2)?(?:[ \t\n\r]+standalone[ \t\n\r]*=[ \t\n\r]*(['"])(?:yes|no)\3)?[ \t\n\r]*\?>$/.test(declaration)) fail('不支持的 XML 声明/编码或引号不匹配');
      this.position = end + 2;
    }
    this.decoration();
    const state: XmlYieldState = { count: 0 };
    const root: XmlNode = await this.elementAsync(1, state);
    this.decoration();
    if (this.position !== this.source.length) fail('根元素后存在未知 XML 内容');
    return root;
  }
  private async elementAsync(depth: number, state: XmlYieldState): Promise<XmlNode> {
    this.budget.node(depth);
    if (++state.count % RDB_YIELD_NODE_SLICE === 0) await yieldRdbSlice();
    if (!this.starts('<') || this.starts('<!') || this.starts('<?') || this.starts('</')) fail('未知 XML 声明/DTD/元素，原报告未导入');
    this.position++;
    const start: number = this.position;
    while (/[a-zA-Z0-9_-]/.test(this.source.charAt(this.position)) && this.position < this.source.length) this.position++;
    const name: string = this.source.substring(start, this.position);
    if (!/^[a-zA-Z][a-zA-Z0-9_-]*$/.test(name)) fail('非法/命名空间 XML 元素');
    this.whitespace();
    const node: XmlNode = { name: name, text: '', children: [] };
    if (this.starts('/>')) { this.position += 2; return node; }
    if (!this.starts('>')) fail('未知 XML 属性，原报告未导入：' + name);
    this.position++;
    while (this.position < this.source.length) {
      if (this.starts('</')) {
        this.position += 2; const closeStart: number = this.position;
        while (/[a-zA-Z0-9_-]/.test(this.source.charAt(this.position)) && this.position < this.source.length) this.position++;
        if (this.source.substring(closeStart, this.position) !== name) fail('XML 结束标签不匹配：' + name);
        this.whitespace(); if (!this.starts('>')) fail('非法 XML 结束标签'); this.position++; return node;
      }
      if (this.starts('<!--')) {
        const end: number = this.source.indexOf('-->', this.position + 4);
        if (end < 0 || this.source.substring(this.position + 4, end).indexOf('--') >= 0) fail('非法 XML 注释');
        this.position = end + 3;
      } else if (this.starts('<![CDATA[')) {
        const end: number = this.source.indexOf(']]>', this.position + 9);
        if (end < 0) fail('未闭合 CDATA'); node.text += this.source.substring(this.position + 9, end); this.position = end + 3;
      } else if (this.starts('<')) {
        node.children.push(await this.elementAsync(depth + 1, state));
      } else {
        const end: number = this.source.indexOf('<', this.position);
        if (end < 0) fail('未闭合 XML 元素：' + name);
        const raw: string = this.source.substring(this.position, end);
        if (raw.indexOf(']]>') >= 0) fail('文本中含非法 CDATA 结束串');
        node.text += xmlDecode(raw); this.position = end;
      }
    }
    fail('未闭合 XML 元素：' + name);
  }
  private starts(token: string): boolean { return this.source.substring(this.position,this.position+token.length) === token; }
  private whitespace(): void { while (/[ \t\n\r]/.test(this.source.charAt(this.position)) && this.position < this.source.length) this.position++; }
  private decoration(): void {
    this.whitespace();
    while (this.starts('<!--')) {
      const end: number = this.source.indexOf('-->',this.position+4);
      if (end < 0 || this.source.substring(this.position+4,end).indexOf('--') >= 0) fail('非法 XML 注释');
      this.position=end+3; this.whitespace();
    }
  }
  read(): XmlNode {
    // An XML declaration is legal only at the start (after an optional BOM).
    // Comments/whitespace may precede the root only when there is no declaration.
    if (this.starts('<?xml')) {
      const end: number = this.source.indexOf('?>',this.position+5);
      if (end < 0) fail('未闭合 XML 声明');
      const declaration: string = this.source.substring(this.position,end+2);
      if (!/^<\?xml[ \t\n\r]+version[ \t\n\r]*=[ \t\n\r]*(['"])1\.0\1(?:[ \t\n\r]+encoding[ \t\n\r]*=[ \t\n\r]*(['"])(?:utf-8|UTF-8)\2)?(?:[ \t\n\r]+standalone[ \t\n\r]*=[ \t\n\r]*(['"])(?:yes|no)\3)?[ \t\n\r]*\?>$/.test(declaration)) fail('不支持的 XML 声明/编码或引号不匹配');
      this.position=end+2;
    }
    this.decoration();
    const root: XmlNode = this.element(1); this.decoration();
    if (this.position !== this.source.length) fail('根元素后存在未知 XML 内容');
    return root;
  }
  private element(depth: number): XmlNode {
    this.budget.node(depth);
    if (!this.starts('<') || this.starts('<!') || this.starts('<?') || this.starts('</')) fail('未知 XML 声明/DTD/元素，原报告未导入');
    this.position++;
    const start: number = this.position;
    while (/[a-zA-Z0-9_-]/.test(this.source.charAt(this.position)) && this.position < this.source.length) this.position++;
    const name: string = this.source.substring(start,this.position);
    if (!/^[a-zA-Z][a-zA-Z0-9_-]*$/.test(name)) fail('非法/命名空间 XML 元素');
    this.whitespace();
    const node: XmlNode = { name:name, text:'', children:[] };
    if (this.starts('/>')) { this.position+=2; return node; }
    if (!this.starts('>')) fail('未知 XML 属性，原报告未导入：' + name);
    this.position++;
    while (this.position < this.source.length) {
      if (this.starts('</')) {
        this.position+=2; const closeStart: number=this.position;
        while (/[a-zA-Z0-9_-]/.test(this.source.charAt(this.position)) && this.position < this.source.length) this.position++;
        if (this.source.substring(closeStart,this.position)!==name) fail('XML 结束标签不匹配：'+name);
        this.whitespace(); if (!this.starts('>')) fail('非法 XML 结束标签'); this.position++; return node;
      }
      if (this.starts('<!--')) {
        const end: number=this.source.indexOf('-->',this.position+4);
        if (end<0 || this.source.substring(this.position+4,end).indexOf('--')>=0) fail('非法 XML 注释');
        this.position=end+3;
      } else if (this.starts('<![CDATA[')) {
        const end: number=this.source.indexOf(']]>',this.position+9);
        if (end<0) fail('未闭合 CDATA'); node.text+=this.source.substring(this.position+9,end); this.position=end+3;
      } else if (this.starts('<')) node.children.push(this.element(depth+1));
      else {
        const end: number=this.source.indexOf('<',this.position);
        if (end<0) fail('未闭合 XML 元素：'+name);
        const raw: string=this.source.substring(this.position,end);
        if (raw.indexOf(']]>')>=0) fail('文本中含非法 CDATA 结束串');
        node.text+=xmlDecode(raw); this.position=end;
      }
    }
    fail('未闭合 XML 元素：'+name);
  }
}
function structure(node: XmlNode, allowed: string[], repeated: boolean = false): void {
  if (!/^[ \t\n\r]*$/.test(node.text)) fail('元素 '+node.name+' 含未知混合文本');
  const seen: Set<string>=new Set<string>();
  for (const child of node.children) {
    if (allowed.indexOf(child.name)<0) fail('未知 XML 字段 '+node.name+'/'+child.name+'，原报告未导入');
    if (!repeated && seen.has(child.name)) fail('重复 XML 字段 '+node.name+'/'+child.name);
    seen.add(child.name);
  }
}
function child(node: XmlNode, name: string): XmlNode | undefined { return node.children.find((c: XmlNode): boolean=>c.name===name); }
function leaf(node: XmlNode): string { if (node.children.length>0) fail('文本字段 '+node.name+' 含未知元素'); return node.text; }
function field(node: XmlNode, name: string, fallback: string = ''): string { const c: XmlNode|undefined=child(node,name); return c===undefined?fallback:leaf(c); }
function booleanText(text: string): boolean { if(text.trim()==='true')return true;if(text.trim()==='false')return false;fail('非法布尔值：'+text); }

function utf8Bytes(text: string): number[] {
  stringValue(text,'字符串'); const bytes: number[]=[];
  for(let i: number=0;i<text.length;i++) {
    let c: number=text.charCodeAt(i);
    if(c>=0xd800&&c<=0xdbff)c=0x10000+((c-0xd800)<<10)+(text.charCodeAt(++i)-0xdc00);
    if(c<128)bytes.push(c);else if(c<2048)bytes.push(192|(c>>6),128|(c&63));
    else if(c<65536)bytes.push(224|(c>>12),128|((c>>6)&63),128|(c&63));
    else bytes.push(240|(c>>18),128|((c>>12)&63),128|((c>>6)&63),128|(c&63));
  }return bytes;
}
function fromUtf8(bytes: number[]): string {
  let out: string='';
  for(let i: number=0;i<bytes.length;i++) {
    const first: number=bytes[i];let c: number=first;let count: number=0;let minimum: number=0;
    if(first<128)count=0;else if(first>=194&&first<=223){c=first&31;count=1;minimum=128;}
    else if(first>=224&&first<=239){c=first&15;count=2;minimum=2048;}
    else if(first>=240&&first<=244){c=first&7;count=3;minimum=65536;}else fail('字符串转义含无效 UTF-8 字节');
    for(let j: number=0;j<count;j++){const b: number=bytes[++i];if(!(b>=128&&b<=191))fail('字符串转义含不完整 UTF-8');c=(c<<6)|(b&63);}
    if(c<minimum||c>0x10ffff||(c>=0xd800&&c<=0xdfff))fail('字符串转义含非法 Unicode');
    out+=unicode(c);
  }return out;
}
function quoted(text: string): string {
  let out: string="'";
  for(const b of utf8Bytes(text)) {
    if(b===39||b===92)out+='\\'+String.fromCharCode(b);
    else if(b===10)out+='\\n';else if(b===13)out+='\\r';else if(b===9)out+='\\t';
    else if(b<32||b>=127)out+='\\'+b.toString(8).padStart(3,'0');else out+=String.fromCharCode(b);
  }return out+"'";
}
class ValueReader {
  text: string;
  position: number=0;
  budget: Budget;
  constructor(text: string,budget: Budget){budget.text(text);this.text=text;this.budget=budget;}
  skip(): void{while(/\s/.test(this.text.charAt(this.position))&&this.position<this.text.length)this.position++;}
  test(token: string): boolean{this.skip();if(this.text.substring(this.position,this.position+token.length)!==token)return false;this.position+=token.length;return true;}
  expect(token: string): void{if(!this.test(token))fail('标记值缺少 '+token+'，位置 '+this.position);}
  end(): void{this.skip();if(this.position!==this.text.length)fail('未知/多余标记值内容：'+this.text.substring(this.position,this.position+40));}
  number(): number {
    this.skip();const match: RegExpMatchArray|null=this.text.substring(this.position).match(/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/);
    if(match===null)fail('缺少有限数值，位置 '+this.position);
    this.position+=match[0].length;const number: number=Number(match[0]);finite(number,'坐标/数值');return number;
  }
  word(): string {
    this.skip(); const q: string=this.text.charAt(this.position);
    if(q==="'"||q==='"') {
      this.position++;const bytes: number[]=[];
      while(this.position<this.text.length&&this.text.charAt(this.position)!==q) {
        const c: string=this.text.charAt(this.position++);
        if(c==='\\') {
          if(this.position>=this.text.length)fail('未闭合字符串转义');
          const escaped: string=this.text.charAt(this.position++);
          if(/[0-9]/.test(escaped)) {
            let byte: number=Number(escaped);let n: number=1;
            while(n<3&&/[0-9]/.test(this.text.charAt(this.position))&&this.position<this.text.length){byte=byte*8+Number(this.text.charAt(this.position++));n++;}
            bytes.push(byte&255);
          } else if(escaped==='n')bytes.push(10);else if(escaped==='r')bytes.push(13);else if(escaped==='t')bytes.push(9);
          else bytes.push(...utf8Bytes(escaped));
        } else if(c.charCodeAt(0)>=0xd800&&c.charCodeAt(0)<=0xdbff)bytes.push(...utf8Bytes(c+this.text.charAt(this.position++)));
        else bytes.push(...utf8Bytes(c));
      }
      if(this.text.charAt(this.position)!==q)fail('未闭合字符串引号');this.position++;return fromUtf8(bytes);
    }
    const start: number=this.position;
    while(/[a-zA-Z0-9_$]/.test(this.text.charAt(this.position))&&this.position<this.text.length)this.position++;
    if(start===this.position)fail('缺少标记名称/字符串');return this.text.substring(start,this.position);
  }
  point(): RdbPoint{this.budget.point();const x: number=this.number();this.expect(',');return{x:x,y:this.number()};}
  points(): RdbPoint[]{this.expect('(');const points: RdbPoint[]=[];
    while(!this.test(')')){points.push(this.point());this.test(';');}return points;}
  fixedEdgePoints(allowEmpty: boolean=false): RdbPoint[] {
    this.expect('(');if(allowEmpty&&this.test(')'))return[];
    const first:RdbPoint=this.point();this.expect(';');const second:RdbPoint=this.point();this.expect(')');return[first,second];
  }
  transform(simple: boolean=false): RdbTransform {
    const out: RdbTransform={rotationDeg:0,mirror:false,magnification:1,x:0,y:0};
    let rotation: boolean=false,scale: boolean=false,translation: boolean=false;
    while(true) {
      this.skip();const c: string=this.text.charAt(this.position);
      if(c==='r'||c==='m') {
        if(rotation)fail('重复旋转/镜像变换');rotation=true;this.position++;
        const angle: number=this.number();out.mirror=c==='m';out.rotationDeg=out.mirror?angle*2:angle;
      } else if(c==='*') {if(scale||simple)fail('标签不支持缩放或重复 MAG');scale=true;this.position++;out.magnification=this.number();}
      else if(/[0-9.+-]/.test(c)&&c!=='') {if(translation)fail('重复位移');translation=true;out.x=this.number();this.expect(',');out.y=this.number();}
      else break;
    }
    if(!rotation&&!scale&&!translation)fail('缺少变换');
    checkTransform(out,simple);return out;
  }
}
function checkTransform(t: RdbTransform,simple: boolean=false): void {
  if(t===null||typeof t!=='object')fail('变换为空');
  finite(t.rotationDeg,'变换角');finite(t.magnification,'MAG');finite(t.x,'位移 X');finite(t.y,'位移 Y');
  if(typeof t.mirror!=='boolean'||t.magnification<=0)fail('变换 mirror/MAG 非法');
  if(simple&&(t.magnification!==1||[0,90,180,270].indexOf(t.rotationDeg)<0))fail('DText 只支持 r0/r90/r180/r270 或 m0/m45/m90/m135 且 MAG=1');
}
function transformText(t: RdbTransform): string {checkTransform(t);return(t.mirror?'m'+(t.rotationDeg/2):'r'+t.rotationDeg)+' *'+t.magnification+' '+t.x+','+t.y;}
function pointText(p: RdbPoint): string{finite(p.x,'X');finite(p.y,'Y');return p.x+','+p.y;}
function pointsText(points: RdbPoint[]): string{return '('+points.map((p:RdbPoint):string=>pointText(p)).join(';')+')';}
function readTag(reader: ValueReader): RdbTagRef {const user: boolean=reader.test('#');return{name:reader.word(),user:user};}
function tagText(tag: RdbTagRef): string{if(typeof tag.user!=='boolean')fail('tag.user 必须为布尔值');return(tag.user?'#':'')+quoted(tag.name);}
function readValue(text: string,budget: Budget): RdbValue {
  budget.value();const r: ValueReader=new ValueReader(text,budget);let tag: RdbTagRef|undefined=undefined;
  if(r.test('[')){tag=readTag(r);r.expect(']');}
  const type: string=r.test('edge-pair')?'edge-pair':r.word();r.expect(':');let v: RdbValue;
  if(type==='text')v={kind:'text',text:r.word()};
  else if(type==='float') {
    r.skip();const rest: string=r.text.substring(r.position).trim();
    if(rest==='nan'||rest==='inf'||rest==='-inf'){v={kind:'float',specialNumber:rest as 'nan'|'inf'|'-inf'};r.position=r.text.length;}
    else v={kind:'float',number:r.number()};
  } else if(type==='box'||type==='edge')v={kind:type,points:r.fixedEdgePoints(type==='box')};
  else if(type==='edge-pair') {
    const first: RdbPoint[]=r.fixedEdgePoints();const symmetric: boolean=r.test('|');if(!symmetric)r.expect('/');
    v={kind:'edge-pair',points:first.concat(r.fixedEdgePoints()),symmetric:symmetric};
  } else if(type==='polygon') {
    r.expect('(');const contours: RdbPoint[][]=[[]];
    if(!r.test(')')) {
      while(true){contours[contours.length-1].push(r.point());r.test(';');if(r.test('/'))contours.push([]);else if(r.test(')'))break;}
    }
    v={kind:'polygon',points:contours[0],holes:contours.slice(1)};
  } else if(type==='path') {
    v={kind:'path',points:r.points(),width:0,beginExtension:0,endExtension:0,round:false};
    if(r.test('w=')){const signedWidth:number=r.number();v.width=Math.abs(signedWidth);v.round=signedWidth<0;}if(r.test('bx='))v.beginExtension=r.number();if(r.test('ex='))v.endExtension=r.number();
    if(r.test('r='))v.round=booleanText(r.word());
  } else if(type==='label') {
    r.expect('(');const textValue: string=r.word();r.expect(',');const t: RdbTransform=r.transform(true);r.expect(')');
    v={kind:'label',text:textValue,transform:t,size:0,font:-1,horizontalAlignment:'none',verticalAlignment:'none'};
    if(r.test('s='))v.size=r.number();if(r.test('f=')){
      const rawFont:number=r.number();
      // KLayout's reader accepts a signed int32 and stores Font in a signed
      // 26-bit bitfield. Text input follows that real canonicalization; typed
      // state must already be canonical to avoid silently wrapping on write.
      if(!Number.isInteger(rawFont)||rawFont< -2147483648||rawFont>2147483647)fail('text font 超过 KLayout signed int32 文本范围');
      v.font=(rawFont<<6)>>6;
    }
    if(r.test('ha=')){const a:string=r.word();if(a!=='l'&&a!=='c'&&a!=='r')fail('标签水平对齐非法');v.horizontalAlignment=a;}
    if(r.test('va=')){const a:string=r.word();if(a!=='b'&&a!=='c'&&a!=='t')fail('标签垂直对齐非法');v.verticalAlignment=a;}
  } else fail('未知 RDB 标记值类型 '+type+'，原报告未导入');
  if(tag!==undefined)v.tag=tag;r.end();return v;
}
function writeValue(v: RdbValue,includeTag:boolean=true): string {
  let text: string='';
  if(v.kind==='text')text='text: '+quoted(v.text!);
  else if(v.kind==='float')text='float: '+(v.specialNumber===undefined?String(v.number):v.specialNumber);
  else if(v.kind==='box'||v.kind==='edge')text=v.kind+': '+pointsText(v.points!);
  else if(v.kind==='edge-pair')text='edge-pair: '+pointsText(v.points!.slice(0,2))+(v.symmetric?'|':'/')+pointsText(v.points!.slice(2));
  else if(v.kind==='polygon')text='polygon: ('+[v.points!].concat(v.holes!).map((p:RdbPoint[]):string=>p.map((q:RdbPoint):string=>pointText(q)).join(';')).join('/')+')';
  else if(v.kind==='path')text='path: '+pointsText(v.points!)+' w='+v.width+' bx='+v.beginExtension+' ex='+v.endExtension+' r='+v.round;
  else if(v.kind==='label') {
    const t: RdbTransform=v.transform!;text='label: ('+quoted(v.text!)+','+(t.mirror?'m'+t.rotationDeg/2:'r'+t.rotationDeg)+' '+t.x+','+t.y+')';
    if(v.size!==0)text+=' s='+v.size;if(v.font!==-1)text+=' f='+v.font;
    if(v.horizontalAlignment!=='none')text+=' ha='+v.horizontalAlignment;if(v.verticalAlignment!=='none')text+=' va='+v.verticalAlignment;
  } else fail('未知标记值类型');
  return(!includeTag||v.tag===undefined?'':'['+tagText(v.tag)+'] ')+text;
}
export function rdbCellQName(cell: RdbCell): string {return cell.name+(cell.variant===''?'':':'+cell.variant);}
export function rdbCategoryPath(path: string[]): string {return path.map((name:string):string=>quoted(name)).join('.');}
function readCategoryPath(text: string,budget: Budget): string[] {
  const reader: ValueReader=new ValueReader(text,budget);const path:string[]=[];reader.skip();if(reader.position===text.length)return path;
  do{path.push(reader.word());}while(reader.test('.'));reader.end();return path;
}
function readTags(text: string,budget: Budget): RdbTagRef[] {
  const reader: ValueReader=new ValueReader(text,budget);const tags:RdbTagRef[]=[];reader.skip();if(reader.position===text.length)return tags;
  do{tags.push(readTag(reader));}while(reader.test(','));reader.end();return tags;
}
function categories(node: XmlNode|undefined,budget: Budget,depth: number=1): RdbCategory[] {
  if(node===undefined)return[];structure(node,['category'],true);const result:RdbCategory[]=[];
  for(const c of node.children){budget.spend();structure(c,['name','description','categories']);result.push({name:field(c,'name'),description:field(c,'description'),categories:categories(child(c,'categories'),budget,depth+1)});}
  return result;
}
function readDocument(root: XmlNode,budget: Budget): RdbDocument {
  if(root.name!=='report-database')fail('根元素必须为 report-database');
  structure(root,['description','original-file','generator','top-cell','tags','categories','cells','items']);
  const d:RdbDocument={schemaVersion:1,coordinateUnit:'um',description:field(root,'description'),originalFile:field(root,'original-file'),
    generator:field(root,'generator'),topCell:field(root,'top-cell'),tags:[],categories:categories(child(root,'categories'),budget),cells:[],items:[]};
  const tags:XmlNode|undefined=child(root,'tags');
  if(tags!==undefined){structure(tags,['tag'],true);for(const tag of tags.children){structure(tag,['name','description']);d.tags.push({name:field(tag,'name'),description:field(tag,'description')});}}
  const cells:XmlNode|undefined=child(root,'cells');
  if(cells!==undefined){structure(cells,['cell'],true);for(const cell of cells.children){
    structure(cell,['name','variant','layout-name','references']);const c:RdbCell={name:field(cell,'name'),variant:field(cell,'variant'),layoutName:field(cell,'layout-name'),references:[]};
    const refs:XmlNode|undefined=child(cell,'references');if(refs!==undefined){structure(refs,['ref'],true);for(const ref of refs.children){structure(ref,['parent','trans']);const r:ValueReader=new ValueReader(field(ref,'trans'),budget);const t:RdbTransform=r.transform();r.end();c.references.push({parentCell:field(ref,'parent'),transform:t});}}
    d.cells.push(c);
  }}
  const items:XmlNode|undefined=child(root,'items');
  if(items!==undefined){structure(items,['item'],true);if(items.children.length>budget.limits.maximumItems)fail('超过 item 预算');for(const item of items.children){
    structure(item,['tags','category','cell','visited','multiplicity','comment','image','values']);
    const multiplicityText:string=field(item,'multiplicity','1').trim();if(!/^\d+$/.test(multiplicityText))fail('multiplicity 必须为非负整数');
    const i:RdbItem={cell:field(item,'cell'),category:readCategoryPath(field(item,'category'),budget),tags:readTags(field(item,'tags'),budget),
      visited:booleanText(field(item,'visited','false')),multiplicity:Number(multiplicityText),comment:field(item,'comment'),image:field(item,'image'),values:[]};
    const values:XmlNode|undefined=child(item,'values');if(values!==undefined){structure(values,['value'],true);for(const value of values.children)i.values.push(readValue(leaf(value),budget));}
    d.items.push(i);
  }}return d;
}
function keys(value: Object, allowed: string[], name: string): void {
  for(const key of Object.keys(value))if(allowed.indexOf(key)<0)fail(name+' 含未知字段 '+key+'，原报告未发布');
}
function array(value: Object,name: string): void {if(!Array.isArray(value))fail(name+' 必须为数组');}
function checkTag(t:RdbTagRef,b:Budget):void {if(t===undefined||t===null)fail('tag 为空');keys(t,['name','user'],'tag');b.text(t.name);if(typeof t.user!=='boolean')fail('tag.user 非布尔');}
function checkValue(v:RdbValue,b:Budget):void {
  b.value();if(v===undefined||v===null)fail('标记值为空');
  let allowed:string[]=['kind','tag'];
  if(v.kind==='text')allowed=allowed.concat(['text']);else if(v.kind==='float')allowed=allowed.concat(['number','specialNumber']);
  else if(v.kind==='box'||v.kind==='edge')allowed=allowed.concat(['points']);else if(v.kind==='edge-pair')allowed=allowed.concat(['points','symmetric']);
  else if(v.kind==='polygon')allowed=allowed.concat(['points','holes']);else if(v.kind==='path')allowed=allowed.concat(['points','width','beginExtension','endExtension','round']);
  else if(v.kind==='label')allowed=allowed.concat(['text','transform','size','font','horizontalAlignment','verticalAlignment']);else fail('未知 RDB 标记值类型');
  keys(v,allowed,'标记值');if(v.tag!==undefined)checkTag(v.tag,b);
  if(v.kind==='text'||v.kind==='label')b.text(v.text!);
  if(v.kind==='float'){
    if(v.specialNumber!==undefined){if(v.number!==undefined||['nan','inf','-inf'].indexOf(v.specialNumber)<0)fail('浮点特殊值合同非法');}
    else finite(v.number!,'float');
  }
  if(v.kind==='box'||v.kind==='edge'||v.kind==='edge-pair'||v.kind==='polygon'||v.kind==='path'){
    array(v.points!,'points');let contours:RdbPoint[][]=[v.points!];
    if(v.kind==='box'&&v.points!.length!==0&&v.points!.length!==2)fail('box 必须为空或两角点');
    if(v.kind==='edge'&&v.points!.length!==2)fail('edge 必须含两端点');
    if(v.kind==='edge-pair'&&(v.points!.length!==4||typeof v.symmetric!=='boolean'))fail('edge-pair 必须含四端点和 symmetric');
    if(v.kind==='polygon'){array(v.holes!,'holes');contours=contours.concat(v.holes!);}
    for(const contour of contours){array(contour,'轮廓');for(const p of contour){b.point();keys(p,['x','y'],'point');finite(p.x,'X');finite(p.y,'Y');}}
  }
  if(v.kind==='path'){finite(v.width!,'path width');if(v.width!<0)fail('typed path width 必须为非负绝对宽度；有符号文本宽度由 parser 转换并保留 round');finite(v.beginExtension!,'begin extension');finite(v.endExtension!,'end extension');if(typeof v.round!=='boolean')fail('path round 非布尔');}
  if(v.kind==='label'){
    checkTransform(v.transform!,true);keys(v.transform!,['rotationDeg','mirror','magnification','x','y'],'transform');finite(v.size!,'text size');
    if(!Number.isInteger(v.font!)||v.font!< -33554432||v.font!>33554431)fail('typed text font 必须为 KLayout signed26 canonical 范围整数');
    if(['none','l','c','r'].indexOf(v.horizontalAlignment!)<0||['none','b','c','t'].indexOf(v.verticalAlignment!)<0)fail('text 对齐非法');
  }
}
/** Returns stable parent-before-child order for a KLayout-compatible XML write. */
function checkDocument(d:RdbDocument,b:Budget):RdbCell[] {
  if(d===null||d===undefined)fail('文档为空');keys(d,['schemaVersion','coordinateUnit','description','originalFile','generator','topCell','tags','categories','cells','items'],'document');
  if(d.schemaVersion!==1||d.coordinateUnit!=='um')fail('schemaVersion=1 且 coordinateUnit=um 为必需合同');
  for(const t of [d.description,d.originalFile,d.generator,d.topCell]){b.text(t);xmlEscape(t);}
  array(d.tags,'tags');for(const t of d.tags){b.node(1);keys(t,['name','description'],'tag declaration');b.text(t.name);b.text(t.description);xmlEscape(t.name);xmlEscape(t.description);}
  const categorySet:Set<string>=new Set<string>();
  const walk = (cs:RdbCategory[],prefix:string[],depth:number):void => {
    array(cs,'categories');const names:Set<string>=new Set<string>();
    for(const c of cs){b.node(depth);keys(c,['name','description','categories'],'category');b.text(c.name);b.text(c.description);xmlEscape(c.name);xmlEscape(c.description);
      if(names.has(c.name))fail('同级 category 名重复');names.add(c.name);const path:string[]=prefix.concat([c.name]);categorySet.add(rdbCategoryPath(path));walk(c.categories,path,depth+1);}
  };walk(d.categories,[],1);
  const cells:Map<string,RdbCell>=new Map<string,RdbCell>();array(d.cells,'cells');
  for(const c of d.cells){b.node(1);keys(c,['name','variant','layoutName','references'],'cell');for(const t of [c.name,c.variant,c.layoutName]){b.text(t);xmlEscape(t);}
    const name:string=rdbCellQName(c);if(cells.has(name))fail('重复/歧义 qualified cell：'+name);cells.set(name,c);array(c.references,'references');
    for(const ref of c.references){b.node(2);keys(ref,['parentCell','transform'],'reference');b.text(ref.parentCell);checkTransform(ref.transform);keys(ref.transform,['rotationDeg','mirror','magnification','x','y'],'transform');}
  }
  const sorted:RdbCell[]=[],active:Set<string>=new Set<string>(),depths:Map<string,number>=new Map<string,number>();
  const visit = (c:RdbCell,depth:number):void => {
    b.spend();if(depth>b.limits.maximumDepth)fail('cell reference 深度超预算');const name:string=rdbCellQName(c);
    if(depths.has(name))return;if(active.has(name))fail('cell reference 环无法写成 KLayout 父先序');active.add(name);
    let longest:number=1;
    for(const ref of c.references){const parent:RdbCell|undefined=cells.get(ref.parentCell);if(parent===undefined)fail('悬空 parent cell：'+ref.parentCell);visit(parent,depth+1);longest=Math.max(longest,1+depths.get(ref.parentCell)!);}
    if(longest>b.limits.maximumDepth)fail('cell reference 最长路径深度超预算');
    active.delete(name);depths.set(name,longest);sorted.push(c);
  };for(const c of d.cells)visit(c,1);
  array(d.items,'items');if(d.items.length>b.limits.maximumItems)fail('item 数量超预算');
  for(const item of d.items){b.node(1);keys(item,['cell','category','tags','visited','multiplicity','comment','image','values'],'item');b.text(item.cell);b.text(item.comment);b.text(item.image);
    if(!cells.has(item.cell))fail('悬空 item cell：'+item.cell);array(item.category,'item.category');for(const name of item.category)b.text(name);
    if(!categorySet.has(rdbCategoryPath(item.category)))fail('悬空 item category：'+rdbCategoryPath(item.category));
    if(typeof item.visited!=='boolean'||!Number.isSafeInteger(item.multiplicity)||item.multiplicity<0)fail('visited/multiplicity 非法或超过安全整数');
    array(item.tags,'item.tags');for(const tag of item.tags)checkTag(tag,b);
    // Image is preserved as opaque text; KLayout also stores it without validating the codec.
    xmlEscape(item.comment);xmlEscape(item.image);array(item.values,'values');for(const value of item.values)checkValue(value,b);
  }return sorted;
}
async function readDocumentAsync(root: XmlNode, budget: Budget): Promise<RdbDocument> {
  if (root.name !== 'report-database') fail('根元素必须为 report-database');
  structure(root, ['description', 'original-file', 'generator', 'top-cell', 'tags', 'categories', 'cells', 'items']);
  const d: RdbDocument = { schemaVersion: 1, coordinateUnit: 'um', description: field(root, 'description'), originalFile: field(root, 'original-file'),
    generator: field(root, 'generator'), topCell: field(root, 'top-cell'), tags: [], categories: categories(child(root, 'categories'), budget), cells: [], items: [] };
  const tags: XmlNode | undefined = child(root, 'tags');
  if (tags !== undefined) { structure(tags, ['tag'], true); for (const tag of tags.children) { structure(tag, ['name', 'description']); d.tags.push({ name: field(tag, 'name'), description: field(tag, 'description') }); } }
  const cells: XmlNode | undefined = child(root, 'cells');
  if (cells !== undefined) {
    structure(cells, ['cell'], true);
    for (let ci: number = 0; ci < cells.children.length; ci++) {
      const cell: XmlNode = cells.children[ci];
      structure(cell, ['name', 'variant', 'layout-name', 'references']);
      const c: RdbCell = { name: field(cell, 'name'), variant: field(cell, 'variant'), layoutName: field(cell, 'layout-name'), references: [] };
      const refs: XmlNode | undefined = child(cell, 'references');
      if (refs !== undefined) {
        structure(refs, ['ref'], true);
        for (const ref of refs.children) {
          structure(ref, ['parent', 'trans']);
          const r: ValueReader = new ValueReader(field(ref, 'trans'), budget);
          const t: RdbTransform = r.transform(); r.end();
          c.references.push({ parentCell: field(ref, 'parent'), transform: t });
        }
      }
      d.cells.push(c);
      if (ci > 0 && ci % RDB_YIELD_ITEM_SLICE === 0) await yieldRdbSlice();
    }
  }
  const items: XmlNode | undefined = child(root, 'items');
  if (items !== undefined) {
    structure(items, ['item'], true);
    if (items.children.length > budget.limits.maximumItems) fail('超过 item 预算');
    for (let ii: number = 0; ii < items.children.length; ii++) {
      const item: XmlNode = items.children[ii];
      structure(item, ['tags', 'category', 'cell', 'visited', 'multiplicity', 'comment', 'image', 'values']);
      const multiplicityText: string = field(item, 'multiplicity', '1').trim();
      if (!/^\d+$/.test(multiplicityText)) fail('multiplicity 必须为非负整数');
      const parsedItem: RdbItem = { cell: field(item, 'cell'), category: readCategoryPath(field(item, 'category'), budget), tags: readTags(field(item, 'tags'), budget),
        visited: booleanText(field(item, 'visited', 'false')), multiplicity: Number(multiplicityText), comment: field(item, 'comment'), image: field(item, 'image'), values: [] };
      const values: XmlNode | undefined = child(item, 'values');
      if (values !== undefined) { structure(values, ['value'], true); for (const value of values.children) parsedItem.values.push(readValue(leaf(value), budget)); }
      d.items.push(parsedItem);
      if (ii > 0 && ii % RDB_YIELD_ITEM_SLICE === 0) await yieldRdbSlice();
    }
  }
  return d;
}
export function parseRdb(xml:string,limits?:RdbLimits):RdbReadResult {
  try{const b:Budget=new Budget(limits);const d:RdbDocument=readDocument(new XmlReader(xml,b).read(),b);checkDocument(d,new Budget(limits));return{ok:true,message:'RDB 已完整解析；坐标为 μm，报告不代表检查通过'+tagDeclarationNotice(d),document:d};}
  catch(error){return{ok:false,message:errorMessage(error as Error)};}
}
/** 大体积 RDB 报告异步分片协作让步解析，避免百万级标记值同步阻塞 UI 线程 */
export async function parseRdbAsync(xml: string, limits?: RdbLimits): Promise<RdbReadResult> {
  try {
    const b: Budget = new Budget(limits);
    const reader: XmlReader = await XmlReader.createAsync(xml, b);
    const root: XmlNode = await reader.readAsync();
    await yieldRdbSlice();
    const d: RdbDocument = await readDocumentAsync(root, b);
    await yieldRdbSlice();
    checkDocument(d, new Budget(limits));
    return { ok: true, message: 'RDB 已完整解析；坐标为 μm，报告不代表检查通过' + tagDeclarationNotice(d), document: d };
  } catch (error) {
    return { ok: false, message: errorMessage(error as Error) };
  }
}
function tagDeclarationNotice(d:RdbDocument):string {
  const names:Set<string>=new Set<string>();
  for(const tag of d.tags){if(names.has(tag.name))return'；同名 tag 声明及描述按原顺序保留，KLayout XML 未记录声明的 system/user 身份，其重存可能覆盖同名描述';names.add(tag.name);}
  return'';
}
export function serializeRdb(d:RdbDocument,limits?:RdbLimits):RdbWriteResult {
  try {
    const b:Budget=new Budget(limits);const sorted:RdbCell[]=checkDocument(d,b);const lines:string[]=['<?xml version="1.0" encoding="utf-8"?>','<report-database>'];
    const line = (depth:number,name:string,text:string):void => {lines.push(' '.repeat(depth)+'<'+name+'>'+xmlEscape(text)+'</'+name+'>');};
    line(1,'description',d.description);line(1,'original-file',d.originalFile);line(1,'generator',d.generator);line(1,'top-cell',d.topCell);
    lines.push(' <tags>');for(const tag of d.tags){lines.push('  <tag>');line(3,'name',tag.name);line(3,'description',tag.description);lines.push('  </tag>');}lines.push(' </tags>');
    const cats = (cs:RdbCategory[],depth:number):void => {lines.push(' '.repeat(depth)+'<categories>');for(const c of cs){lines.push(' '.repeat(depth+1)+'<category>');line(depth+2,'name',c.name);line(depth+2,'description',c.description);cats(c.categories,depth+2);lines.push(' '.repeat(depth+1)+'</category>');}lines.push(' '.repeat(depth)+'</categories>');};
    cats(d.categories,1);lines.push(' <cells>');for(const c of sorted){lines.push('  <cell>');line(3,'name',c.name);line(3,'variant',c.variant);line(3,'layout-name',c.layoutName);lines.push('   <references>');
      for(const ref of c.references){lines.push('    <ref>');line(5,'parent',ref.parentCell);line(5,'trans',transformText(ref.transform));lines.push('    </ref>');}lines.push('   </references>','  </cell>');}lines.push(' </cells>',' <items>');
    for(const item of d.items){lines.push('  <item>');line(3,'tags',item.tags.map((t:RdbTagRef):string=>tagText(t)).join(','));line(3,'category',rdbCategoryPath(item.category));line(3,'cell',item.cell);
      line(3,'visited',String(item.visited));line(3,'multiplicity',String(item.multiplicity));line(3,'comment',item.comment);line(3,'image',item.image);lines.push('   <values>');
      for(const value of item.values)line(4,'value',writeValue(value));lines.push('   </values>','  </item>');}lines.push(' </items>','</report-database>');
    const xml:string=lines.join('\n')+'\n';if(xml.length>b.limits.maximumCharacters)fail('序列化文件超过字符预算');
    // Enforce the emitted XML node/depth budget as well as the typed-state budget.
    new XmlReader(xml,new Budget(limits)).read();
    return{ok:true,message:'KLayout RDB 已完整序列化'+tagDeclarationNotice(d),xml:xml};
  }catch(error){return{ok:false,message:errorMessage(error as Error)};}
}
export function parseRdbValue(text:string,limits?:RdbLimits):RdbValueResult {
  try{const b:Budget=new Budget(limits);const v:RdbValue=readValue(text,b);checkValue(v,new Budget(limits));return{ok:true,message:'标记值已解析',value:v};}
  catch(error){return{ok:false,message:errorMessage(error as Error)};}
}
export function serializeRdbValue(value:RdbValue,limits?:RdbLimits):RdbWriteResult {
  try{const b:Budget=new Budget(limits);checkValue(value,b);const text:string=writeValue(value);if(text.length>b.limits.maximumCharacters)fail('标记值超文本预算');return{ok:true,message:'标记值已序列化',xml:text};}
  catch(error){return{ok:false,message:errorMessage(error as Error)};}
}
export function rdbIdentityTransform():RdbTransform{return{rotationDeg:0,mirror:false,magnification:1,x:0,y:0};}
/** Human-readable message/scalar/label text. No UTF-8 octal escapes are exposed to the UI. */
export function rdbValueDisplay(value:RdbValue):string {
  checkValue(value,new Budget());let text:string;
  if(value.kind==='text')text=value.text!;
  else if(value.kind==='label')text=value.text!+' @ '+value.transform!.x+','+value.transform!.y+' μm';
  else text=writeValue(value,false);
  return(value.tag===undefined?'':value.tag.name+': ')+text;
}
export function rdbQueryItems(document:RdbDocument,query:RdbItemQuery,limits?:RdbLimits):RdbQueryResult {
  try{const b:Budget=new Budget(limits);checkDocument(document,b);keys(query,['category','includeDescendants','cell','tags','visited','text'],'query');
    if(query.category!==undefined){array(query.category,'query.category');for(const name of query.category)b.text(name);}
    if(query.includeDescendants!==undefined&&typeof query.includeDescendants!=='boolean')fail('includeDescendants 非布尔');
    if(query.cell!==undefined){b.text(query.cell);if(!document.cells.some((c:RdbCell):boolean=>rdbCellQName(c)===query.cell))fail('查询 cell 不存在');}
    if(query.tags!==undefined){array(query.tags,'query.tags');for(const tag of query.tags)checkTag(tag,b);}
    if(query.visited!==undefined&&typeof query.visited!=='boolean')fail('query.visited 非布尔');
    if(query.text!==undefined)b.text(query.text);
    const term:string=query.text===undefined?'':query.text.toLocaleLowerCase();const indices:number[]=[];
    for(let index:number=0;index<document.items.length;index++){
      b.spend();const item:RdbItem=document.items[index];
      if(query.cell!==undefined&&item.cell!==query.cell)continue;
      if(query.visited!==undefined&&item.visited!==query.visited)continue;
      if(query.category!==undefined){const prefix:string[]=query.category;
        if(item.category.length<prefix.length||(query.includeDescendants===false&&item.category.length!==prefix.length))continue;
        if(!prefix.every((name:string,i:number):boolean=>item.category[i]===name))continue;}
      if(query.tags!==undefined&&!query.tags.every((tag:RdbTagRef):boolean=>item.tags.some((t:RdbTagRef):boolean=>t.name===tag.name&&t.user===tag.user)))continue;
      if(term!==''){
        // Search semantic Unicode strings, not serializer escape sequences.
        const parts:string[]=[item.cell,item.comment,item.category.join('.'),...item.tags.map((t:RdbTagRef):string=>t.name)];
        for(const value of item.values){const display:string=rdbValueDisplay(value);b.text(display);parts.push(display);}
        if(parts.join('\n').toLocaleLowerCase().indexOf(term)<0)continue;
      }
      indices.push(index);
    }return{ok:true,message:'完整 item 筛选结果',indices:indices};
  }catch(error){return{ok:false,message:errorMessage(error as Error),indices:[]};}
}
export function rdbTransformPoint(p:RdbPoint,t:RdbTransform):RdbPoint {
  checkTransform(t);finite(p.x,'X');finite(p.y,'Y');const angle:number=(t.rotationDeg%360)*Math.PI/180,c:number=Math.cos(angle),s:number=Math.sin(angle),y:number=t.mirror?-p.y:p.y;
  const out:RdbPoint={x:t.magnification*(c*p.x-s*y)+t.x,y:t.magnification*(s*p.x+c*y)+t.y};finite(out.x,'变换 X');finite(out.y,'变换 Y');return out;
}
/** outer(inner(point)), including mirrored rotation sign. */
export function composeRdbTransforms(outer:RdbTransform,inner:RdbTransform):RdbTransform {
  checkTransform(outer);checkTransform(inner);const translation:RdbPoint=rdbTransformPoint({x:inner.x,y:inner.y},outer);
  const rawAngle:number=(outer.rotationDeg%360)+(outer.mirror?-(inner.rotationDeg%360):(inner.rotationDeg%360));
  const out:RdbTransform={rotationDeg:((rawAngle%360)+360)%360,mirror:outer.mirror!==inner.mirror,
    magnification:outer.magnification*inner.magnification,x:translation.x,y:translation.y};checkTransform(out);return out;
}
export function rdbFramePaths(d:RdbDocument,sourceCell:string,targetCell:string,limits?:RdbLimits):RdbFrameResult {
  try{const b:Budget=new Budget(limits);checkDocument(d,b);const cells:Map<string,RdbCell>=new Map<string,RdbCell>();for(const c of d.cells)cells.set(rdbCellQName(c),c);
    if(!cells.has(sourceCell)||!cells.has(targetCell))fail('定位 source/target cell 不存在');const paths:RdbFramePath[]=[];
    const walk = (name:string,frame:RdbTransform,path:string[]):void => {b.spend();if(path.length>b.limits.maximumDepth)fail('定位 reference 深度超预算');
      if(name===targetCell){if(paths.length>=b.limits.maximumFramePaths)fail('定位路径超预算，未返回截断结果');paths.push({cells:path,transform:frame});return;}
      const cell:RdbCell=cells.get(name)!;for(const ref of cell.references)walk(ref.parentCell,composeRdbTransforms(ref.transform,frame),path.concat([ref.parentCell]));
    };walk(sourceCell,rdbIdentityTransform(),[sourceCell]);
    if(paths.length===0)fail('报告中不存在 source→target reference；需要布局另行提供实际 frame，不猜 identity');
    return{ok:true,message:'全部报告 reference 路径已解析',paths:paths};
  }catch(error){return{ok:false,message:errorMessage(error as Error),paths:[]};}
}
export function rdbItemBoundsNm(item:RdbItem,frame:RdbTransform=rdbIdentityTransform(),limits?:RdbLimits):RdbBoundsResult {
  try{const b:Budget=new Budget(limits);checkTransform(frame);const state:RdbBoundsState={};let label:boolean=false,path:boolean=false;
    const include = (p:RdbPoint,padding:number=0):void => {const q:RdbPoint=rdbTransformPoint(p,frame);const x:number=q.x*1000,y:number=q.y*1000,r:number=padding*frame.magnification*1000;finite(x,'nm X');finite(y,'nm Y');finite(r,'nm padding');
      if(state.bounds===undefined)state.bounds={minX:x-r,minY:y-r,maxX:x+r,maxY:y+r};else{state.bounds.minX=Math.min(state.bounds.minX,x-r);state.bounds.minY=Math.min(state.bounds.minY,y-r);state.bounds.maxX=Math.max(state.bounds.maxX,x+r);state.bounds.maxY=Math.max(state.bounds.maxY,y+r);}};
    for(const v of item.values){checkValue(v,b);
      if(v.kind==='label'){label=true;include({x:v.transform!.x,y:v.transform!.y});}
      else if(v.kind==='box'&&v.points!.length===2){const a:RdbPoint=v.points![0],z:RdbPoint=v.points![1];const corners:RdbPoint[]=[a,z,{x:a.x,y:z.y},{x:z.x,y:a.y}];for(const p of corners)include(p);}
      else if(v.kind==='path'){
        path=true;
        // KLayout clips/reflexes miters beyond half-width. Its conservative bbox
        // construction uses full width, or half-width plus end extension.
        const padding:number=Math.max(v.width!,v.width!/2+Math.max(Math.abs(v.beginExtension!),Math.abs(v.endExtension!)));
        for(const p of v.points!)include(p,padding);
      }
      else if(v.points!==undefined){for(const p of v.points)include(p);if(v.holes!==undefined)for(const h of v.holes)for(const p of h)include(p);}
    }
    const bounds:RdbBounds|undefined=state.bounds;
    if(bounds!==undefined){finite(bounds.minX,'nm minX');finite(bounds.maxX,'nm maxX');finite(bounds.minY,'nm minY');finite(bounds.maxY,'nm maxY');}
    return{ok:true,message:bounds===undefined?'此 item 没有非空几何标记':'μm 标记已转换到指定 frame 的 nm 定位范围',boundsNm:bounds,labelAnchorOnly:label,conservativePath:path};
  }catch(error){return{ok:false,message:errorMessage(error as Error),labelAnchorOnly:false,conservativePath:false};}
}
interface RdbBoundsState { bounds?:RdbBounds; }
export function rdbFromViolations(report:RdbViolationReport,limits?:RdbLimits):RdbReadResult {
  try{const b:Budget=new Budget(limits);keys(report,['description','originalFile','generator','cellName','violations','runNotice'],'DRC report');b.text(report.runNotice);const d:RdbDocument={schemaVersion:1,coordinateUnit:'um',description:report.description,originalFile:report.originalFile,
    generator:report.generator,topCell:report.cellName,tags:[],categories:[],cells:[{name:report.cellName,variant:'',layoutName:'',references:[]}],items:[]};
    const rules:Map<string,RdbCategory>=new Map<string,RdbCategory>();array(report.violations,'violations');
    if(report.violations.length>b.limits.maximumItems)fail('DRC item 超预算');
    for(const violation of report.violations){keys(violation,['id','ruleId','ruleName','type','severity','layerNumber','x','y','width','height','message','shapeIds','fromInstance'],'DRC violation');for(const n of [violation.x,violation.y,violation.width,violation.height])finite(n,'DRC nm 坐标');
      if(!Number.isSafeInteger(violation.id)||!Number.isInteger(violation.layerNumber)||violation.layerNumber<0||violation.layerNumber>32767)fail('DRC sourceId/layer 非法');
      b.text(violation.type);b.text(violation.severity);array(violation.shapeIds,'DRC shapeIds');for(const id of violation.shapeIds)if(!Number.isSafeInteger(id))fail('DRC shapeId 非法');
      if(violation.fromInstance!==undefined&&typeof violation.fromInstance!=='boolean')fail('DRC fromInstance 非布尔');
      if(violation.width<0||violation.height<0)fail('DRC 范围尺寸为负数');b.text(violation.ruleId);b.text(violation.ruleName);b.text(violation.message);
      if(!rules.has(violation.ruleId)){const c:RdbCategory={name:violation.ruleId,description:violation.ruleName,categories:[]};rules.set(violation.ruleId,c);d.categories.push(c);}
      const values:RdbValue[]=[{kind:'text',text:violation.message},{kind:'text',text:'ruleId='+violation.ruleId+'; ruleName='+violation.ruleName},
        {kind:'text',text:'severity='+violation.severity+'; type='+violation.type+'; layer='+violation.layerNumber},
        {kind:'text',text:'sourceId='+violation.id+'; shapeIds='+violation.shapeIds.join(',')+'; fromInstance='+(violation.fromInstance===true)}];
      // Existing DRC x/y is the marker centre in the published active-cell frame.
      values.push({kind:'box',points:[{x:(violation.x-violation.width/2)/1000,y:(violation.y-violation.height/2)/1000},{x:(violation.x+violation.width/2)/1000,y:(violation.y+violation.height/2)/1000}]});
      d.items.push({cell:report.cellName,category:[violation.ruleId],tags:[],visited:false,multiplicity:1,comment:'',image:'',values:values});
    }
    if(report.runNotice!==''){let name:string='HongTu.RunNotice';let suffix:number=1;while(rules.has(name)){b.spend();name='HongTu.RunNotice.'+suffix++;}d.categories.push({name:name,description:'Run context / completeness (not a pass claim)',categories:[]});
      d.items.push({cell:report.cellName,category:[name],tags:[],visited:false,multiplicity:1,comment:'',image:'',values:[{kind:'text',text:report.runNotice}]});}
    checkDocument(d,b);return{ok:true,message:'已有 DRC 报告已转换；没有执行检查或修改检查通过状态',document:d};
  }catch(error){return{ok:false,message:errorMessage(error as Error)};}
}
export class RdbService {
  parse(xml:string,limits?:RdbLimits):RdbReadResult{return parseRdb(xml,limits);}
  async parseAsync(xml: string, limits?: RdbLimits): Promise<RdbReadResult> { return await parseRdbAsync(xml, limits); }
  serialize(document:RdbDocument,limits?:RdbLimits):RdbWriteResult{return serializeRdb(document,limits);}
  framePaths(document:RdbDocument,source:string,target:string,limits?:RdbLimits):RdbFrameResult{return rdbFramePaths(document,source,target,limits);}
  itemBoundsNm(item:RdbItem,frame?:RdbTransform,limits?:RdbLimits):RdbBoundsResult{return rdbItemBoundsNm(item,frame,limits);}
  queryItems(document:RdbDocument,query:RdbItemQuery,limits?:RdbLimits):RdbQueryResult{return rdbQueryItems(document,query,limits);}
  fromViolations(report:RdbViolationReport,limits?:RdbLimits):RdbReadResult{return rdbFromViolations(report,limits);}
}
export const rdbService:RdbService=new RdbService();
