/**
 * 鸿图快捷键服务
 *
 * 拼音首字母快捷键系统，符合国人输入习惯：
 * - XZ = 选择 (XuanZe)
 * - JX = 矩形 (JuXing)
 * - DB = 多边形 (DuoBianXing)
 * - LJ = 路径 (LuJing)
 * - CL = 测量 (CeLiang)
 * - CX = 撤销 (CheXiao)
 * - CZ = 重做 (ChongZuo)
 * - SC = 删除 (ShanChu)
 * - FD = 放大 (FangDa)
 * - SX = 缩小 (SuoXiao)
 * - KF = 框选放大 (Kuangxuan Fangda)
 * - QX = 全选 (QuanXuan)
 *
 * 画布先按 Space 启动助记码，再在 800ms 间隔内连续输入；裸单键由 Index 直接处理。
 *
 * Profile 系统（解决 KLayout 快捷键可理解性痛点）：
 * - 可导出 / 导入 profile（JSON：actionKey → code）
 * - 冲突检查（同一 code 不能绑定到两个动作）
 * - 平台语法提示（Space + 字母助记码）
 * - PersistentStorage 跨重启保留
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { DrawTool, NavModule } from '../common/types';

/** 快捷键动作类型 */
export enum ShortcutAction {
  SWITCH_TOOL = 'switch_tool',
  UNDO = 'undo',
  REDO = 'redo',
  DELETE = 'delete',
  ZOOM_IN = 'zoom_in',
  ZOOM_OUT = 'zoom_out',
  FIT_ALL = 'fit_all',
  SELECT_ALL = 'select_all',
  DESELECT = 'deselect',
  TOGGLE_GRID = 'toggle_grid',
  SAVE = 'save',
  OPEN = 'open',
  RUN_DRC = 'run_drc',
  /** TRANSFORM-1: 旋转选中图形（param=度数：90/180/270） */
  ROTATE = 'rotate',
  /** TRANSFORM-1: 镜像选中图形（param=0 水平/X轴翻转，1 垂直/Y轴翻转） */
  MIRROR = 'mirror',
  /** TRANSFORM-1: 缩放选中图形（param=倍数，如 2.0/0.5） */
  SCALE = 'scale',
  /** SC-M2: 复制选中图形 */
  COPY = 'copy',
  /** SC-M2: 粘贴剪贴板 */
  PASTE = 'paste',
  /** SC-M2: 对齐选中图形（param=left/right/top/bottom/centerH/centerV） */
  ALIGN = 'align',
  /** SC-M2: 分布选中图形（param=horizontal/vertical） */
  DISTRIBUTE = 'distribute',
  /** 单键方案: 方向键微移（param=方向 'up'/'down'/'left'/'right'，步长由调用方决定） */
  NUDGE = 'nudge',
  /** 框选缩放（KF；单键 B 保留为矩形工具） */
  BOX_ZOOM = 'box_zoom',
  /** 单键方案: 视图后退（Backspace） */
  VIEW_BACK = 'view_back',
  /** 单键方案: 取消当前操作/回到Select（Esc） */
  ESCAPE = 'escape',
}

/** 快捷键映射条目 */
export interface ShortcutMapEntry {
  action: ShortcutAction;
  param?: Object;
}

/** 快捷键描述（用于显示快捷键列表） */
export interface ShortcutEntry {
  keys: string;
  action: ShortcutAction;
  description: string;
  category: string;
  /** 稳定动作键（用于编辑、导入导出） */
  actionKey: string;
}

/** importProfile 结果 */
export interface ImportResult {
  ok: boolean;
  error?: string;
}

/** setShortcut 结果 */
export interface SetShortcutResult {
  ok: boolean;
  conflict?: string;
  error?: string;
}

/** Map key-value 对（用于遍历时承载键值，避免使用 Record 计算键） */
interface StringPair {
  key: string;
  value: string;
}

/** 默认快捷键映射条目（直接以静态数组形式提供，避免计算键字面量） */
interface DefaultMapEntry {
  code: string;
  action: ShortcutAction;
  param?: Object;
}

