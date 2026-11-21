/**
 * 鸿图验证增强服务
 *
 * 补齐与 KLayout 对齐的分析功能：
 * - XOR 对比（版图异或）— 比较两组图形的差异
 * - 网络追踪（Net Tracing）— 追踪连通网络
 * - 标记浏览器（Marker Browser）— DRC/分析结果可视化
 * - 版图差异对比（Layout Diff）— 两个版图文件差异
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { Shape, ShapeType, Point, getShapeBounds, ShapeBounds } from '../models/GdsiiData';
import { editService } from './EditService';
import { drcService, DrcViolation } from './DrcService';
import { nativeHongTuService } from './NativeHongTuService';
import { DEMO_VIA_LAYERS } from '../common/constants';
import type { NativeNet, NativeViaLayer, NativeLvsResult } from '../../cpp/types/libhongtu/Index';

/** XOR 差异结果 */
export interface XorResult {
  /** 仅在 A 中存在的图形数 */
  onlyInA: number;
  /** 仅在 B 中存在的图形数 */
  onlyInB: number;
  /** 交集图形数 */
  intersection: number;
  /** 差异图形（A XOR B） */
  diffShapes: Shape[];
  /** 耗时(ms) */
  elapsed: number;
}

/** 包围盒 */
export interface BoundingBox {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

/** 网络（Net） */
export interface Net {
  id: number;
  name: string;
  shapes: number[];  // shape IDs
  boundingBox: BoundingBox;
  fromInstance?: boolean;
}

/** 标记（Marker）— DRC/分析结果的可视化标记 */
export interface Marker {
  id: number;
  source: string;       // 来源："DRC" / "XOR" / "NetTrace"
  category: string;     // 分类
  message: string;      // 描述
  x: number;
  y: number;
  width: number;
  height: number;
  severity: 'error' | 'warning' | 'info';
  shapeId?: number;     // 关联图形
}

/**
 * 普通导入版图的安全默认：仅同层连通。GDS/OASIS 层号属于文件及其 PDK，
 * 不能把内置演示层名直接解释为通孔。调用方有明确工艺层表时传入 viaLayers。
 */
export const DEFAULT_VIA_LAYERS: NativeViaLayer[] = [];

/** 仅供内置演示文档显式启用；Via3 无 M4 定义，未自动连通。 */
export const DEMO_LVS_VIA_LAYERS: NativeViaLayer[] = DEMO_VIA_LAYERS;

/** LVS 单网判定（供 UI 逐网渲染，不关心 native 细节） */
export interface LvsNetReport {
  /** 同名网络仍以提取ID区分；仅在本次快照内有效 */
  netId: number;
  shapeIds: number[];
  fromInstance: boolean;
  /** 网名（未命名时为 native 生成的 N$n 匿名名） */
  name: string;
  /** 该网承载的全部标签名（>1 即一网多网名 = 短路） */
  labels: string[];
  shapeCount: number;
  layers: number[];
  /** 判定：match 已匹配参考网 / open 参考网表有而版图无 / short 短路 / extra 版图多余 / anonymous 未标签 */
  verdict: string;
  /** 中文结论标签（直接渲染） */
  verdictLabel: string;
  /** true = 该网结论为通过项（渲染成绿色） */
  ok: boolean;
  bboxMinX: number;
  bboxMinY: number;
  bboxMaxX: number;
  bboxMaxY: number;
}

/**
 * 验证增强服务
 */
export class VerifyService {
  /** markers 数组上限，超过则丢弃最旧记录 */
  private static readonly MAX_MARKERS: number = 200;

  private markers: Marker[] = [];
  private nextMarkerId = 1;
  private nets: Net[] = [];
  // VERIFY-2: nextNetId 死字段已删除（traceNets 使用局部 netId 变量，从未读写此字段）

  // ===== XOR 对比 =====

