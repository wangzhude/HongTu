/**
 * 鸿图 Agent 原生联网检索与网页正文提取服务
 *
 * 特性：
 * 1. 免额外 API Key 开箱即用：并发/级联聚合 Bing Web/RSS、DuckDuckGo HTML 与 Wikipedia MediaWiki API；
 * 2. 严格 SSRF 防护：拦截 localhost、环回地址、RFC1918 私网、链路本地与非 HTTP(S) 协议；
 * 3. 智能正文清洗：剥离 script/style/nav/svg 噪声并解码 HTML 实体，保留结构化段落供 LLM 引用。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

export interface DshWebSearchItem {
  title: string;
  url: string;
  snippet: string;
  source: string;
}

interface ScoredSearchItem {
  item: DshWebSearchItem;
  score: number;
}

export interface DshWebSearchResponse {
  query: string;
  engine: string;
  results: DshWebSearchItem[];
  errorMessage?: string;
}

export interface DshWebFetchResponse {
  url: string;
  title: string;
  content: string;
  truncated: boolean;
  byteLength: number;
}

const SEARCH_USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

export function validatePublicWebUrl(rawUrl: string): string {
  const trimmed: string = rawUrl.trim();
  if (trimmed.length === 0 || trimmed.length > 2048) {
    throw new Error('URL 长度无效');
  }
  const match: RegExpExecArray | null = /^(https?):\/\/([^/\s?#]+)(\/[^\s#]*)?(?:#.*)?$/i.exec(trimmed);
  if (match === null) {
    throw new Error('仅支持公开的 http:// 或 https:// 网页地址');
  }
  const authority: string = match[2];
  if (authority.includes('@')) {
    throw new Error('不允许包含内嵌凭据的 URL');
  }
  let host: string = authority.toLowerCase();
  if (host.startsWith('[')) {
    const closeIdx: number = host.indexOf(']');
    if (closeIdx < 0) {
      throw new Error('IPv6 主机格式无效');
    }
    const ipv6: string = host.substring(1, closeIdx);
    if (ipv6 === '::1' || ipv6 === '::' || ipv6.startsWith('fe80:') || ipv6.startsWith('fc') || ipv6.startsWith('fd')) {
      throw new Error('禁止访问本地或内网 IPv6 地址');
    }
    host = ipv6;
  } else {
    const colonIdx: number = host.lastIndexOf(':');
    if (colonIdx > 0) {
      const portStr: string = host.substring(colonIdx + 1);
      if (!/^\d{1,5}$/.test(portStr)) {
        throw new Error('URL 端口格式无效');
      }
      const portNum: number = Number(portStr);
      if (portNum < 1 || portNum > 65535) {
        throw new Error('URL 端口超出范围');
      }
      host = host.substring(0, colonIdx);
    }
  }
  if (host === 'localhost' || host.endsWith('.local') || host.endsWith('.internal') || host.endsWith('.lan')) {
    throw new Error('禁止访问本地或内网域名');
  }
  const ipv4Match: RegExpExecArray | null = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (ipv4Match !== null) {
    const a: number = Number(ipv4Match[1]);
    const b: number = Number(ipv4Match[2]);
    const c: number = Number(ipv4Match[3]);
    const d: number = Number(ipv4Match[4]);
    if (a > 255 || b > 255 || c > 255 || d > 255) {
      throw new Error('IPv4 地址无效');
    }
    if (
      a === 0 ||
      a === 10 ||
      a === 127 ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) ||
      (a === 100 && b >= 64 && b <= 127) ||
      a >= 224
    ) {
      throw new Error('禁止访问环回、私网或保留 IPv4 地址');
    }
  }
  return trimmed;
}

export function decodeHtmlEntities(input: string): string {
  if (input.length === 0) return '';
  return input
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&#x([0-9a-fA-F]{1,6});/g, (_all: string, hex: string): string => {
      const code: number = parseInt(hex, 16);
      return Number.isFinite(code) && code > 0 && code <= 0x10FFFF ? String.fromCodePoint(code) : '';
    })
    .replace(/&#(\d{1,7});/g, (_all: string, dec: string): string => {
      const code: number = parseInt(dec, 10);
      return Number.isFinite(code) && code > 0 && code <= 0x10FFFF ? String.fromCodePoint(code) : '';
    });
}

export function extractReadableTextFromHtml(html: string, maxChars: number = 12000): DshWebFetchResponse {
  let title: string = '';
  const titleMatch: RegExpExecArray | null = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
  if (titleMatch !== null) {
    title = decodeHtmlEntities(titleMatch[1].replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
  }
  let cleaned: string = html
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<(?:script|style|noscript|svg|canvas|iframe|header|footer|nav)[^>]*>[\s\S]*?<\/(?:script|style|noscript|svg|canvas|iframe|header|footer|nav)>/gi, ' ')
    .replace(/<(?:br|hr)\s*\/?>/gi, '\n')
    .replace(/<\/(?:p|div|section|article|li|tr|h[1-6]|blockquote|pre)>/gi, '\n')
    .replace(/<[^>]+>/g, ' ');
  cleaned = decodeHtmlEntities(cleaned)
    .replace(/[ \t\f\v]+/g, ' ')
    .replace(/\r?\n\s*\r?\n+/g, '\n\n')
    .trim();
  const truncated: boolean = cleaned.length > maxChars;
  const content: string = truncated ? `${cleaned.substring(0, maxChars)}…` : cleaned;
  return {
    url: '',
    title,
    content,
    truncated,
    byteLength: html.length
  };
}

function decodeResultBody(result: string | Object | ArrayBuffer): string {
  if (typeof result === 'string') {
    return result;
  }
  if (result instanceof ArrayBuffer) {
    const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(result));
  }
  return String(result);
}

export function unwrapSearchRedirectUrl(rawHref: string): string {
  let href: string = decodeHtmlEntities(rawHref).trim();
  if (href.startsWith('//')) {
    href = `https:${href}`;
  }
  const uddgMatch: RegExpExecArray | null = /[?&]uddg=([^&]+)/i.exec(href);
  if (uddgMatch !== null) {
    try {
      href = decodeURIComponent(uddgMatch[1]);
    } catch (_) {}
  }
  const bingMatch: RegExpExecArray | null = /bing\.com\/ck\/a\?(?:[^#]*&)?u=a1([A-Za-z0-9_-]+)/i.exec(href);
  if (bingMatch !== null) {
    try {
      let b64: string = bingMatch[1].replace(/-/g, '+').replace(/_/g, '/');
      while (b64.length % 4 !== 0) {
        b64 += '=';
      }
      const helper: util.Base64Helper = new util.Base64Helper();
      const decodedBytes: Uint8Array = helper.decodeSync(b64);
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const target: string = decoder.decodeToString(decodedBytes).trim();
      if (/^https?:\/\//i.test(target)) {
        href = target;
      }
    } catch (_) {}
  }
  return href;
}

export function filterRelevantSearchItems(query: string, items: DshWebSearchItem[]): DshWebSearchItem[] {
  const tokens: string[] = query
    .toLowerCase()
    .split(/[\s,.;:!?/\\|()\[\]{}"']+/)
    .map((t: string): string => t.trim())
    .filter((t: string): boolean => t.length >= 2);
  if (tokens.length === 0 || items.length <= 1) {
    return items;
  }
  const scored: ScoredSearchItem[] = [];
  for (let i = 0; i < items.length; i++) {
    const it: DshWebSearchItem = items[i];
    const hay: string = `${it.title} ${it.url} ${it.snippet}`.toLowerCase();
    let hits: number = 0;
    for (let k = 0; k < tokens.length; k++) {
      if (hay.includes(tokens[k])) {
        hits++;
      }
    }
    const isNoiseDict: boolean = /(?:dict\.youdao\.com|iciba\.com|fanyi\.baidu\.com)/i.test(it.url);
    const score: number = hits - (isNoiseDict ? 2 : 0);
    scored.push({ item: it, score });
  }
  const strong: DshWebSearchItem[] = scored
    .filter((entry: ScoredSearchItem): boolean => entry.score > 0)
    .sort((a: ScoredSearchItem, b: ScoredSearchItem): number => b.score - a.score)
    .map((entry: ScoredSearchItem): DshWebSearchItem => entry.item);
  return strong.length > 0 ? strong : items;
}

export function parseBingRssItems(xml: string, maxResults: number): DshWebSearchItem[] {
  const out: DshWebSearchItem[] = [];
  const itemRegex: RegExp = /<item>([\s\S]*?)<\/item>/gi;
  let match: RegExpExecArray | null = itemRegex.exec(xml);
  while (match !== null && out.length < maxResults) {
    const block: string = match[1];
    const tMatch: RegExpExecArray | null = /<title>([\s\S]*?)<\/title>/i.exec(block);
    const lMatch: RegExpExecArray | null = /<link>([\s\S]*?)<\/link>/i.exec(block);
    const dMatch: RegExpExecArray | null = /<description>([\s\S]*?)<\/description>/i.exec(block);
    const rawUrl: string = lMatch !== null
      ? unwrapSearchRedirectUrl(lMatch[1].replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1'))
      : '';
    const title: string = tMatch !== null
      ? decodeHtmlEntities(tMatch[1].replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').replace(/<[^>]+>/g, '')).replace(/\s+/g, ' ').trim()
      : '';
    const snippet: string = dMatch !== null
      ? decodeHtmlEntities(dMatch[1].replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim()
      : '';
    if (title.length > 0 && /^https?:\/\//i.test(rawUrl)) {
      out.push({ title, url: rawUrl, snippet: snippet.substring(0, 360), source: 'Bing' });
    }
    match = itemRegex.exec(xml);
  }
  return out;
}

export function parseBingHtmlItems(html: string, maxResults: number): DshWebSearchItem[] {
  const out: DshWebSearchItem[] = [];
  const blockRegex: RegExp = /<li[^>]+class="[^"]*\bb_algo\b[^"]*"[^>]*>([\s\S]*?)<\/li>/gi;
  let match: RegExpExecArray | null = blockRegex.exec(html);
  while (match !== null && out.length < maxResults) {
    const block: string = match[1];
    const aMatch: RegExpExecArray | null = /<h2[^>]*>[\s\S]*?<a[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/i.exec(block);
    if (aMatch !== null) {
      const url: string = unwrapSearchRedirectUrl(aMatch[1]);
      const title: string = decodeHtmlEntities(aMatch[2].replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
      const pMatch: RegExpExecArray | null = /<p[^>]*>([\s\S]*?)<\/p>/i.exec(block);
      const snippet: string = pMatch !== null
        ? decodeHtmlEntities(pMatch[1].replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim()
        : '';
      if (title.length > 0 && /^https?:\/\//i.test(url) && !out.some((x: DshWebSearchItem): boolean => x.url === url)) {
        out.push({ title, url, snippet: snippet.substring(0, 360), source: 'Bing' });
      }
    }
    match = blockRegex.exec(html);
  }
  return out;
}

export function parseDuckDuckGoHtmlItems(html: string, maxResults: number): DshWebSearchItem[] {
  const out: DshWebSearchItem[] = [];
  const linkRegex: RegExp = /<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>([\s\S]{0,1200})/gi;
  let match: RegExpExecArray | null = linkRegex.exec(html);
  while (match !== null && out.length < maxResults) {
    const url: string = unwrapSearchRedirectUrl(match[1]);
    const title: string = decodeHtmlEntities(match[2].replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
    const tail: string = match[3];
    const snipMatch: RegExpExecArray | null = /class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)<\/(?:a|div|span)>/i.exec(tail);
    const snippet: string = snipMatch !== null
      ? decodeHtmlEntities(snipMatch[1].replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim()
      : '';
    if (title.length > 0 && /^https?:\/\//i.test(url) && !out.some((x: DshWebSearchItem): boolean => x.url === url)) {
      out.push({ title, url, snippet: snippet.substring(0, 360), source: 'DuckDuckGo' });
    }
    match = linkRegex.exec(html);
  }
  return out;
}

export class DshWebSearchService {
  private async httpGetText(url: string, timeoutMs: number = 12000, accept: string = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'): Promise<string> {
    const safeUrl: string = validatePublicWebUrl(url);
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(safeUrl, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': SEARCH_USER_AGENT,
          'Accept': accept,
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
        },
        connectTimeout: Math.min(10000, timeoutMs),
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      if (resp.responseCode < 200 || resp.responseCode >= 400) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      return decodeResultBody(resp.result);
    } finally {
      try { req.destroy(); } catch (_) {}
    }
  }

  private async searchWikipedia(query: string, maxResults: number, lang: 'zh' | 'en'): Promise<DshWebSearchItem[]> {
    const host: string = lang === 'zh' ? 'zh.wikipedia.org' : 'en.wikipedia.org';
    const apiUrl: string =
      `https://${host}/w/api.php?action=query&list=search&srsearch=${encodeURIComponent(query)}&utf8=1&format=json&srlimit=${Math.min(8, maxResults)}`;
    const body: string = await this.httpGetText(apiUrl, 9000, 'application/json');
    const root: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
    const qObj: Object | undefined = root['query'];
    if (qObj === null || qObj === undefined || typeof qObj !== 'object') return [];
    const listObj: Object | undefined = (qObj as Record<string, Object>)['search'];
    if (!Array.isArray(listObj)) return [];
    const arr: Object[] = listObj as Object[];
    const items: DshWebSearchItem[] = [];
    for (let i = 0; i < arr.length && items.length < maxResults; i++) {
      const entry: Record<string, Object> = arr[i] as Record<string, Object>;
      const title: string = typeof entry['title'] === 'string' ? (entry['title'] as string).trim() : '';
      const rawSnippet: string = typeof entry['snippet'] === 'string' ? (entry['snippet'] as string) : '';
      if (title.length > 0) {
        items.push({
          title,
          url: `https://${host}/wiki/${encodeURIComponent(title.replace(/ /g, '_'))}`,
          snippet: decodeHtmlEntities(rawSnippet.replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim().substring(0, 360),
          source: lang === 'zh' ? 'Wikipedia(ZH)' : 'Wikipedia(EN)'
        });
      }
    }
    return items;
  }

  async search(rawQuery: string, limit: number = 6): Promise<DshWebSearchResponse> {
    const query: string = rawQuery.trim();
    if (query.length === 0) {
      throw new Error('搜索关键词不能为空');
    }
    const cappedLimit: number = Math.max(1, Math.min(10, Math.round(limit)));
    const merged: DshWebSearchItem[] = [];
    const seenUrls: Set<string> = new Set<string>();
    const usedEngines: string[] = [];
    const errors: string[] = [];

    const appendItems = (items: DshWebSearchItem[], engineName: string): void => {
      if (items.length > 0 && !usedEngines.includes(engineName)) {
        usedEngines.push(engineName);
      }
      for (let i = 0; i < items.length && merged.length < cappedLimit; i++) {
        const it: DshWebSearchItem = items[i];
        if (!seenUrls.has(it.url)) {
          seenUrls.add(it.url);
          merged.push(it);
        }
      }
    };

    // 1. Bing RSS (fast, clean XML structure, accessible directly in CN & global networks)
    try {
      const rssXml: string = await this.httpGetText(
        `https://cn.bing.com/search?q=${encodeURIComponent(query)}&format=rss&count=${cappedLimit}`,
        10000,
        'application/rss+xml,application/xml,text/xml,*/*;q=0.8'
      );
      appendItems(parseBingRssItems(rssXml, cappedLimit), 'Bing RSS');
    } catch (e) {
      errors.push(`BingRSS: ${e instanceof Error ? e.message : String(e)}`);
    }

    // 2. Bing HTML fallback if RSS returned fewer than 3 hits
    if (merged.length < Math.min(3, cappedLimit)) {
      try {
        const bingHtml: string = await this.httpGetText(
          `https://cn.bing.com/search?q=${encodeURIComponent(query)}&count=${cappedLimit}`,
          10000
        );
        appendItems(parseBingHtmlItems(bingHtml, cappedLimit), 'Bing Web');
      } catch (e) {
        errors.push(`BingWeb: ${e instanceof Error ? e.message : String(e)}`);
      }
    }

    // 3. DuckDuckGo HTML fallback
    if (merged.length < Math.min(3, cappedLimit)) {
      try {
        const ddgHtml: string = await this.httpGetText(
          `https://html.duckduckgo.com/html/?q=${encodeURIComponent(query)}`,
          10000
        );
        appendItems(parseDuckDuckGoHtmlItems(ddgHtml, cappedLimit), 'DuckDuckGo');
      } catch (e) {
        errors.push(`DDG: ${e instanceof Error ? e.message : String(e)}`);
      }
    }

    // 4. Wikipedia ZH/EN authoritative technical fallback
    if (merged.length < cappedLimit) {
      const hasCjk: boolean = /[\u4e00-\u9fff]/.test(query);
      try {
        const wikiItems: DshWebSearchItem[] = await this.searchWikipedia(query, cappedLimit - merged.length, hasCjk ? 'zh' : 'en');
        appendItems(wikiItems, 'Wikipedia');
      } catch (e) {
        errors.push(`Wiki: ${e instanceof Error ? e.message : String(e)}`);
      }
    }

    const filtered: DshWebSearchItem[] = filterRelevantSearchItems(query, merged).slice(0, cappedLimit);
    return {
      query,
      engine: usedEngines.length > 0 ? usedEngines.join(' + ') : 'unavailable',
      results: filtered,
      errorMessage: filtered.length === 0 && errors.length > 0 ? errors.join('; ') : undefined
    };
  }

  async fetchPage(rawUrl: string, maxChars: number = 12000): Promise<DshWebFetchResponse> {
    const safeUrl: string = validatePublicWebUrl(rawUrl);
    const cappedChars: number = Math.max(500, Math.min(32000, Math.round(maxChars)));
    const rawBody: string = await this.httpGetText(safeUrl, 15000);
    const trimmed: string = rawBody.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      const truncated: boolean = trimmed.length > cappedChars;
      return {
        url: safeUrl,
        title: safeUrl,
        content: truncated ? `${trimmed.substring(0, cappedChars)}…` : trimmed,
        truncated,
        byteLength: rawBody.length
      };
    }
    const parsed: DshWebFetchResponse = extractReadableTextFromHtml(rawBody, cappedChars);
    parsed.url = safeUrl;
    if (parsed.title.length === 0) {
      parsed.title = safeUrl;
    }
    return parsed;
  }
}

export const dshWebSearchService: DshWebSearchService = new DshWebSearchService();