/** 默认快捷键映射（恢复默认的基线，不可变） */
const DEFAULT_SHORTCUT_LIST: DefaultMapEntry[] = [
  // 工具切换
  { code: 'XZ', action: ShortcutAction.SWITCH_TOOL, param: DrawTool.SELECT },
  { code: 'MY', action: ShortcutAction.SWITCH_TOOL, param: DrawTool.PAN },
  { code: 'YD', action: ShortcutAction.SWITCH_TOOL, param: DrawTool.MOVE },
  { code: 'JX', action: ShortcutAction.SWITCH_TOOL, param: DrawTool.RECT },
  { code: 'DB', action: ShortcutAction.SWITCH_TOOL, param: DrawTool.POLYGON },
  { code: 'LJ', action: ShortcutAction.SWITCH_TOOL, param: DrawTool.PATH },
  { code: 'SF', action: ShortcutAction.SWITCH_TOOL, param: DrawTool.INSTANCE },
  { code: 'CL', action: ShortcutAction.SWITCH_TOOL, param: DrawTool.MEASURE },
  { code: 'WB', action: ShortcutAction.SWITCH_TOOL, param: DrawTool.TEXT },

  // 编辑操作
  { code: 'CX', action: ShortcutAction.UNDO },
  { code: 'CZ', action: ShortcutAction.REDO },
  { code: 'SC', action: ShortcutAction.DELETE },
  { code: 'QX', action: ShortcutAction.SELECT_ALL },
  // SHORTCUT-2: 取消选择 / 切换网格（原先枚举有但无快捷码，不可达）
  // SHORTCUT-1: 重新分配避免前缀冲突——QXX 被 QX(SELECT_ALL) 贪婪匹配阻断，改用 QXJ
  { code: 'QXJ', action: ShortcutAction.DESELECT },
  { code: 'WG', action: ShortcutAction.TOGGLE_GRID },
  // TRANSFORM-1: 变换操作（旋转/镜像/缩放）
  // SHORTCUT-1: 重新分配避免前缀冲突
  // 原码 XZZ/XZN/XZX 被 XZ(SELECT) 阻断 → 改用 XSJ/XSQ/XSC（旋转90/180/270）
  { code: 'XSJ', action: ShortcutAction.ROTATE, param: 90 },
  { code: 'XSQ', action: ShortcutAction.ROTATE, param: 180 },
  { code: 'XSC', action: ShortcutAction.ROTATE, param: 270 },
  // 原码 JXH/JXV 被 JX(RECT) 阻断 → 改用 JXSH/JXC（镜像水平/垂直），但仍冲突，改用 MSH/MSV
  { code: 'MSH', action: ShortcutAction.MIRROR, param: 0 },
  { code: 'MSV', action: ShortcutAction.MIRROR, param: 1 },
  // 原码 SFF 被 SF(INSTANCE) 阻断 → 改用 SFB（缩放2倍）
  { code: 'SFB', action: ShortcutAction.SCALE, param: 2 },
  // SC-M2: 复制/粘贴/对齐/分布（拼音首字母，避免与现有码前缀冲突）
  // FZ=复制(FuZhi) / ZT=粘贴(ZhanTie) / DQZ=对齐左(DuiQi Zuo) / DQY=对齐右(DuiQi You)
  // DQS=对齐上(DuiQi Shang) / DQX=对齐下(DuiQi Xia) / DQH=水平居中 / DQV=垂直居中
  // FC=分布水平(FenBu) / FCS=分布垂直(FenBu Shuzhi)
  { code: 'FZ', action: ShortcutAction.COPY },
  { code: 'ZT', action: ShortcutAction.PASTE },
  { code: 'DQZ', action: ShortcutAction.ALIGN, param: 'left' },
  { code: 'DQY', action: ShortcutAction.ALIGN, param: 'right' },
  { code: 'DQS', action: ShortcutAction.ALIGN, param: 'top' },
  { code: 'DQX', action: ShortcutAction.ALIGN, param: 'bottom' },
  { code: 'DQH', action: ShortcutAction.ALIGN, param: 'centerH' },
  { code: 'DQV', action: ShortcutAction.ALIGN, param: 'centerV' },
  { code: 'FCS', action: ShortcutAction.DISTRIBUTE, param: 'horizontal' },
  { code: 'FCX', action: ShortcutAction.DISTRIBUTE, param: 'vertical' },

  // 视图操作
  { code: 'FD', action: ShortcutAction.ZOOM_IN },
  { code: 'SX', action: ShortcutAction.ZOOM_OUT },
  { code: 'QA', action: ShortcutAction.FIT_ALL },
  { code: 'KF', action: ShortcutAction.BOX_ZOOM },

  // 文件操作
  { code: 'DK', action: ShortcutAction.OPEN },
  { code: 'BC', action: ShortcutAction.SAVE },

  // DRC
  { code: 'YY', action: ShortcutAction.RUN_DRC },
];

/** 默认 actionKey → 中文标签（静态数组，避免计算键字面量） */
interface ActionLabelEntry {
  actionKey: string;
  label: string;
}

/** 根据 action 构造稳定 actionKey */
function buildActionKey(action: ShortcutAction, param?: Object): string {
  if (param !== undefined && param !== null) {
    return `${action}|${String(param)}`;
  }
  return `${action}|`;
}