  /**
   * 计算两组图形的 XOR
   * 简化版：基于包围盒的快速比较
   */
  xorCompare(shapesA: Shape[], shapesB: Shape[]): XorResult {
    const startTime = Date.now();
    const diffShapes: Shape[] = [];

    // 找出在 A 但不在 B 的图形
    for (const a of shapesA) {
      const found = shapesB.some(b => this.shapesEqual(a, b));
      if (!found) {
        diffShapes.push(this.cloneShape(a));
      }
    }

    // 找出在 B 但不在 A 的图形
    for (const b of shapesB) {
      const found = shapesA.some(a => this.shapesEqual(a, b));
      if (!found) {
        diffShapes.push(this.cloneShape(b));
      }
    }

    const intersection = shapesA.filter(a => shapesB.some(b => this.shapesEqual(a, b))).length;

    const result: XorResult = {
      onlyInA: shapesA.length - intersection,
      onlyInB: shapesB.length - intersection,
      intersection: intersection,
      diffShapes: diffShapes,
      elapsed: Date.now() - startTime,
    };
    return result;
  }

  // ===== 网络追踪 =====

  /**
   * native 连通网络提取（同层交叠/接触 + via 跨层 + TEXT 标签命名）。
   * 作用于 native 布局快照；编辑后调用方先 syncDocument 当前文档，不需要保存或清除 dirty。
   * 返回 null 表示 native 不可用**或没有已加载布局**，调用方回退 ArkTS traceNets。
   */
  traceNetsNative(viaLayers: NativeViaLayer[], ownerCellId: number,
                  hierarchyDepth: number = 0): Net[] | null {
    const native: NativeNet[] | null =
      nativeHongTuService.extractNets(viaLayers, ownerCellId, hierarchyDepth);
    if (native === null) {
      return null;
    }
    return this.cacheNativeNets(native);
  }

  private cacheNativeNets(native: NativeNet[]): Net[] {
    const nets: Net[] = [];
    for (let i = 0; i < native.length; i++) {
      const n: NativeNet = native[i];
      const shapeIds: number[] = [];
      for (let j = 0; j < n.shapeIds.length; j++) {
        shapeIds.push(n.shapeIds[j]);
      }
      const box: BoundingBox = {
        minX: n.bboxMinX,
        minY: n.bboxMinY,
        maxX: n.bboxMaxX,
        maxY: n.bboxMaxY,
      };
      const net: Net = {
        id: n.id,
        name: n.name,
        shapes: shapeIds,
        boundingBox: box,
        fromInstance: n.fromInstance === true,
      };
      nets.push(net);
    }
    this.nets = nets;
    return nets;
  }

  /**
   * 连通性级 LVS（native）：与 SPICE 参考网表按网名比对。
   * @returns null = native 模块不可用；否则结果对象的 ran/status 说明是否真的跑过
   */
  runLvsNative(schematicNetlist: string, viaLayers: NativeViaLayer[],
               ownerCellId: number, hierarchyDepth: number = 0): NativeLvsResult | null {
    return nativeHongTuService.runLvs(schematicNetlist, viaLayers, ownerCellId, hierarchyDepth);
  }

  /** 导出提取网表为 SPICE 文本（native）；不可用/无布局返回 null */
  exportSpiceNetlist(viaLayers: NativeViaLayer[], ownerCellId: number,
                     hierarchyDepth: number = 0): string | null {
    return nativeHongTuService.exportSpiceNetlist(viaLayers, ownerCellId, hierarchyDepth);
  }

  /** LVS 结果状态 → 中文标题（UI 用它区分「未运行」与「不匹配」） */
  lvsStatusLabel(status: string): string {
    if (status === 'pass') return 'LVS 通过（连通性级预检查）';
    if (status === 'mismatch') return 'LVS 不匹配';
    if (status === 'no-netlist') return 'LVS 未运行：缺少参考网表';
    if (status === 'empty-schematic') return 'LVS 未运行：参考网表解析不出网络';
    if (status === 'invalid-schematic') return 'LVS 未运行：参考网表记录不完整';
    if (status === 'unsupported-schematic') return 'LVS 未运行：参考网表超出连通性预检查范围';
    if (status === 'truncated') return 'LVS 未运行：网络提取不完整';
    if (status === 'empty-layout') return 'LVS 未运行：版图提取到 0 网络';
    if (status === 'no-layout') return 'LVS 未运行：native 侧无已加载版图';
    return 'LVS 未运行';
  }