/** 默认 actionKey → 中文标签列表（运行时构造，避免源码层计算键字面量） */
function buildActionLabels(): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  m.set(buildActionKey(ShortcutAction.SWITCH_TOOL, DrawTool.SELECT), '选择工具');
  m.set(buildActionKey(ShortcutAction.SWITCH_TOOL, DrawTool.MOVE), '移动工具（两点移动）');
  m.set(buildActionKey(ShortcutAction.SWITCH_TOOL, DrawTool.RECT), '矩形工具');
  m.set(buildActionKey(ShortcutAction.SWITCH_TOOL, DrawTool.POLYGON), '多边形工具');
  m.set(buildActionKey(ShortcutAction.SWITCH_TOOL, DrawTool.PATH), '路径工具');
  m.set(buildActionKey(ShortcutAction.SWITCH_TOOL, DrawTool.INSTANCE), '放置实例（弹窗）');
  m.set(buildActionKey(ShortcutAction.SWITCH_TOOL, DrawTool.MEASURE), '测量工具');
  m.set(buildActionKey(ShortcutAction.SWITCH_TOOL, DrawTool.TEXT), '文本工具');
  m.set(buildActionKey(ShortcutAction.UNDO), '撤销');
  m.set(buildActionKey(ShortcutAction.REDO), '重做');
  m.set(buildActionKey(ShortcutAction.DELETE), '删除选中');
  m.set(buildActionKey(ShortcutAction.SELECT_ALL), '全选');
  m.set(buildActionKey(ShortcutAction.DESELECT), '取消选择');
  m.set(buildActionKey(ShortcutAction.TOGGLE_GRID), '切换网格');
  m.set(buildActionKey(ShortcutAction.ZOOM_IN), '放大');
  m.set(buildActionKey(ShortcutAction.ZOOM_OUT), '缩小');
  m.set(buildActionKey(ShortcutAction.FIT_ALL), '适配全部');
  m.set(buildActionKey(ShortcutAction.BOX_ZOOM), '框选放大');
  m.set(buildActionKey(ShortcutAction.OPEN), '打开文件');
  m.set(buildActionKey(ShortcutAction.SAVE), '保存文件');
  m.set(buildActionKey(ShortcutAction.RUN_DRC), '运行 DRC');
  // TRANSFORM-1: 变换操作标签
  m.set(buildActionKey(ShortcutAction.ROTATE, 90), '旋转 90°');
  m.set(buildActionKey(ShortcutAction.ROTATE, 180), '旋转 180°');
  m.set(buildActionKey(ShortcutAction.ROTATE, 270), '旋转 270°');
  m.set(buildActionKey(ShortcutAction.MIRROR, 0), '水平镜像（沿 X 轴翻转）');
  m.set(buildActionKey(ShortcutAction.MIRROR, 1), '垂直镜像（沿 Y 轴翻转）');
  m.set(buildActionKey(ShortcutAction.SCALE, 2), '缩放 2x');
  // SC-M2: 复制/粘贴/对齐/分布标签
  m.set(buildActionKey(ShortcutAction.COPY), '复制选中');
  m.set(buildActionKey(ShortcutAction.PASTE), '粘贴剪贴板');
  m.set(buildActionKey(ShortcutAction.ALIGN, 'left'), '左对齐');
  m.set(buildActionKey(ShortcutAction.ALIGN, 'right'), '右对齐');
  m.set(buildActionKey(ShortcutAction.ALIGN, 'top'), '顶对齐');
  m.set(buildActionKey(ShortcutAction.ALIGN, 'bottom'), '底对齐');
  m.set(buildActionKey(ShortcutAction.ALIGN, 'centerH'), '水平居中');
  m.set(buildActionKey(ShortcutAction.ALIGN, 'centerV'), '垂直居中');
  m.set(buildActionKey(ShortcutAction.DISTRIBUTE, 'horizontal'), '水平分布');
  m.set(buildActionKey(ShortcutAction.DISTRIBUTE, 'vertical'), '垂直分布');
  return m;
}

const ACTION_LABELS: Map<string, string> = buildActionLabels();

/** Add only the new action to old profiles; never steal a custom code or prefix. */
function addMissingBoxZoom(map: Map<string, ShortcutMapEntry>): void {
  let present: boolean = false;
  map.forEach((entry: ShortcutMapEntry) => {
    if (entry.action === ShortcutAction.BOX_ZOOM) present = true;
  });
  if (present) return;
  // These initial letters are not claimed by Index's single-key tool bindings.
  const roots: string = 'KACDEHJNOQTUVWYZ';
  const endings: string = 'FZABCDEGHIJKLMNOPQRSTUVWXY';
  for (let i = 0; i < roots.length; i++) {
    for (let j = 0; j < endings.length; j++) {
      const candidate: string = roots[i] + endings[j];
      let conflict: boolean = false;
      map.forEach((_entry: ShortcutMapEntry, code: string) => {
        if (code.startsWith(candidate) || candidate.startsWith(code)) conflict = true;
      });
      if (!conflict) {
        map.set(candidate, { action: ShortcutAction.BOX_ZOOM });
        return;
      }
    }
  }
  // An exhausted custom profile stays intact; getShortcutList exposes an
  // unassigned action so the user can choose which binding to replace.
}

/** 深拷贝默认映射到 Map，避免污染基线 */
function cloneDefaultMap(): Map<string, ShortcutMapEntry> {
  const result: Map<string, ShortcutMapEntry> = new Map<string, ShortcutMapEntry>();
  for (let i = 0; i < DEFAULT_SHORTCUT_LIST.length; i++) {
    const item = DEFAULT_SHORTCUT_LIST[i];
    const copy: ShortcutMapEntry = item.param !== undefined
      ? { action: item.action, param: item.param }
      : { action: item.action };
    result.set(item.code, copy);
  }
  return result;
}

/** 当前激活的快捷键映射（用户可修改，跨重启保留） */
let activeShortcutMap: Map<string, ShortcutMapEntry> = cloneDefaultMap();

/** 根据 action 返回分类 */
function categoryFor(action: ShortcutAction): string {
  switch (action) {
    case ShortcutAction.SWITCH_TOOL:
      return '工具';
    case ShortcutAction.UNDO:
    case ShortcutAction.REDO:
    case ShortcutAction.DELETE:
    case ShortcutAction.SELECT_ALL:
    case ShortcutAction.DESELECT:
    case ShortcutAction.ROTATE:
    case ShortcutAction.MIRROR:
    case ShortcutAction.SCALE:
    case ShortcutAction.COPY:
    case ShortcutAction.PASTE:
    case ShortcutAction.ALIGN:
    case ShortcutAction.DISTRIBUTE:
      return '编辑';
    case ShortcutAction.ZOOM_IN:
    case ShortcutAction.ZOOM_OUT:
    case ShortcutAction.FIT_ALL:
    case ShortcutAction.BOX_ZOOM:
    case ShortcutAction.TOGGLE_GRID:
      return '视图';
    case ShortcutAction.OPEN:
    case ShortcutAction.SAVE:
      return '文件';
    case ShortcutAction.RUN_DRC:
      return '验证';
    default:
      return '其他';
  }
}

/** 校验字符串是否为合法 ShortcutAction 值 */
function isShortcutAction(value: string): boolean {
  return value === ShortcutAction.SWITCH_TOOL
    || value === ShortcutAction.UNDO
    || value === ShortcutAction.REDO
    || value === ShortcutAction.DELETE
    || value === ShortcutAction.ZOOM_IN
    || value === ShortcutAction.ZOOM_OUT
    || value === ShortcutAction.FIT_ALL
    || value === ShortcutAction.SELECT_ALL
    || value === ShortcutAction.DESELECT
    || value === ShortcutAction.TOGGLE_GRID
    || value === ShortcutAction.SAVE
    || value === ShortcutAction.OPEN
    || value === ShortcutAction.RUN_DRC
    || value === ShortcutAction.ROTATE
    || value === ShortcutAction.MIRROR
    || value === ShortcutAction.SCALE
    || value === ShortcutAction.COPY
    || value === ShortcutAction.PASTE
    || value === ShortcutAction.ALIGN
    || value === ShortcutAction.DISTRIBUTE
    || value === ShortcutAction.NUDGE
    || value === ShortcutAction.BOX_ZOOM
    || value === ShortcutAction.VIEW_BACK
    || value === ShortcutAction.ESCAPE;
}

function isAllowedStringParam(action: ShortcutAction, param: string): boolean {
  switch (action) {
    case ShortcutAction.SWITCH_TOOL:
      return param === String(DrawTool.SELECT)
        || param === String(DrawTool.MOVE)
        || param === String(DrawTool.RECT)
        || param === String(DrawTool.POLYGON)
        || param === String(DrawTool.PATH)
        || param === String(DrawTool.INSTANCE)
        || param === String(DrawTool.MEASURE)
        || param === String(DrawTool.TEXT);
    case ShortcutAction.ALIGN:
      return param === 'left'
        || param === 'right'
        || param === 'top'
        || param === 'bottom'
        || param === 'centerH'
        || param === 'centerV';
    case ShortcutAction.DISTRIBUTE:
      return param === 'horizontal' || param === 'vertical';
    default:
      return false;
  }
}