  /**
   * 逐网判定表：把 native 网络列表 + LVS 结果合成 UI 可直接渲染的行。
   * 短路优先于匹配（一网多网名时不能只报「匹配」把缺陷藏起来）。
   */
  buildLvsReports(nativeNets: NativeNet[], result: NativeLvsResult): LvsNetReport[] {
    this.cacheNativeNets(nativeNets);
    const shorts: string[][] = [];
    for (let i = 0; i < result.shortNets.length; i++) {
      shorts.push(result.shortNets[i].split('<->'));
    }
    const reports: LvsNetReport[] = [];
    for (let i = 0; i < nativeNets.length; i++) {
      const n: NativeNet = nativeNets[i];
      const anonymous: boolean = n.labels.length === 0;
      let verdict: string = 'match';
      if (anonymous) {
        verdict = 'anonymous';
      }
      for (let s = 0; s < shorts.length; s++) {
        const parts: string[] = shorts[s];
        let hit: boolean = false;
        for (let l = 0; l < n.labels.length; l++) {
          if (parts.indexOf(n.labels[l]) >= 0) {
            hit = true;
          }
        }
        if (hit) {
          verdict = 'short';
          break;
        }
      }
      if (verdict === 'match' && !anonymous) {
        for (let o = 0; o < result.openNets.length; o++) {
          if (n.labels.indexOf(result.openNets[o]) >= 0) {
            verdict = 'open';
            break;
          }
        }
      }
      if (verdict === 'match' && !anonymous) {
        for (let e = 0; e < result.extraNets.length; e++) {
          if (n.labels.indexOf(result.extraNets[e]) >= 0) {
            verdict = 'extra';
            break;
          }
        }
      }
      const report: LvsNetReport = {
        netId: n.id,
        shapeIds: n.shapeIds.slice(),
        fromInstance: n.fromInstance === true,
        name: n.name,
        labels: n.labels.slice(),
        shapeCount: n.shapeIds.length,
        layers: n.layers.slice(),
        verdict: verdict,
        verdictLabel: VerifyService.verdictLabel(verdict, n.labels),
        ok: verdict === 'match',
        bboxMinX: n.bboxMinX,
        bboxMinY: n.bboxMinY,
        bboxMaxX: n.bboxMaxX,
        bboxMaxY: n.bboxMaxY,
      };
      reports.push(report);
    }
    return reports;
  }

  /** ID 在本次提取快照内唯一；禁止以网名选中另一座不连通的同名导体。 */
  getNetForReport(report: LvsNetReport): Net | undefined {
    return this.nets.find((net: Net) => net.id === report.netId);
  }

  /** 文档版本变化后，旧成员 ID 与位置标记不能作为当前分析再使用。 */
  invalidateDocumentAnalysis(): void {
    drcService.invalidateResult();
    this.nets = [];
    this.clearMarkers();
  }

  /** 仅参考网表或 LVS 输入变化；其他来源的标记可继续保留。 */
  clearNetSnapshot(): void {
    this.nets = [];
    this.clearMarkers('NetTrace');
  }

  private static verdictLabel(verdict: string, labels: string[]): string {
    if (verdict === 'short') return '短路 ' + labels.join(' <-> ');
    if (verdict === 'open') return '开路（同名导体未连通）';
    if (verdict === 'extra') return '多余（参考网表无此名）';
    if (verdict === 'anonymous') return '未标签（匿名网）';
    return '匹配';
  }