/** 根据 actionKey 反解出 ShortcutMapEntry，非法时返回 null */
function entryFromActionKey(actionKey: string): ShortcutMapEntry | null {
  const parts = actionKey.split('|');
  if (parts.length !== 2) {
    return null;
  }
  const action = parts[0] as ShortcutAction;
  const paramStr = parts[1];
  if (!isShortcutAction(action)) {
    return null;
  }
  if (paramStr.length === 0) {
    return { action: action };
  }
  if (isAllowedStringParam(action, paramStr)) {
    return { action: action, param: action === ShortcutAction.SWITCH_TOOL ? Number(paramStr) : paramStr };
  }
  const num = Number(paramStr);
  if (Number.isNaN(num)) {
    return null;
  }
  return { action: action, param: num };
}

/** 获取所有快捷键列表（基于 activeShortcutMap，用于帮助面板与编辑） */
export function getShortcutList(): ShortcutEntry[] {
  const result: ShortcutEntry[] = [];
  activeShortcutMap.forEach((entry: ShortcutMapEntry, code: string) => {
    const actionKey = buildActionKey(entry.action, entry.param);
    const label = ACTION_LABELS.get(actionKey) ?? actionKey;
    const item: ShortcutEntry = {
      keys: code,
      action: entry.action,
      description: label,
      category: categoryFor(entry.action),
      actionKey: actionKey,
    };
    result.push(item);
  });
  if (!result.some((item: ShortcutEntry) => item.action === ShortcutAction.BOX_ZOOM)) {
    result.push({ keys: '', action: ShortcutAction.BOX_ZOOM, description: '框选放大',
      category: '视图', actionKey: buildActionKey(ShortcutAction.BOX_ZOOM) });
  }
  return result;
}

/**
 * 快捷键服务
 *
 * 管理快捷键输入缓冲区，在 800ms 窗口内收集字母并匹配。
 * 同时负责 profile 的导入/导出、冲突检查与持久化。
 */
export class ShortcutService {
  private buffer: string = '';
  /** Explicit Space prefix separates mnemonics from immediate single-key tools. */
  private mnemonicMode: boolean = false;
  private mnemonicTimer: number = -1;
  private lastInputTime: number = 0;
  private readonly TIMEOUT_MS: number = 800;
  private onAction: ((action: ShortcutAction, param?: Object) => void) | null = null;
  private initialized: boolean = false;
  private readonly STORAGE_KEY: string = 'shortcutProfile';

  constructor() {
    this.init();
  }

  /**
   * 初始化：绑定持久化键并加载已存 profile。幂等。
   *
   * 与 AiService.loadConfig 同款 try/catch 包裹，避免在应用启动早期
   * 持久化 API 不可用时抛出。
   */
  init(): void {
    if (this.initialized) {
      return;
    }
    try {
      PersistentStorage.persistProp(this.STORAGE_KEY, '');
      const stored: string = AppStorage.get<string>(this.STORAGE_KEY) ?? '';
      if (stored.length > 0) {
        this.loadProfileJson(stored);
      }
      this.initialized = true;
    } catch (e) {
      // 持久化绑定失败时仍可使用默认映射
      this.initialized = false;
    }
  }

  /** UI 端在 aboutToAppear 调用以确保已初始化（幂等） */
  ensureInitialized(): void {
    this.init();
  }

  /** 设置动作回调 */
  setHandler(handler: (action: ShortcutAction, param?: Object) => void): void {
    this.onAction = handler;
  }

  /**
   * 输入一个字母
   * @param key 按键（大写字母）
   * @returns 是否匹配成功
   */
  input(key: string): boolean {
    const now = Date.now();

    // 超时重置缓冲区
    if (now - this.lastInputTime > this.TIMEOUT_MS) {
      // SHORTCUT-1: 超时前检查是否有被暂挂的精确匹配（因存在更长前缀码而未触发），
      // 补触发避免 QX/SF 等两字母码静默失败（QX 被 QXJ 阻断、SF 被 SFB 阻断）
      if (this.buffer.length > 0) {
        const pendingEntry = activeShortcutMap.get(this.buffer);
        if (pendingEntry !== undefined && this.onAction) {
          this.onAction(pendingEntry.action, pendingEntry.param);
        }
      }
      this.buffer = '';
    }

    this.buffer += key.toUpperCase();
    this.lastInputTime = now;

    // SHORTCUT-1: 优先最长码匹配——精确匹配后检查是否还有更长的码以当前 buffer 为前缀，
    // 若有则继续等待用户输入（避免贪婪匹配阻断三字母码）；
    // 超时后由下次 input 的超时检查触发清空，但为避免用户等待 800ms 才触发两字母码，
    // 这里采用折中：精确匹配后立即检查更长前缀，无更长前缀才立即触发。
    const entry = activeShortcutMap.get(this.buffer);
    if (entry !== undefined) {
      // 检查是否存在以当前 buffer 为前缀的更长的码
      let hasLongerPrefix = false;
      activeShortcutMap.forEach((_v: ShortcutMapEntry, code: string) => {
        if (code.length > this.buffer.length && code.startsWith(this.buffer)) {
          hasLongerPrefix = true;
        }
      });
      if (!hasLongerPrefix) {
        // 无更长码，立即触发
        if (this.onAction) {
          this.onAction(entry.action, entry.param);
        }
        this.buffer = '';
        return true;
      }
      // 有更长码，暂不触发，等待用户继续输入（return false 让 UI 显示缓冲区）
      return false;
    }

    // 检查是否是某个快捷键的前缀
    let isPrefix = false;
    activeShortcutMap.forEach((_v: ShortcutMapEntry, code: string) => {
      if (code.startsWith(this.buffer)) {
        isPrefix = true;
      }
    });
    if (!isPrefix) {
      // SC-H4: 当前 buffer 无匹配且无更长前缀时，检查去掉最后一位后是否为已成立的精确匹配
      // 场景：QX 是 SELECT_ALL 的精确码，但被 QXJ(DESELECT) 阻断等待；
      // 用户误输 A → buffer="QXA"，无匹配无前缀，原实现直接清空丢失 SELECT_ALL
      if (this.buffer.length > 1) {
        const prevBuffer: string = this.buffer.substring(0, this.buffer.length - 1);
        const prevEntry = activeShortcutMap.get(prevBuffer);
        if (prevEntry !== undefined && this.onAction) {
          this.onAction(prevEntry.action, prevEntry.param);
        }
      }
      this.buffer = '';
    }

    return false;
  }

  /** Continue an active mnemonic before Index tries single-key tools (KF vs F). */
  consumeInput(key: string): boolean {
    if (this.mnemonicMode) {
      const upper: string = key.toUpperCase();
      if (!/^[A-Z]$/.test(upper)) return false;
      if (this.mnemonicTimer !== -1) { clearTimeout(this.mnemonicTimer); this.mnemonicTimer = -1; }
      if (Date.now() - this.lastInputTime > this.TIMEOUT_MS && this.buffer.length > 0) {
        // An expired partial code must not reinterpret its tail as another edit.
        this.commitMnemonic(); return true;
      }
      // Explicit mode treats an invalid suffix as cancellation. The legacy
      // input API may resolve a shorter exact prefix, but an accidental tail
      // must never execute a destructive short command in this mode.
      const combined: string = this.buffer + upper;
      let validPrefix: boolean = false;
      activeShortcutMap.forEach((_entry: ShortcutMapEntry, code: string) => {
        if (code.startsWith(combined)) validPrefix = true;
      });
      if (!validPrefix) { this.clear(); return true; }
      this.input(upper);
      if (this.buffer.length === 0) this.mnemonicMode = false;
      else if (this.mnemonicMode) {
        const expected: string = this.buffer;
        this.mnemonicTimer = setTimeout((): void => {
          this.mnemonicTimer = -1;
          if (this.mnemonicMode && this.buffer === expected) this.commitMnemonic();
        }, this.TIMEOUT_MS);
      }
      return true;
    }
    if (this.buffer.length === 0) return false;
    const upper: string = key.toUpperCase();
    if (!/^[A-Z]$/.test(upper)) return false;
    if (Date.now() - this.lastInputTime > this.TIMEOUT_MS) {
      const pending: ShortcutMapEntry | undefined = activeShortcutMap.get(this.buffer);
      this.buffer = '';
      if (pending !== undefined && this.onAction !== null) this.onAction(pending.action, pending.param);
      return false;
    }
    const combined: string = this.buffer + upper;
    let continuation: boolean = false;
    activeShortcutMap.forEach((_entry: ShortcutMapEntry, code: string) => {
      if (code.startsWith(combined)) continuation = true;
    });
    this.input(upper);
    return continuation;
  }

  /** 获取当前缓冲区内容（用于 UI 显示） */
  getBuffer(): string {
    return this.buffer;
  }

  beginMnemonic(): void {
    this.clear();
    this.mnemonicMode = true;
    this.lastInputTime = Date.now();
  }

  isMnemonicMode(): boolean { return this.mnemonicMode; }