  /**
   * 追踪网络连通性
   * 简化版：同层重叠或接触的图形属于同一网络
   */
  traceNets(shapes: Shape[]): Net[] {
    this.nets = [];
    const visited = new Set<number>();
    let netId = 1;

    // V-1: 过滤 INSTANCE/TEXT 类型，它们是引用/标注而非真实几何图形，
    // 不应参与网络连通性分析（INSTANCE 无几何范围，TEXT 是标注锚点）
    const geometricShapes: Shape[] = shapes.filter(s =>
      s.type !== ShapeType.INSTANCE && s.type !== ShapeType.TEXT && s.type !== ShapeType.NODE
    );

    for (const shape of geometricShapes) {
      if (visited.has(shape.id)) continue;

      const netShapes: number[] = [shape.id];
      visited.add(shape.id);

      // BFS 搜索连通图形
      const queue: Shape[] = [shape];
      while (queue.length > 0) {
        const current = queue.shift()!;
        // V-1: 在已过滤的 geometricShapes 上遍历，避免 INSTANCE/TEXT 参与连通性分析
        for (const s of geometricShapes) {
          if (visited.has(s.id)) continue;
          if (s.layerNumber === current.layerNumber && s.datatype === current.datatype && this.shapesConnected(current, s)) {
            visited.add(s.id);
            netShapes.push(s.id);
            queue.push(s);
          }
        }
      }

      // 计算包围盒（VERIFY-3: 复用 getShapeBounds，统一对 PATH 扩展 pathWidth/2 并处理空 points）
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      let hasAny: boolean = false;
      for (const sid of netShapes) {
        const s = geometricShapes.find(sh => sh.id === sid);
        if (s) {
          const sb: ShapeBounds = getShapeBounds(s);
          // getShapeBounds 对空 points 返回 {0,0,0,0}，此处需跳过避免污染
          if (s.points.length === 0) continue;
          hasAny = true;
          if (sb.minX < minX) minX = sb.minX;
          if (sb.minY < minY) minY = sb.minY;
          if (sb.maxX > maxX) maxX = sb.maxX;
          if (sb.maxY > maxY) maxY = sb.maxY;
        }
      }
      // VERIFY-3: 无有效顶点时回退到 0,0,0,0，避免 Infinity 拼入状态栏
      if (!hasAny) {
        minX = 0; minY = 0; maxX = 0; maxY = 0;
      }

      const box: BoundingBox = { minX: minX, minY: minY, maxX: maxX, maxY: maxY };
      // 先用当前 netId 生成名称再自增，确保第一个网络为 NET1
      const net: Net = {
        id: netId,
        name: `NET${netId}`,
        shapes: netShapes,
        boundingBox: box,
      };
      netId++;
      this.nets.push(net);
    }

    return this.nets;
  }

  getNets(): Net[] { return this.nets; }

  getNet(id: number): Net | undefined { return this.nets.find(n => n.id === id); }

  // ===== 标记浏览器 =====

  /** 从 DRC 结果生成标记 */
  markersFromDrc(violations: DrcViolation[]): Marker[] {
    const newMarkers: Marker[] = [];
    for (let i = 0; i < violations.length; i++) {
      const v = violations[i];
      const m: Marker = {
        id: this.nextMarkerId++,
        source: 'DRC',
        category: v.ruleName,
        message: v.message,
        x: v.x,
        y: v.y,
        width: v.width,
        height: v.height,
        severity: v.severity === 'error' ? 'error' : 'warning',
      };
      newMarkers.push(m);
    }
    for (let i = 0; i < newMarkers.length; i++) {
      this.pushMarker(newMarkers[i]);
    }
    return newMarkers;
  }

  /** 从 XOR 结果生成标记 */
  markersFromXor(result: XorResult): Marker[] {
    const newMarkers: Marker[] = [];
    for (let i = 0; i < result.diffShapes.length; i++) {
      const s = result.diffShapes[i];
      // VERIFY-4: 复用 getShapeBounds，统一对 PATH 扩展并避免 spread 栈溢出
      const sb: ShapeBounds = getShapeBounds(s);
      const m: Marker = {
        id: this.nextMarkerId++,
        source: 'XOR',
        category: 'XOR差异',
        message: `差异图形 (L${s.layerNumber})`,
        x: sb.minX,
        y: sb.minY,
        width: sb.maxX - sb.minX,
        height: sb.maxY - sb.minY,
        severity: 'info',
        shapeId: s.id,
      };
      newMarkers.push(m);
    }
    for (let i = 0; i < newMarkers.length; i++) {
      this.pushMarker(newMarkers[i]);
    }
    return newMarkers;
  }