  /** Enter or timeout resolves exact shorter codes; incomplete codes are cancelled. */
  commitMnemonic(): boolean {
    if (!this.mnemonicMode) return false;
    const entry: ShortcutMapEntry | undefined = activeShortcutMap.get(this.buffer);
    this.clear();
    if (entry !== undefined && this.onAction !== null) this.onAction(entry.action, entry.param);
    return true;
  }

  /** 清空缓冲区 */
  clear(): void {
    if (this.mnemonicTimer !== -1) { clearTimeout(this.mnemonicTimer); this.mnemonicTimer = -1; }
    this.buffer = '';
    this.mnemonicMode = false;
  }

  /** 检查缓冲区是否活跃 */
  isActive(): boolean {
    return this.mnemonicMode || this.buffer.length > 0;
  }

  /**
   * 导出当前 profile 为 JSON 字符串。
   * 格式：{ actionKey: code, ... }，缩进 2 空格，便于阅读与跨设备拷贝。
   */
  exportProfile(): string {
    return this.profileJson(activeShortcutMap);
  }

  private profileJson(mapping: Map<string, ShortcutMapEntry>): string {
    const pairs: StringPair[] = [];
    mapping.forEach((entry: ShortcutMapEntry, code: string) => {
      const actionKey = buildActionKey(entry.action, entry.param);
      pairs.push({ key: actionKey, value: code });
    });
    // 用 Record<string, string> 构造 JSON 对象，键为静态字符串字段（无计算键）
    const obj: Record<string, string> = {};
    for (let i = 0; i < pairs.length; i++) {
      obj[pairs[i].key] = pairs[i].value;
    }
    return JSON.stringify(obj, null, 2);
  }

  /**
   * 导入 profile JSON。
   * 校验 → 冲突检查 → 加载 → 持久化。
   * @returns ImportResult
   */
  importProfile(json: string): ImportResult {
    const trimmed = json.trim();
    if (trimmed.length === 0) {
      const r: ImportResult = { ok: false, error: 'JSON 为空' };
      return r;
    }
    let obj: Record<string, string>;
    try {
      const parsed: Object = JSON.parse(trimmed);
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        const r: ImportResult = { ok: false, error: 'JSON 顶层必须是对象（actionKey → code）' };
        return r;
      }
      obj = parsed as Record<string, string>;
    } catch (e) {
      const r: ImportResult = { ok: false, error: 'JSON 解析失败：' + String(e) };
      return r;
    }
    const akKeys = Object.keys(obj);
    if (akKeys.length === 0) {
      const r: ImportResult = { ok: false, error: 'JSON 内无任何映射条目' };
      return r;
    }
    // 校验 actionKey 合法性 + 内部冲突检查
    const seenCodes: Map<string, string> = new Map<string, string>(); // code → actionKey
    const newMap: Map<string, ShortcutMapEntry> = new Map<string, ShortcutMapEntry>();
    for (let i = 0; i < akKeys.length; i++) {
      const ak = akKeys[i];
      const code = obj[ak];
      if (typeof code !== 'string' || code.length === 0) {
        const r: ImportResult = { ok: false, error: `动作 "${ak}" 的码无效` };
        return r;
      }
      // SHORTCUT-3: 校验 code 字符集（仅 A-Z 字母），与 setShortcut 的校验一致
      if (!/^[A-Za-z]+$/.test(code)) {
        const r: ImportResult = { ok: false, error: `动作 "${ak}" 的码 "${code}" 含非法字符（仅允许字母）` };
        return r;
      }
      const upper = code.toUpperCase();
      const entry = entryFromActionKey(ak);
      if (entry === null) {
        const r: ImportResult = { ok: false, error: `未知动作："${ak}"` };
        return r;
      }
      const existing = seenCodes.get(upper);
      if (existing !== undefined) {
        const r: ImportResult = { ok: false, error: `冲突：码 "${upper}" 同时绑定到 "${ak}" 与 "${existing}"` };
        return r;
      }
      seenCodes.set(upper, ak);
      newMap.set(upper, entry);
    }
    // 加载
    addMissingBoxZoom(newMap);
    return this.commitProfile(newMap);
  }

  /**
   * 冲突检查：返回 newCode 与现有码的冲突描述（除 actionKey 自身外）。
   * 仅完全相同视为冲突；运行时支持短码等待更长前缀后再补触发。
   * 无冲突返回 null。
   */
  checkConflict(actionKey: string, newCode: string): string | null {
    const upper = newCode.toUpperCase();
    let conflictDesc: string | null = null;
    activeShortcutMap.forEach((entry: ShortcutMapEntry, code: string) => {
      if (conflictDesc !== null) return;
      const existingActionKey = buildActionKey(entry.action, entry.param);
      if (existingActionKey === actionKey) return; // 排除自身
      // 完全相同
      if (code === upper) {
        conflictDesc = existingActionKey;
        return;
      }
    });
    return conflictDesc;
  }

  /**
   * 修改某个动作的快捷码。
   * @returns SetShortcutResult，ok=false 且 conflict 为占用方的 actionKey 表示冲突。
   */
  setShortcut(actionKey: string, newCode: string): SetShortcutResult {
    const upper = newCode.toUpperCase();
    // 校验 newCode：仅 A-Z 字母
    if (!/^[A-Za-z]+$/.test(upper)) {
      const r: SetShortcutResult = { ok: false };
      return r;
    }
    const entry = entryFromActionKey(actionKey);
    if (entry === null) {
      const r: SetShortcutResult = { ok: false };
      return r;
    }
    // 冲突检查（排除自身）
    const conflict = this.checkConflict(actionKey, upper);
    if (conflict !== null) {
      const r: SetShortcutResult = { ok: false, conflict: conflict };
      return r;
    }
    // 找到旧码并移除（避免同一动作残留多个码）
    const oldCode = this.findCodeByActionKey(actionKey);
    const next: Map<string, ShortcutMapEntry> = new Map<string, ShortcutMapEntry>(activeShortcutMap);
    if (oldCode !== null && oldCode !== upper) {
      next.delete(oldCode);
    }
    next.set(upper, entry);
    return this.commitProfile(next);
  }

  /** 恢复默认映射并持久化 */
  resetToDefault(): ImportResult {
    return this.commitProfile(cloneDefaultMap());
  }

  /** 获取动作的中文标签 */
  getActionLabel(actionKey: string): string {
    return ACTION_LABELS.get(actionKey) ?? actionKey;
  }

  /** 获取所有快捷键列表（实例方法，便于组件通过 shortcutService 调用） */
  getShortcutList(): ShortcutEntry[] {
    return getShortcutList();
  }

  /** Publish a new runtime profile only after storage accepts and reads back the exact JSON. */
  private commitProfile(next: Map<string, ShortcutMapEntry>): ImportResult {
    let previous: string | undefined;
    let writeAttempted: boolean = false;
    try {
      previous = AppStorage.get<string>(this.STORAGE_KEY);
      const json: string = this.profileJson(next);
      writeAttempted = true;
      AppStorage.setOrCreate<string>(this.STORAGE_KEY, json);
      if (AppStorage.get<string>(this.STORAGE_KEY) !== json) {
        throw new Error('存储未确认写入');
      }
      activeShortcutMap = next;
      this.clear();
      return { ok: true };
    } catch (e) {
      // A platform error can occur after a write; restore the prior profile when possible.
      let rollbackError: string = '';
      if (writeAttempted) {
        try {
          if (AppStorage.get<string>(this.STORAGE_KEY) !== previous) {
            const oldJson: string = previous ?? '';
            AppStorage.setOrCreate<string>(this.STORAGE_KEY, oldJson);
            if (AppStorage.get<string>(this.STORAGE_KEY) !== oldJson) {
              throw new Error('存储未确认恢复');
            }
          }
        } catch (rollback) { rollbackError = `；旧存储恢复失败：${String(rollback)}`; }
      }
      return { ok: false, error: `快捷键保存失败：${String(e)}${rollbackError}` };
    }
  }

  /** 解析 profile JSON 并加载到 activeShortcutMap（内部用，不持久化、不报错） */
  private loadProfileJson(json: string): boolean {
    try {
      const parsed: Object = JSON.parse(json);
      const obj = parsed as Record<string, string>;
      const newMap: Map<string, ShortcutMapEntry> = new Map<string, ShortcutMapEntry>();
      const keys = Object.keys(obj);
      for (let i = 0; i < keys.length; i++) {
        const actionKey = keys[i];
        const code = obj[actionKey];
        const entry = entryFromActionKey(actionKey);
        if (entry === null || typeof code !== 'string' || code.length === 0) {
          continue;
        }
        newMap.set(code.toUpperCase(), entry);
      }
      if (newMap.size === 0) {
        return false;
      }
      addMissingBoxZoom(newMap);
      activeShortcutMap = newMap;
      this.clear();
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 在 activeShortcutMap 中查找 actionKey 对应的当前 code */
  private findCodeByActionKey(actionKey: string): string | null {
    let found: string | null = null;
    activeShortcutMap.forEach((entry: ShortcutMapEntry, code: string) => {
      if (found === null && buildActionKey(entry.action, entry.param) === actionKey) {
        found = code;
      }
    });
    return found;
  }
}

/** 快捷键服务单例 */
export const shortcutService = new ShortcutService();