  getMarkers(): Marker[] { return this.markers; }

  getMarkersBySource(source: string): Marker[] {
    return this.markers.filter(m => m.source === source);
  }

  clearMarkers(source?: string) {
    if (source) {
      this.markers = this.markers.filter(m => m.source !== source);
    } else {
      this.markers = [];
    }
  }

  deleteMarker(id: number): boolean {
    const idx = this.markers.findIndex(m => m.id === id);
    if (idx >= 0) {
      this.markers.splice(idx, 1);
      return true;
    }
    return false;
  }

  // ===== 辅助方法 =====

  /** 压入 marker，并在超过 MAX_MARKERS 时丢弃最旧记录 */
  private pushMarker(m: Marker): void {
    this.markers.push(m);
    while (this.markers.length > VerifyService.MAX_MARKERS) {
      this.markers.shift();
    }
  }

  private shapesEqual(a: Shape, b: Shape): boolean {
    // V-3: 完整比较图形语义，原实现仅比较 layerNumber+points，导致
    // RECT 与 POLYGON 同层同顶点被判等，PATH 与 POLYGON 同顶点被判等（忽略 pathWidth），
    // TEXT 与 RECT 同层同锚点被判等（忽略 text 内容）
    if (a.type !== b.type) return false;
    if (a.layerNumber !== b.layerNumber) return false;
    if (a.points.length !== b.points.length) return false;
    // PATH 必须比较 pathWidth
    if (a.type === ShapeType.PATH) {
      const aw = a.pathWidth ?? 0;
      const bw = b.pathWidth ?? 0;
      if (aw !== bw) return false;
    }
    // TEXT 必须比较 text 内容
    if (a.type === ShapeType.TEXT) {
      if ((a.text ?? '') !== (b.text ?? '')) return false;
    }
    return a.points.every((p, i) => p.x === b.points[i].x && p.y === b.points[i].y);
  }

  private shapesConnected(a: Shape, b: Shape): boolean {
    // 简化：检查包围盒是否重叠或接触
    const aBox = this.getBoundingBox(a);
    const bBox = this.getBoundingBox(b);
    return !(aBox.maxX < bBox.minX || aBox.minX > bBox.maxX ||
             aBox.maxY < bBox.minY || aBox.minY > bBox.maxY);
  }

  private getBoundingBox(shape: Shape): BoundingBox {
    // VERIFY-2/4: 复用 getShapeBounds，统一对 PATH 扩展 pathWidth/2 并用循环避免栈溢出
    const sb: ShapeBounds = getShapeBounds(shape);
    const box: BoundingBox = {
      minX: sb.minX,
      minY: sb.minY,
      maxX: sb.maxX,
      maxY: sb.maxY,
    };
    return box;
  }

  private cloneShape(s: Shape): Shape {
    const pts: Point[] = [];
    for (let i = 0; i < s.points.length; i++) {
      pts.push({ x: s.points[i].x, y: s.points[i].y });
    }
    const copy: Shape = {
      id: s.id,
      type: s.type,
      layerNumber: s.layerNumber,
      datatype: s.datatype,
      points: pts,
      selected: s.selected,
    };
    if (s.pathWidth !== undefined) {
      copy.pathWidth = s.pathWidth;
    }
    // VERIFY-1: 补齐 INSTANCE 专属字段（cellId/rotation/mirror/cellName）
    if (s.ownerCellId !== undefined) {
      copy.ownerCellId = s.ownerCellId;
    }
    if (s.cellId !== undefined) {
      copy.cellId = s.cellId;
    }
    if (s.rotation !== undefined) {
      copy.rotation = s.rotation;
    }
    if (s.mirror !== undefined) {
      copy.mirror = s.mirror;
    }
    if (s.magnification !== undefined) {
      copy.magnification = s.magnification;
    }
    if (s.cellName !== undefined) {
      copy.cellName = s.cellName;
    }
    // VERIFY-1: 补齐 TEXT 专属字段
    if (s.text !== undefined) {
      copy.text = s.text;
    }
    return copy;
  }
}

/** 验证服务单例 */
export const verifyService = new VerifyService();
