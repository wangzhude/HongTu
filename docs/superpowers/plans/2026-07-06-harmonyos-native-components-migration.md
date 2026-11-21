# 鸿图鸿蒙原生组件迁移实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将鸿图项目中所有可替换为鸿蒙原生的自定义 UI 实现逐步迁移到 ArkUI 原生组件/API，涵盖弹窗、菜单、布局容器、图标、动画、手势、字体、反馈、状态管理，以提升可维护性、性能与跨设备体验。

**Architecture:** 采用分阶段渐进式重构：先建立主题色/字体等基础设施，再逐层替换弹窗、菜单、布局、图标、动画、手势，最后升级状态管理。每个阶段独立可交付、可构建、可回退。渲染核心（XComponent + OpenGL ES）保持不变，所有重构聚焦 ArkTS UI 层与服务层 API。

**Tech Stack:** HarmonyOS NEXT (API 12+)、ArkTS、ArkUI V2 装饰器（@ComponentV2/@ObservedV2/@Trace）、hvigor 构建、XComponent + NAPI + OpenGL ES（渲染层不动）

---

## 调研结论摘要

### A. 当前项目自定义实现清单（可替换为原生）

| # | 自定义实现 | 位置 | 行数 | 原生替换 |
|---|---|---|---|---|
| 1 | 硬编码 COLORS 常量对象 | common/constants.ets:40-64 | - | ColorMetrics + AppStorageV2 |
| 2 | 6 处自定义弹窗（Stack 遮罩 + Column） | InstancePlaceDialog.ets:121-379、Index.ets:322-421(OpenWizardDialog)、LayoutCanvasView.ets:700-785(MoveFineTuneDialog)、LayoutCanvasView.ets:789-850(TextCreateDialog)、WorkbenchSidebar.ets:314-360(保存预设)、WorkbenchOverlays.ets:821-880(导入Profile) | ~600 | @CustomDialog / bindSheet |
| 3 | 整个 ContextMenu 组件 | ContextMenu.ets | 310 | bindContextMenu + Menu + MenuItem + MenuItemGroup |
| 4 | 3 处分段控件（Text 按钮组） | WorkbenchTitleBar.ets:74-99(模块tabs+视图模式)、WorkbenchInspector.ets:264-280(规则集选择) | - | SegmentButton / Tabs |
| 5 | 三栏布局（Row + layoutWeight） | Index.ets:425-710 | - | SideBarContainer(AUTO) |
| 6 | 浮层抽屉（手动遮罩 + Row） | Index.ets:720-810 | - | bindSheet / SideBarContainer Overlay |
| 7 | 全项目图标（Text + Unicode/emoji） | EditorToolbar:41-82、WorkbenchTitleBar、StatusBar、WorkbenchSidebar、LayoutCanvasView、ContextMenu、WorkbenchOverlays、InstancePlaceDialog | ~30处 | SymbolGlyph |
| 8 | 违规闪烁动画（setInterval） | LayoutCanvasView.ets:140-201 | - | animateTo + iterations:-1 |
| 9 | 浮层/抽屉无转场动画 | Index.ets:720-810、WorkbenchOverlays 全部面板 | - | transition + TransitionEffect |
| 10 | 画布平移（onTouch 手动计算） | LayoutCanvasView.ets:377-400 | - | PanGesture |
| 11 | 画布手势未组合 | LayoutCanvasView.ets:377-400 | - | parallelGesture / exclusiveGesture |
| 12 | Sidebar 图层/工具列表（Scroll+Column+ForEach） | WorkbenchSidebar.ets:213-295 | - | List + ListItem + LazyForEach |
| 13 | DRC 规则启用开关（Text 启用/停用） | WorkbenchInspector.ets:800-909 | - | Toggle / Checkbox |
| 14 | Text(应用)/Text(添加) 文本按钮 | WorkbenchInspector、WorkbenchSidebar 多处 | - | Button |
| 15 | 系统字体 fontFamily('monospace') | EditorToolbar:77、StatusBar:37/48/55/62/70/80/88、LayoutCanvasView:1499/1503/1508/1513 | - | FontRegistry.registerFont |
| 16 | 状态反馈仅靠 statusText | 全局 | - | promptAction.showToast |
| 17 | 文本宽度估算（length*8+12） | LayoutCanvasView.ets:1431 | - | @ohos.measure.measureText |
| 18 | 网络请求无连通性检测 | AiService.ets | - | @ohos.net.connection |
| 19 | 状态管理 V1（@State/@Prop/@Link） | 全项目 | - | @ObservedV2/@Trace/@ComponentV2（可选） |

### B. 已正确使用原生 API（无需改动，作为参照）

PersistentStorage + AppStorage、picker.DocumentViewPicker、fileIo、http、window + display、preferences、Select、Toggle、Slider、TextInput、TextArea、List、ListItem、Scroll、AlertDialog.show(2处)、XComponent、LongPressGesture、TapGesture、PinchGesture、@Builder。

### C. 关键风险提示

1. **ArkUI 无独立可拖拽 SplitContainer 组件**。可调节分隔条需 PanGesture + 状态绑定自行实现；或用 SideBarContainer 的 sideBarWidth 配合控制按钮。本计划采用 SideBarContainer(AUTO) 方案，放弃手动拖拽分隔条（当前代码本就无拖拽分隔条）。
2. **bindContextMenu 触发方式**：通过 ResponseMode.RightClick（桌面右键）/ LongPress（触屏长按），可统一替代当前 LongPressGesture 手动触发逻辑。
3. **SymbolGlyph 需要 HMSymbol 图标资源**。HarmonyOS 自带 HMSymbol 图标库，但版图编辑器的部分专业图标（如对齐、分布、网络追踪）可能无对应 HMSymbol，需用 Image + 自定义 SVG 资源兜底。
4. **V1/V2 装饰器不可混用**。若升级状态管理到 V2，需整个组件树一并迁移，工作量大。本计划将 V2 升级列为可选阶段（阶段十），其余阶段保持 V1。
5. **主题色重构是基础**。所有组件依赖 COLORS 常量，必须先迁移到 AppStorageV2，后续组件替换才能引用动态主题色。

---

## 文件结构映射

### 新建文件

| 文件 | 职责 |
|---|---|
| `entry/src/main/ets/common/Theme.ets` | 主题色管理：AppStorageV2 持久化的 ColorMetrics 对象、暗色/亮色切换、COLORS 兼容别名 |
| `entry/src/main/ets/common/Fonts.ets` | 字体注册：FontRegistry.registerFont 注册等宽字体，提供 fontFamily 常量 |
| `entry/src/main/ets/common/Icons.ets` | 图标定义：SymbolGlyph 字符常量 + 缺失图标的 Image 资源映射 |
| `entry/src/main/ets/common/MaterialTokens.ets` | 材质令牌：Elevation 枚举、ShadowStyle 映射、BlurStyle 按层级映射、RADIUS/ALPHA 令牌、withAlpha 工具 |
| `entry/src/main/cangjie/` | 仓颉混合开发模块根目录（cjpm 工程） |
| `entry/src/main/cangjie/cjpm.toml` | 仓颉包管理配置 |
| `entry/src/main/cangjie/src/main.cj` | 仓颉模块入口与 ArkTS 互操作注册 |
| `entry/src/main/cangjie/src/hongtu_ffi.cj` | 仓颉 FFI 层：@extern("C") 声明 libhongtu.so 的 C 接口、@repr(C) struct 与 C++ 结构体 1:1 映射 |
| `entry/src/main/cangjie/src/bridge.cj` | 仓颉桥接层：安全封装 FFI 调用、CFFI 导出到 ArkTS |
| `entry/src/main/cangjie/src/gdsii_writer.cj` | 仓颉 GDSII 写入器：ArrayBuffer 实现替代 ArkTS GdsByteWriter |
| `entry/src/main/cangjie/src/drc_engine.cj` | 仓颉 DRC 引擎：协程并行分块检查 + 空间网格索引 |
| `entry/src/main/cangjie/src/render_serializer.cj` | 仓颉渲染数据序列化：批次合并 + ArrayBuffer 零拷贝 |
| `entry/src/main/cangjie/src/models.cj` | 仓颉数据模型：value 类型 Point/ShapeBounds + 引用类型 Shape |
| `entry/src/main/cangjie/src/parallel_parser.cj` | 仓颉并行解析调度：GDSII 按 CELL 分块、OASIS CBLOCK 并行解压 |
| `entry/src/main/ets/services/CangjieBridge.ets` | ArkTS 侧仓颉模块加载与类型声明 |
| `entry/src/main/ets/components/dialogs/PlaceInstanceDialog.ets` | @CustomDialog：实例放置对话框（替换 InstancePlaceDialog） |
| `entry/src/main/ets/components/dialogs/OpenWizardDialog.ets` | @CustomDialog：大文件打开向导 |
| `entry/src/main/ets/components/dialogs/MoveFineTuneDialog.ets` | @CustomDialog：移动微调 |
| `entry/src/main/ets/components/dialogs/TextCreateDialog.ets` | @CustomDialog：文本创建 |
| `entry/src/main/ets/components/dialogs/PresetSaveDialog.ets` | @CustomDialog：预设保存（替换 WorkbenchSidebar 内联弹窗） |
| `entry/src/main/ets/components/dialogs/ProfileImportDialog.ets` | @CustomDialog：Profile 导入（替换 WorkbenchOverlays 内联弹窗） |
| `entry/src/main/ets/components/menus/CanvasContextMenu.ets` | @Builder：画布上下文菜单内容（配合 bindContextMenu） |
| `entry/src/main/ets/components/segments/ModuleSegment.ets` | 模块切换 SegmentButton 封装 |
| `entry/src/main/ets/components/segments/ViewModeSegment.ets` | 视图模式 SegmentButton 封装 |
| `entry/src/main/ets/components/segments/RulesetSegment.ets` | 规则集 SegmentButton 封装 |

### 修改文件

| 文件 | 修改内容 |
|---|---|
| `common/constants.ets` | 删除 COLORS 常量，改为从 Theme.ets 重导出（兼容期） |
| `components/workbench/InstancePlaceDialog.ets` | 替换为 PlaceInstanceDialog 的薄包装或删除 |
| `components/workbench/ContextMenu.ets` | 删除（迁移到 CanvasContextMenu + bindContextMenu） |
| `components/workbench/EditorToolbar.ets` | 图标改 SymbolGlyph/Image，按钮加 transition |
| `components/workbench/StatusBar.ets` | 图标改 SymbolGlyph，分隔符改 Divider |
| `components/workbench/WorkbenchTitleBar.ets` | 分段控件改 SegmentButton，图标改 SymbolGlyph，徽标改 Badge |
| `components/workbench/WorkbenchSidebar.ets` | 列表改 List+LazyForEach，图标改 SymbolGlyph，内联弹窗改引用 CustomDialog |
| `components/workbench/WorkbenchInspector.ets` | 规则集改 SegmentButton，启用开关改 Toggle，文本按钮改 Button，图标改 SymbolGlyph |
| `components/workbench/WorkbenchOverlays.ets` | 面板加 transition 转场，内联弹窗改引用 CustomDialog |
| `components/workbench/LayoutCanvasView.ets` | 闪烁动画改 animateTo，平移改 PanGesture，手势组合改 parallelGesture，文本测量改 measure |
| `pages/Index.ets` | 三栏布局改 SideBarContainer，浮层抽屉改 bindSheet，ContextMenuItem 触发改 bindContextMenu，弹窗调用改 CustomDialogController，遮罩改 backgroundBlurStyle，根容器加 expandSafeArea |
| `entryability/EntryAbility.ets` | onStart 中初始化 Theme 与 Fonts，onWindowStageCreate 启用沉浸式（setWindowLayoutFullScreen + setWindowSystemBarProperties） |
| `services/AiService.ets` | 请求前加 @ohos.net.connectivity 网络检测 |
| `services/NativeHongTuService.ets` | 阶段十一改用仓颉 CFFI 桥接替代直接 import libhongtu.so |
| `services/LayoutExportService.ets` | 阶段十一 GdsByteWriter 改用仓颉 ArrayBuffer 实现 |
| `services/DrcService.ets` | 阶段十一分块检查改用仓颉协程并行 |
| `services/FileImportService.ets` | 阶段十一解析改用仓颉并行调度 |
| `components/GlCanvas.ets` | 阶段十一 shapesToBatches 改用仓颉合并批次 + ArrayBuffer |
| `cpp/gdsii_reader.cpp`/`oasis_reader.cpp` | 阶段十一为仓颉 FFI 添加 extern "C" 导出 |
| `cpp/xcomponent_plugin.cpp` | 阶段十一 NapiSetRenderData 改为接收 ArrayBuffer 零拷贝 |
| `cpp/napi_init.cpp` | 阶段十一由仓颉 bridge.cj 替代（可逐步废弃） |
| `build-profile.json5`（模块级） | 声明 cangjieOptions 仓颉模块 |

---

## 实施阶段

### 阶段一：基础设施（主题色 + 字体 + 图标常量）

> 必须最先完成，所有后续阶段依赖主题色与图标常量。

#### Task 1.1: 创建主题色管理模块 Theme.ets

**Files:**
- Create: `entry/src/main/ets/common/Theme.ets`

- [ ] **Step 1: 创建 Theme.ets，定义 AppStorageV2 持久化的主题对象**

```typescript
// entry/src/main/ets/common/Theme.ets
import { AppStorageV2 } from '@kit.ArkUI';

/** 主题色集合，对应原 ColorPalette 接口（common/constants.ets:17-38），支持暗色/亮色切换 */
@ObservedV2
export class ThemeColors {
  // 品牌色
  @Trace primary: string = '#007AFF';
  @Trace primarySoft: string = '#E8F0FE';
  @Trace accent: string = '#0062CC';
  @Trace accentSoft: string = '#E8F0FE';
  // 语义色
  @Trace success: string = '#34C759';
  @Trace warning: string = '#FF9F0A';
  @Trace danger: string = '#FF3B30';
  // 中性色（注意：原字段名是 ink / muted，不是 textPrimary / textSecondary）
  @Trace bg: string = '#F5F5F7';
  @Trace surface: string = '#FFFFFF';
  @Trace surfaceMuted: string = '#FAFAFA';
  @Trace border: string = '#E5E5EA';
  @Trace ink: string = '#1D1D1F';
  @Trace muted: string = '#6E6E73';
  // 画布色
  @Trace canvasBg: string = '#1D1D2B';
  @Trace canvasGrid: string = 'rgba(255,255,255,0.03)';
  @Trace canvasGridMajor: string = 'rgba(255,255,255,0.07)';

  /** 切换到暗色主题 */
  applyDark(): void {
    this.bg = '#1C1C1E';
    this.surface = '#2C2C2E';
    this.surfaceMuted = '#3A3A3C';
    this.border = '#48484A';
    this.ink = '#F5F5F7';
    this.muted = '#AEAEB2';
    this.canvasBg = '#0D0D14';
  }

  /** 切换到亮色主题 */
  applyLight(): void {
    this.bg = '#F5F5F7';
    this.surface = '#FFFFFF';
    this.surfaceMuted = '#FAFAFA';
    this.border = '#E5E5EA';
    this.ink = '#1D1D1F';
    this.muted = '#6E6E73';
    this.canvasBg = '#1D1D2B';
  }
}

/** 全局主题单例，通过 AppStorageV2 持久化当前模式 */
export class ThemeManager {
  static readonly STORAGE_KEY = 'theme_colors';
  static readonly MODE_KEY = 'theme_mode';

  static init(): ThemeColors {
    const colors = new ThemeColors();
    AppStorageV2.connect(ThemeColors, this.STORAGE_KEY, colors);
    return colors;
  }

  static get(): ThemeColors {
    return AppStorageV2.connect(ThemeColors, this.STORAGE_KEY, new ThemeColors()) as ThemeColors;
  }

  static toggleDark(isDark: boolean): void {
    const colors = this.get();
    if (isDark) colors.applyDark();
    else colors.applyLight();
  }
}

/** 兼容别名：让现有 import { COLORS } from '../common/constants' 继续工作 */
export const COLORS_PROXY = ThemeManager.get();
```

- [ ] **Step 2: 在 constants.ets 中保留 COLORS 别名指向主题对象**

修改 `entry/src/main/ets/common/constants.ets`，将原 `export const COLORS = {...}` 替换为：

```typescript
import { ThemeManager } from './Theme';

/** 兼容别名：COLORS 现在是动态主题对象的代理引用 */
export const COLORS = ThemeManager.get();
```

- [ ] **Step 3: 在 EntryAbility.onStart 中初始化主题**

修改 `entry/src/main/ets/entryability/EntryAbility.ets`，在 `onCreate` 或 `onWindowStageCreate` 之前调用：

```typescript
import { ThemeManager } from '../common/Theme';

// 在 onCreate 回调中
ThemeManager.init();
// 根据 EntryAbility 上下文判断当前颜色模式
const colorMode = this.context.config?.colorMode;
ThemeManager.toggleDark(colorMode === 1); // 1 = COLOR_MODE_DARK
```

- [ ] **Step 4: 构建验证**

Run: `hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`
Expected: BUILD SUCCESSFUL，所有引用 COLORS 的文件编译通过（因为 COLORS 仍存在，仅底层换成动态对象）

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/common/Theme.ets entry/src/main/ets/common/constants.ets entry/src/main/ets/entryability/EntryAbility.ets
git commit -m "refactor(theme): 引入 AppStorageV2 动态主题色，保留 COLORS 兼容别名"
```

#### Task 1.2: 创建字体注册模块 Fonts.ets

**Files:**
- Create: `entry/src/main/ets/common/Fonts.ets`

- [ ] **Step 1: 创建 Fonts.ets，注册等宽字体**

```typescript
// entry/src/main/ets/common/Fonts.ets
import { font } from '@kit.ArkUI';

/** 已注册的字体族名常量 */
export const FONT_MONO = 'HongTuMono';
export const FONT_SANS = 'HongTuSans';

/** 注册自定义字体，需在 EntryAbility 启动时调用一次 */
export function registerFonts(context: Context): void {
  // JetBrainsMono 用于坐标/数值显示
  font.registerFont({
    familyName: FONT_MONO,
    familySrc: '/rawfile/docs/_shared/fonts/JetBrainsMono-Regular.ttf'
  });
  // InstrumentSans 用于 UI 文本
  font.registerFont({
    familyName: FONT_SANS,
    familySrc: '/rawfile/docs/_shared/fonts/InstrumentSans-Regular.ttf'
  });
}
```

- [ ] **Step 2: 在 EntryAbility 中调用 registerFonts**

修改 `entry/src/main/ets/entryability/EntryAbility.ets`：

```typescript
import { registerFonts } from '../common/Fonts';

// 在 onCreate 中，ThemeManager.init() 之后
registerFonts(this.context);
```

- [ ] **Step 3: 替换硬编码的 fontFamily('monospace')**

用 Grep 找到所有 `.fontFamily('monospace')` 调用（EditorToolbar.ets:77、StatusBar.ets:37/48/55/62/70/80/88、LayoutCanvasView.ets:1499/1503/1508/1513），逐处替换为 `.fontFamily(FONT_MONO)`：

```typescript
import { FONT_MONO } from '../common/Fonts';
// ...
.fontFamily(FONT_MONO)
```

- [ ] **Step 4: 构建验证**

Run: `hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`
Expected: BUILD SUCCESSFUL

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/common/Fonts.ets entry/src/main/ets/entryability/EntryAbility.ets entry/src/main/ets/components/workbench/EditorToolbar.ets entry/src/main/ets/components/workbench/StatusBar.ets entry/src/main/ets/components/workbench/LayoutCanvasView.ets
git commit -m "refactor(font): 用 FontRegistry 注册自定义等宽字体替换 monospace"
```

#### Task 1.3: 创建图标常量模块 Icons.ets

**Files:**
- Create: `entry/src/main/ets/common/Icons.ets`

- [ ] **Step 1: 创建 Icons.ets，定义图标常量**

```typescript
// entry/src/main/ets/common/Icons.ets

/**
 * 图标定义。优先使用 SymbolGlyph（HMSymbol 字体），
 * 无对应 HMSymbol 的专业图标用 Image + SVG 资源路径兜底。
 *
 * SymbolGlyph 的 glyph 取值参考 HarmonyOS 图标库：
 * https://developer.huawei.com/consumer/cn/doc/harmonyos-references/symbol-glyph
 */

/** 通用操作图标（SymbolGlyph 字符） */
export const Icon = {
  // 编辑操作
  undo: '\uE83D',        // 撤销
  redo: '\uE83E',        // 重做
  delete: '\uE8B0',      // 删除
  copy: '\uE8C0',        // 复制
  paste: '\uE8C1',       // 粘贴
  // 视图
  eye: '\uE7B3',         // 查看模式
  edit: '\uE80C',        // 编辑模式
  zoomIn: '\uE8A4',      // 放大
  zoomOut: '\uE8A5',     // 缩小
  fit: '\uE8A6',         // 适配
  reset: '\uE8A7',       // 重置
  home: '\uE8A8',        // 主页
  // 文件
  open: '\uE8C2',        // 打开（文件夹）
  save: '\uE8C3',        // 保存
  // 反馈
  warning: '\uE7C0',     // 警告
  info: '\uE7C1',        // 信息
  error: '\uE7C2',       // 错误
  // 功能
  ai: '\uE8D0',          // AI
  macro: '\uE8D1',       // 宏
  search: '\uE8D2',      // 搜索
  close: '\uE8D3',       // 关闭
  // 状态
  visible: '\uE7B3',     // 可见
  hidden: '\uE7B4',      // 隐藏
  expand: '\uE840',      // 展开 ▾
  collapse: '\uE841',    // 收起 ▸
} as const;

/** 专业图标（无 HMSymbol 对应，用 Image + SVG） */
export const IconResource = {
  alignLeft: $r('app.media.ic_align_left'),
  alignCenter: $r('app.media.ic_align_center'),
  alignRight: $r('app.media.ic_align_right'),
  alignTop: $r('app.media.ic_align_top'),
  alignMiddle: $r('app.media.ic_align_middle'),
  alignBottom: $r('app.media.ic_align_bottom'),
  distributeH: $r('app.media.ic_distribute_h'),
  distributeV: $r('app.media.ic_distribute_v'),
  move: $r('app.media.ic_move'),
  placeInstance: $r('app.media.ic_place_instance'),
  netTrace: $r('app.media.ic_net_trace'),
} as const;
```

> 注：上述 HMSymbol 字符码点为示意，实际值需查阅 HarmonyOS 图标库文档校准。若无对应图标，统一改用 Image + SVG 资源。本任务 Step 2 会创建占位 SVG 资源。

- [ ] **Step 2: 创建缺失的 SVG 图标资源（对齐/分布/移动/放置实例/网络追踪）**

在 `entry/src/main/resources/base/media/` 下创建以下 SVG 文件（每个为简洁线性图标，24x24，currentColor）：
- `ic_align_left.svg`、`ic_align_center.svg`、`ic_align_right.svg`
- `ic_align_top.svg`、`ic_align_middle.svg`、`ic_align_bottom.svg`
- `ic_distribute_h.svg`、`ic_distribute_v.svg`
- `ic_move.svg`、`ic_place_instance.svg`、`ic_net_trace.svg`

每个 SVG 内容示例（ic_align_left.svg）：

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <line x1="3" y1="3" x2="3" y2="21"/>
  <rect x="6" y="6" width="6" height="4"/>
  <rect x="6" y="14" width="10" height="4"/>
</svg>
```

- [ ] **Step 3: 构建验证**

Run: `hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`
Expected: BUILD SUCCESSFUL（Icons.ets 暂未被引用，仅确保资源编译通过）

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/ets/common/Icons.ets entry/src/main/resources/base/media/ic_*.svg
git commit -m "feat(icons): 添加图标常量模块与专业图标 SVG 资源"
```

---

### 阶段二：弹窗系统重构（6 处 → @CustomDialog）

> 将所有手动实现的 Stack 遮罩 + Column 弹窗迁移到 @CustomDialog + CustomDialogController，获得原生弹窗动画、焦点管理、Esc 关闭、蒙层点击关闭等能力。

#### Task 2.1: 创建 PlaceInstanceDialog（替换 InstancePlaceDialog）

**Files:**
- Create: `entry/src/main/ets/components/dialogs/PlaceInstanceDialog.ets`
- Modify: `entry/src/main/ets/components/workbench/InstancePlaceDialog.ets`（改为薄包装或删除）
- Modify: `entry/src/main/ets/pages/Index.ets`（改用 CustomDialogController）

- [ ] **Step 1: 创建 PlaceInstanceDialog.ets，用 @CustomDialog 实现实例放置对话框**

```typescript
// entry/src/main/ets/components/dialogs/PlaceInstanceDialog.ets
import { CustomDialogController } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { Icon } from '../../common/Icons';
import { CellOption } from '../../common/types';

@CustomDialog
export struct PlaceInstanceDialog {
  controller: CustomDialogController;
  @Prop cells: CellOption[] = [];
  @State selectedCellId: string = '';
  @State selectedCellIndex: number = 0;
  @State posXStr: string = '0';
  @State posYStr: string = '0';
  @State rotation: number = 0;
  @State mirror: string = 'none';
  @State errorMsg: string = '';
  onConfirm: (cellId: string, x: number, y: number, rotation: number, mirror: string) => void = () => {};

  aboutToAppear(): void {
    if (this.cells.length > 0) {
      this.selectedCellId = this.cells[0].value;
      this.selectedCellIndex = 0;
    }
    this.posXStr = '0';
    this.posYStr = '0';
    this.rotation = 0;
    this.mirror = 'none';
    this.errorMsg = '';
  }

  private handleConfirm(): void {
    const x = parseFloat(this.posXStr);
    const y = parseFloat(this.posYStr);
    if (isNaN(x) || isNaN(y)) {
      this.errorMsg = '坐标必须为数字';
      return;
    }
    if (!this.selectedCellId) {
      this.errorMsg = '请选择 Cell';
      return;
    }
    this.onConfirm(this.selectedCellId, x, y, this.rotation, this.mirror);
    this.controller.close();
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('放置实例').fontSize(16).fontColor(COLORS.ink).fontWeight(FontWeight.Medium)
        Blank()
        SymbolGlyph(Icon.close).fontSize(18).fontColor(COLORS.muted).onClick(() => this.controller.close())
      }.width('100%').padding(16)

      Divider().color(COLORS.border)

      // Cell 选择
      Column() {
        Text('Cell').fontSize(13).fontColor(COLORS.muted).margin({ bottom: 6 })
        Select(this.cells.map(c => ({ value: c.name })))
          .selected(this.selectedCellIndex)
          .value(this.cells[this.selectedCellIndex]?.name ?? '')
          .onSelect((index) => {
            this.selectedCellIndex = index;
            this.selectedCellId = this.cells[index].value;
          })
          .width('100%')
      }.alignItems(HorizontalAlign.Start).margin({ top: 16, left: 16, right: 16 })

      // 坐标输入
      Row() {
        Column() {
          Text('X (nm)').fontSize(13).fontColor(COLORS.muted).margin({ bottom: 6 })
          TextInput({ text: this.posXStr }).type(InputType.Number).onChange(v => this.posXStr = v).width('100%')
        }.layoutWeight(1)
        Column() {
          Text('Y (nm)').fontSize(13).fontColor(COLORS.muted).margin({ bottom: 6 })
          TextInput({ text: this.posYStr }).type(InputType.Number).onChange(v => this.posYStr = v).width('100%')
        }.layoutWeight(1).margin({ left: 12 })
      }.width('100%').margin({ top: 16, left: 16, right: 16 })

      // 旋转角度
      Column() {
        Text('旋转角度').fontSize(13).fontColor(COLORS.muted).margin({ bottom: 6 })
        Row({ space: 8 }) {
          ForEach([0, 90, 180, 270], (deg: number) => {
            Button(`${deg}°`)
              .fontSize(13)
              .backgroundColor(this.rotation === deg ? COLORS.primary : COLORS.surfaceMuted)
              .fontColor(this.rotation === deg ? '#FFFFFF' : COLORS.ink)
              .onClick(() => this.rotation = deg)
          })
        }
      }.alignItems(HorizontalAlign.Start).margin({ top: 16, left: 16, right: 16 })

      // 镜像
      Column() {
        Text('镜像').fontSize(13).fontColor(COLORS.muted).margin({ bottom: 6 })
        Row({ space: 8 }) {
          ForEach([{ label: '无', value: 'none' }, { label: 'X', value: 'x' }, { label: 'Y', value: 'y' }], (m) => {
            Button(m.label)
              .fontSize(13)
              .backgroundColor(this.mirror === m.value ? COLORS.primary : COLORS.surfaceMuted)
              .fontColor(this.mirror === m.value ? '#FFFFFF' : COLORS.ink)
              .onClick(() => this.mirror = m.value)
          })
        }
      }.alignItems(HorizontalAlign.Start).margin({ top: 16, left: 16, right: 16 })

      // 错误提示
      if (this.errorMsg.length > 0) {
        Text(this.errorMsg).fontSize(12).fontColor(COLORS.danger).margin({ top: 12, left: 16, right: 16 })
      }

      // 操作按钮
      Row() {
        Blank()
        Button('取消').backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).onClick(() => this.controller.close())
        Button('确认放置').backgroundColor(COLORS.primary).fontColor('#FFFFFF').margin({ left: 8 }).onClick(() => this.handleConfirm())
      }.width('100%').padding(16)
    }
    .width(360)
    .backgroundColor(COLORS.surface)
    .borderRadius(12)
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.18)', offsetX: 0, offsetY: 8 })
  }
}
```

- [ ] **Step 2: 在 Index.ets 中用 CustomDialogController 替换原 instanceDialogVisible 状态**

修改 `entry/src/main/ets/pages/Index.ets`：

```typescript
import { PlaceInstanceDialog } from '../components/dialogs/PlaceInstanceDialog';

// 在 @Entry struct 顶部声明 controller
private placeInstanceController: CustomDialogController = new CustomDialogController({
  builder: PlaceInstanceDialog({
    cells: this.placeableCells.map(c => ({ name: c.name, value: c.id })),
    onConfirm: (cellId, x, y, rotation, mirror) => this.confirmPlaceInstance(cellId, x, y, rotation, mirror)
  }),
  alignment: DialogAlignment.Center,
  customStyle: false
});

// 替换 openInstanceDialog()
private openInstanceDialog(): void {
  if (this.placeableCells.length === 0) {
    this.statusText = '无可放置的 Cell';
    return;
  }
  this.placeInstanceController.open();
}
```

删除原 `@State instanceDialogVisible: boolean = false` 及 Index.ets 中渲染 `<InstancePlaceDialog>` 的代码块。

- [ ] **Step 3: 构建验证**

Run: `hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: 手动验证**

启动应用 → 工具栏点击"放置实例" → 弹出原生对话框（带原生动画与蒙层）→ 选 Cell、输入坐标、选旋转/镜像 → 确认放置 → 图形出现在画布。Esc/点蒙层可关闭。

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/components/dialogs/PlaceInstanceDialog.ets entry/src/main/ets/pages/Index.ets
git rm entry/src/main/ets/components/workbench/InstancePlaceDialog.ets
git commit -m "refactor(dialog): 实例放置对话框改用 @CustomDialog"
```

#### Task 2.2: 创建 OpenWizardDialog（替换 Index.ets:322-421）

**Files:**
- Create: `entry/src/main/ets/components/dialogs/OpenWizardDialog.ets`
- Modify: `entry/src/main/ets/pages/Index.ets`

- [ ] **Step 1: 创建 OpenWizardDialog.ets**

```typescript
// entry/src/main/ets/components/dialogs/OpenWizardDialog.ets
import { CustomDialogController } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { Icon } from '../../common/Icons';

@CustomDialog
export struct OpenWizardDialog {
  controller: CustomDialogController;
  @Prop fileName: string = '';
  @Prop fileSizeMB: number = 0;
  @State mode: 'view' | 'edit' = 'view';
  onSelect: (mode: 'view' | 'edit') => void = () => {};

  private formatSize(): string {
    return this.fileSizeMB >= 1024 ? `${(this.fileSizeMB / 1024).toFixed(2)} GB` : `${this.fileSizeMB.toFixed(1)} MB`;
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        SymbolGlyph(Icon.warning).fontSize(22).fontColor(COLORS.warning)
        Text('大文件打开向导').fontSize(16).fontColor(COLORS.ink).fontWeight(FontWeight.Medium).margin({ left: 8 })
        Blank()
        SymbolGlyph(Icon.close).fontSize(18).fontColor(COLORS.muted).onClick(() => this.controller.close())
      }.width('100%')

      Text(`文件：${this.fileName}（${this.formatSize()}）`).fontSize(13).fontColor(COLORS.muted)
      Text('该文件较大，完整解析可能占用较多内存。请选择打开模式：').fontSize(13).fontColor(COLORS.muted)

      Row({ space: 12 }) {
        Column({ space: 6 }) {
          SymbolGlyph(Icon.eye).fontSize(28).fontColor(this.mode === 'view' ? COLORS.primary : COLORS.muted)
          Text('查看模式').fontSize(13).fontColor(this.mode === 'view' ? COLORS.primary : COLORS.ink)
          Text('快速扫描，仅显示图形').fontSize(11).fontColor(COLORS.muted)
        }
        .layoutWeight(1).padding(12).borderRadius(8)
        .backgroundColor(this.mode === 'view' ? COLORS.primarySoft : COLORS.surfaceMuted)
        .onClick(() => this.mode = 'view')

        Column({ space: 6 }) {
          SymbolGlyph(Icon.edit).fontSize(28).fontColor(this.mode === 'edit' ? COLORS.primary : COLORS.muted)
          Text('编辑模式').fontSize(13).fontColor(this.mode === 'edit' ? COLORS.primary : COLORS.ink)
          Text('完整解析，支持编辑').fontSize(11).fontColor(COLORS.muted)
        }
        .layoutWeight(1).padding(12).borderRadius(8)
        .backgroundColor(this.mode === 'edit' ? COLORS.primarySoft : COLORS.surfaceMuted)
        .onClick(() => this.mode = 'edit')
      }.width('100%').margin({ top: 8 })

      Row() {
        Blank()
        Button('取消').backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).onClick(() => this.controller.close())
        Button('打开').backgroundColor(COLORS.primary).fontColor('#FFFFFF').margin({ left: 8 }).onClick(() => {
          this.onSelect(this.mode);
          this.controller.close();
        })
      }.width('100%').margin({ top: 8 })
    }
    .width(380).padding(20)
    .backgroundColor(COLORS.surface).borderRadius(12)
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.18)', offsetY: 8 })
  }
}
```

- [ ] **Step 2: 在 Index.ets 中替换 promptOpenWizard 实现**

将原 `promptOpenWizard` 返回 Promise 的 @Builder 实现改为 CustomDialogController：

```typescript
private openWizardController: CustomDialogController = new CustomDialogController({
  builder: OpenWizardDialog({
    fileName: this.pendingOpenFileName ?? '',
    fileSizeMB: this.pendingOpenFileSizeMB ?? 0,
    onSelect: (mode) => this.confirmOpenWizard(mode)
  }),
  alignment: DialogAlignment.Center,
  customStyle: false
});

private promptOpenWizard(fileName: string, fileSizeMB: number): void {
  this.pendingOpenFileName = fileName;
  this.pendingOpenFileSizeMB = fileSizeMB;
  this.openWizardController.open();
}
```

删除原 `OpenWizardDialog` @Builder（Index.ets:322-421）及相关状态变量。

- [ ] **Step 3: 构建验证**

Run: `hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: 手动验证**

打开一个 ≥50MB 的 GDS 文件 → 弹出原生向导对话框 → 选择查看/编辑模式 → 打开 → 正确进入对应模式。

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/components/dialogs/OpenWizardDialog.ets entry/src/main/ets/pages/Index.ets
git commit -m "refactor(dialog): 大文件打开向导改用 @CustomDialog"
```

#### Task 2.3: 创建 MoveFineTuneDialog（替换 LayoutCanvasView.ets:700-785）

**Files:**
- Create: `entry/src/main/ets/components/dialogs/MoveFineTuneDialog.ets`
- Modify: `entry/src/main/ets/components/workbench/LayoutCanvasView.ets`

- [ ] **Step 1: 创建 MoveFineTuneDialog.ets**

```typescript
// entry/src/main/ets/components/dialogs/MoveFineTuneDialog.ets
import { CustomDialogController } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { Icon } from '../../common/Icons';

@CustomDialog
export struct MoveFineTuneDialog {
  controller: CustomDialogController;
  @State dxStr: string = '0';
  @State dyStr: string = '0';
  @State step: number = 10;
  onConfirm: (dx: number, dy: number) => void = () => {};

  private applyStep(axis: 'x' | 'y', delta: number): void {
    const current = parseFloat(axis === 'x' ? this.dxStr : this.dyStr) || 0;
    const newVal = current + delta;
    if (axis === 'x') this.dxStr = String(newVal);
    else this.dyStr = String(newVal);
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Text('移动微调').fontSize(16).fontColor(COLORS.ink).fontWeight(FontWeight.Medium)
        Blank()
        SymbolGlyph(Icon.close).fontSize(18).fontColor(COLORS.muted).onClick(() => this.controller.close())
      }.width('100%')

      // 步长
      Row() {
        Text('步长').fontSize(13).fontColor(COLORS.muted)
        Slider({ value: this.step, min: 1, max: 100, step: 1 })
          .layoutWeight(1).margin({ left: 12 })
          .onChange(v => this.step = Math.round(v))
        Text(`${this.step} nm`).fontSize(13).fontColor(COLORS.ink).width(56)
      }.width('100%')

      // X
      Row() {
        Text('ΔX (nm)').fontSize(13).fontColor(COLORS.muted).width(64)
        TextInput({ text: this.dxStr }).type(InputType.Number).onChange(v => this.dxStr = v).layoutWeight(1)
        Button('-').width(32).backgroundColor(COLORS.surfaceMuted).onClick(() => this.applyStep('x', -this.step))
        Button('+').width(32).backgroundColor(COLORS.surfaceMuted).margin({ left: 4 }).onClick(() => this.applyStep('x', this.step))
      }.width('100%')

      // Y
      Row() {
        Text('ΔY (nm)').fontSize(13).fontColor(COLORS.muted).width(64)
        TextInput({ text: this.dyStr }).type(InputType.Number).onChange(v => this.dyStr = v).layoutWeight(1)
        Button('-').width(32).backgroundColor(COLORS.surfaceMuted).onClick(() => this.applyStep('y', -this.step))
        Button('+').width(32).backgroundColor(COLORS.surfaceMuted).margin({ left: 4 }).onClick(() => this.applyStep('y', this.step))
      }.width('100%')

      Row() {
        Blank()
        Button('取消').backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).onClick(() => this.controller.close())
        Button('应用').backgroundColor(COLORS.primary).fontColor('#FFFFFF').margin({ left: 8 }).onClick(() => {
          this.onConfirm(parseFloat(this.dxStr) || 0, parseFloat(this.dyStr) || 0);
          this.controller.close();
        })
      }.width('100%')
    }
    .width(360).padding(20)
    .backgroundColor(COLORS.surface).borderRadius(12)
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.18)', offsetY: 8 })
  }
}
```

- [ ] **Step 2: 在 LayoutCanvasView 中替换原 MoveFineTuneDialog @Builder**

将 `LayoutCanvasView.ets` 中的 `MoveFineTuneDialog` @Builder（700-785行）与 `showMoveFineTune` 状态逻辑替换为 CustomDialogController 调用。注意 LayoutCanvasView 是子组件，CustomDialogController 需通过回调让 Index.ets 持有并 open，或在 LayoutCanvasView 内部声明。

```typescript
import { MoveFineTuneDialog } from '../dialogs/MoveFineTuneDialog';

// 在 LayoutCanvasView struct 内
private fineTuneController: CustomDialogController = new CustomDialogController({
  builder: MoveFineTuneDialog({
    onConfirm: (dx, dy) => this.applyFineTune(dx, dy)
  }),
  alignment: DialogAlignment.Center,
  customStyle: false
});

private showMoveFineTune(): void {
  this.fineTuneController.open();
}

private applyFineTune(dx: number, dy: number): void {
  // 原有 onMoveConfirm 逻辑
  this.onMoveConfirm(dx, dy);
}
```

- [ ] **Step 3: 构建验证**

Run: `hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: 手动验证**

选中图形 → 长按 → 微调弹窗 → 调步长、±按钮 → 应用 → 图形按增量移动。

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/components/dialogs/MoveFineTuneDialog.ets entry/src/main/ets/components/workbench/LayoutCanvasView.ets
git commit -m "refactor(dialog): 移动微调弹窗改用 @CustomDialog"
```

#### Task 2.4: 创建 TextCreateDialog（替换 LayoutCanvasView.ets:789-850）

**Files:**
- Create: `entry/src/main/ets/components/dialogs/TextCreateDialog.ets`
- Modify: `entry/src/main/ets/components/workbench/LayoutCanvasView.ets`

- [ ] **Step 1: 创建 TextCreateDialog.ets**

```typescript
// entry/src/main/ets/components/dialogs/TextCreateDialog.ets
import { CustomDialogController } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { Icon } from '../../common/Icons';

@CustomDialog
export struct TextCreateDialog {
  controller: CustomDialogController;
  @Prop posX: number = 0;
  @Prop posY: number = 0;
  @State text: string = '';
  @State size: string = '100';
  @State errorMsg: string = '';
  onConfirm: (text: string, size: number) => void = () => {};

  build() {
    Column({ space: 14 }) {
      Row() {
        Text('添加文本').fontSize(16).fontColor(COLORS.ink).fontWeight(FontWeight.Medium)
        Blank()
        SymbolGlyph(Icon.close).fontSize(18).fontColor(COLORS.muted).onClick(() => this.controller.close())
      }.width('100%')

      Row() {
        Text('内容').fontSize(13).fontColor(COLORS.muted).width(48)
        TextInput({ text: this.text }).placeholder('输入文本').onChange(v => this.text = v).layoutWeight(1)
      }.width('100%')

      Row() {
        Text('大小').fontSize(13).fontColor(COLORS.muted).width(48)
        TextInput({ text: this.size }).type(InputType.Number).onChange(v => this.size = v).width(100)
        Text('nm').fontSize(13).fontColor(COLORS.muted).margin({ left: 6 })
      }.width('100%')

      if (this.errorMsg.length > 0) {
        Text(this.errorMsg).fontSize(12).fontColor(COLORS.danger)
      }

      Row() {
        Text(`位置：(${this.posX}, ${this.posY})`).fontSize(11).fontColor(COLORS.muted)
        Blank()
        Button('取消').backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).onClick(() => this.controller.close())
        Button('添加').backgroundColor(COLORS.primary).fontColor('#FFFFFF').margin({ left: 8 }).onClick(() => {
          if (!this.text) { this.errorMsg = '内容不能为空'; return; }
          const s = parseFloat(this.size);
          if (isNaN(s) || s <= 0) { this.errorMsg = '大小必须为正数'; return; }
          this.onConfirm(this.text, s);
          this.controller.close();
        })
      }.width('100%')
    }
    .width(360).padding(20)
    .backgroundColor(COLORS.surface).borderRadius(12)
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.18)', offsetY: 8 })
  }
}
```

- [ ] **Step 2: 在 LayoutCanvasView 中替换原 TextCreateDialog @Builder**

同 Task 2.3 模式，用 CustomDialogController 替换 `LayoutCanvasView.ets:789-850` 的 @Builder 与 `showTextCreateDialog` 状态。

- [ ] **Step 3: 构建验证**

Run: `hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: 手动验证**

选择文本工具 → 画布点击 → 弹窗 → 输入内容/大小 → 添加 → 文本图形出现在画布。

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/components/dialogs/TextCreateDialog.ets entry/src/main/ets/components/workbench/LayoutCanvasView.ets
git commit -m "refactor(dialog): 文本创建弹窗改用 @CustomDialog"
```

#### Task 2.5: 创建 PresetSaveDialog（替换 WorkbenchSidebar.ets:314-360）

**Files:**
- Create: `entry/src/main/ets/components/dialogs/PresetSaveDialog.ets`
- Modify: `entry/src/main/ets/components/workbench/WorkbenchSidebar.ets`

- [ ] **Step 1: 创建 PresetSaveDialog.ets**

```typescript
// entry/src/main/ets/components/dialogs/PresetSaveDialog.ets
import { CustomDialogController } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { Icon } from '../../common/Icons';

@CustomDialog
export struct PresetSaveDialog {
  controller: CustomDialogController;
  @State name: string = '';
  @State errorMsg: string = '';
  onConfirm: (name: string) => void = () => {};

  build() {
    Column({ space: 14 }) {
      Row() {
        Text('保存视图预设').fontSize(16).fontColor(COLORS.ink).fontWeight(FontWeight.Medium)
        Blank()
        SymbolGlyph(Icon.close).fontSize(18).fontColor(COLORS.muted).onClick(() => this.controller.close())
      }.width('100%')

      Text('请输入预设名称').fontSize(13).fontColor(COLORS.muted)
      TextInput({ text: this.name }).placeholder('预设名称').onChange(v => this.name = v)

      if (this.errorMsg.length > 0) {
        Text(this.errorMsg).fontSize(12).fontColor(COLORS.danger)
      }

      Row() {
        Blank()
        Button('取消').backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).onClick(() => this.controller.close())
        Button('保存').backgroundColor(COLORS.primary).fontColor('#FFFFFF').margin({ left: 8 }).onClick(() => {
          if (!this.name.trim()) { this.errorMsg = '名称不能为空'; return; }
          this.onConfirm(this.name.trim());
          this.controller.close();
        })
      }.width('100%')
    }
    .width(320).padding(20)
    .backgroundColor(COLORS.surface).borderRadius(12)
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.18)', offsetY: 8 })
  }
}
```

- [ ] **Step 2: 在 WorkbenchSidebar 中替换内联弹窗**

将 `WorkbenchSidebar.ets:314-360` 的 `if (showSavePresetDialog)` 内联弹窗改为通过回调触发父级 CustomDialogController（或直接在 Sidebar 内声明 controller）。

- [ ] **Step 3: 构建验证 + Commit**

```bash
git add entry/src/main/ets/components/dialogs/PresetSaveDialog.ets entry/src/main/ets/components/workbench/WorkbenchSidebar.ets
git commit -m "refactor(dialog): 预设保存弹窗改用 @CustomDialog"
```

#### Task 2.6: 创建 ProfileImportDialog（替换 WorkbenchOverlays.ets:821-880）

**Files:**
- Create: `entry/src/main/ets/components/dialogs/ProfileImportDialog.ets`
- Modify: `entry/src/main/ets/components/workbench/WorkbenchOverlays.ets`

- [ ] **Step 1: 创建 ProfileImportDialog.ets**

```typescript
// entry/src/main/ets/components/dialogs/ProfileImportDialog.ets
import { CustomDialogController } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { Icon } from '../../common/Icons';

@CustomDialog
export struct ProfileImportDialog {
  controller: CustomDialogController;
  @State jsonText: string = '';
  @State errorMsg: string = '';
  @State conflictInfo: string = '';
  onConfirm: (json: string) => void = () => {};

  build() {
    Column({ space: 14 }) {
      Row() {
        Text('导入快捷键 Profile').fontSize(16).fontColor(COLORS.ink).fontWeight(FontWeight.Medium)
        Blank()
        SymbolGlyph(Icon.close).fontSize(18).fontColor(COLORS.muted).onClick(() => this.controller.close())
      }.width('100%')

      Text('粘贴 Profile JSON 内容').fontSize(13).fontColor(COLORS.muted)
      TextArea({ text: this.jsonText }).placeholder('JSON 内容').onChange(v => this.jsonText = v).height(120).width('100%')

      if (this.conflictInfo.length > 0) {
        Text(this.conflictInfo).fontSize(12).fontColor(COLORS.warning)
      }
      if (this.errorMsg.length > 0) {
        Text(this.errorMsg).fontSize(12).fontColor(COLORS.danger)
      }

      Row() {
        Blank()
        Button('取消').backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).onClick(() => this.controller.close())
        Button('导入').backgroundColor(COLORS.primary).fontColor('#FFFFFF').margin({ left: 8 }).onClick(() => {
          if (!this.jsonText.trim()) { this.errorMsg = '内容不能为空'; return; }
          this.onConfirm(this.jsonText.trim());
          this.controller.close();
        })
      }.width('100%')
    }
    .width(420).padding(20)
    .backgroundColor(COLORS.surface).borderRadius(12)
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.18)', offsetY: 8 })
  }
}
```

- [ ] **Step 2: 在 WorkbenchOverlays 中替换内联弹窗**

将 `WorkbenchOverlays.ets:821-880` 的 `if (showImportDialog)` 内联弹窗改为 CustomDialogController 调用。

- [ ] **Step 3: 构建验证 + Commit**

```bash
git add entry/src/main/ets/components/dialogs/ProfileImportDialog.ets entry/src/main/ets/components/workbench/WorkbenchOverlays.ets
git commit -m "refactor(dialog): Profile 导入弹窗改用 @CustomDialog"
```

---

### 阶段三：菜单与分段控件

#### Task 3.1: 用 bindContextMenu + Menu 替换 ContextMenu 组件

**Files:**
- Create: `entry/src/main/ets/components/menus/CanvasContextMenu.ets`
- Modify: `entry/src/main/ets/pages/Index.ets`（删除 LongPressGesture 手动触发，改用 bindContextMenu）
- Delete: `entry/src/main/ets/components/workbench/ContextMenu.ets`

- [ ] **Step 1: 创建 CanvasContextMenu.ets，用 @Builder 定义菜单内容**

```typescript
// entry/src/main/ets/components/menus/CanvasContextMenu.ets
import { COLORS } from '../../common/constants';
import { Icon, IconResource } from '../../common/Icons';

/** 画布右键上下文菜单内容 Builder。
 *  配合 bindContextMenu 使用，由 Index.ets 在画布组件上绑定。 */
@Reusable
export struct CanvasContextMenuBuilder {
  @Builder
  static build(
    hasSelection: boolean,
    selectionCount: number,
    callbacks: {
      onEdit: () => void,
      onCopy: () => void,
      onPaste: () => void,
      onMeasure: () => void,
      onMoveTool: () => void,
      onAlign: (mode: string) => void,
      onDistribute: (mode: string) => void,
      onChangeLayer: (layerId: string) => void,
      onRunDrc: () => void,
      onLocateViolation: () => void,
      onDelete: () => void,
      onResetView: () => void,
      onEnterCell: () => void,
      onPlaceInstance: () => void,
    }
  ) {
    Menu() {
      MenuItem({ startIcon: Icon.edit, text: `编辑${hasSelection ? ` (${selectionCount})` : ''}` })
        .enabled(hasSelection).onClick(callbacks.onEdit)
      MenuItem({ startIcon: Icon.copy, text: '复制' }).enabled(hasSelection).onClick(callbacks.onCopy)
      MenuItem({ startIcon: Icon.paste, text: '粘贴' }).onClick(callbacks.onPaste)

      MenuItemGroup() {
        MenuItem({ startIcon: IconResource.move, text: '移动' }).enabled(hasSelection).onClick(callbacks.onMoveTool)
      }

      // 对齐子菜单
      MenuItem({ text: '对齐' }) {
        MenuItem({ startIcon: IconResource.alignLeft, text: '左对齐' }).enabled(hasSelection).onClick(() => callbacks.onAlign('left'))
        MenuItem({ startIcon: IconResource.alignCenter, text: '水平居中' }).enabled(hasSelection).onClick(() => callbacks.onAlign('hcenter'))
        MenuItem({ startIcon: IconResource.alignRight, text: '右对齐' }).enabled(hasSelection).onClick(() => callbacks.onAlign('right'))
        MenuItem({ startIcon: IconResource.alignTop, text: '顶对齐' }).enabled(hasSelection).onClick(() => callbacks.onAlign('top'))
        MenuItem({ startIcon: IconResource.alignMiddle, text: '垂直居中' }).enabled(hasSelection).onClick(() => callbacks.onAlign('vcenter'))
        MenuItem({ startIcon: IconResource.alignBottom, text: '底对齐' }).enabled(hasSelection).onClick(() => callbacks.onAlign('bottom'))
      }.enabled(hasSelection)

      // 分布子菜单
      MenuItem({ text: '分布' }) {
        MenuItem({ startIcon: IconResource.distributeH, text: '水平分布' }).enabled(hasSelection && selectionCount >= 3).onClick(() => callbacks.onDistribute('h'))
        MenuItem({ startIcon: IconResource.distributeV, text: '垂直分布' }).enabled(hasSelection && selectionCount >= 3).onClick(() => callbacks.onDistribute('v'))
      }.enabled(hasSelection && selectionCount >= 3)

      // 改图层子菜单
      MenuItem({ text: '改图层' }) {
        // 子项在 Index.ets 中通过动态生成，这里用占位 Builder
        ForEach(this.layerOptions, (opt: LayerOption) => {
          MenuItem({ text: opt.label }).enabled(hasSelection).onClick(() => callbacks.onChangeLayer(opt.value))
        })
      }.enabled(hasSelection)

      MenuItemGroup() {
        MenuItem({ startIcon: IconResource.placeInstance, text: '放置实例' }).onClick(callbacks.onPlaceInstance)
        MenuItem({ text: '进入子 Cell' }).enabled(hasSelection).onClick(callbacks.onEnterCell)
      }

      MenuItemGroup() {
        MenuItem({ startIcon: IconResource.netTrace, text: '运行 DRC' }).onClick(callbacks.onRunDrc)
        MenuItem({ text: '定位违规' }).onClick(callbacks.onLocateViolation)
      }

      MenuItemGroup() {
        MenuItem({ startIcon: Icon.reset, text: '重置视图' }).onClick(callbacks.onResetView)
        MenuItem({ startIcon: Icon.delete, text: '删除' }).enabled(hasSelection).onClick(callbacks.onDelete)
      }
    }
  }

  // 注：layerOptions 需由外部传入，Builder 内无法直接访问外部组件状态。
  // 实际实现改为：在 Index.ets 中用 @Builder 函数定义菜单内容，直接访问组件 @State layers。
}
```

> 说明：由于 ArkUI 的 @Builder 在静态上下文无法访问组件状态，实际菜单 Builder 应直接在 Index.ets 内定义为 @Builder 方法，可访问组件 @State。本任务的 Step 2 将在 Index.ets 内实现最终 Builder，CanvasContextMenu.ets 仅承载菜单项常量与类型定义。

- [ ] **Step 2: 在 Index.ets 中定义 @Builder 菜单内容并用 bindContextMenu 绑定到画布**

修改 `entry/src/main/ets/pages/Index.ets`：

```typescript
import { Menu, MenuItem, MenuItemGroup } from '@kit.ArkUI';

// 在 struct 内定义 @Builder
@Builder
buildCanvasContextMenu() {
  Menu() {
    MenuItem({ startIcon: Icon.edit, text: `编辑${this.selectedShapeIds.length > 0 ? ` (${this.selectedShapeIds.length})` : ''}` })
      .enabled(this.selectedShapeIds.length > 0).onClick(() => this.onContextEdit())
    MenuItem({ startIcon: Icon.copy, text: '复制' }).enabled(this.selectedShapeIds.length > 0).onClick(() => this.onContextCopy())
    MenuItem({ startIcon: Icon.paste, text: '粘贴' }).onClick(() => this.onContextPaste())
    MenuItem({ startIcon: IconResource.move, text: '移动' }).enabled(this.selectedShapeIds.length > 0).onClick(() => this.onContextMoveTool())

    MenuItem({ text: '对齐' }) {
      MenuItem({ startIcon: IconResource.alignLeft, text: '左对齐' }).enabled(this.selectedShapeIds.length > 0).onClick(() => this.onContextAlign('left'))
      MenuItem({ startIcon: IconResource.alignCenter, text: '水平居中' }).enabled(this.selectedShapeIds.length > 0).onClick(() => this.onContextAlign('hcenter'))
      MenuItem({ startIcon: IconResource.alignRight, text: '右对齐' }).enabled(this.selectedShapeIds.length > 0).onClick(() => this.onContextAlign('right'))
      MenuItem({ startIcon: IconResource.alignTop, text: '顶对齐' }).enabled(this.selectedShapeIds.length > 0).onClick(() => this.onContextAlign('top'))
      MenuItem({ startIcon: IconResource.alignMiddle, text: '垂直居中' }).enabled(this.selectedShapeIds.length > 0).onClick(() => this.onContextAlign('vcenter'))
      MenuItem({ startIcon: IconResource.alignBottom, text: '底对齐' }).enabled(this.selectedShapeIds.length > 0).onClick(() => this.onContextAlign('bottom'))
    }.enabled(this.selectedShapeIds.length > 0)

    MenuItem({ text: '分布' }) {
      MenuItem({ startIcon: IconResource.distributeH, text: '水平分布' }).enabled(this.selectedShapeIds.length >= 3).onClick(() => this.onContextDistribute('h'))
      MenuItem({ startIcon: IconResource.distributeV, text: '垂直分布' }).enabled(this.selectedShapeIds.length >= 3).onClick(() => this.onContextDistribute('v'))
    }.enabled(this.selectedShapeIds.length >= 3)

    MenuItem({ text: '改图层' }) {
      ForEach(this.layers, (layer: LayerInfo) => {
        MenuItem({ text: `${layer.index} ${layer.name}` }).enabled(this.selectedShapeIds.length > 0).onClick(() => this.onContextChangeLayer(layer.id))
      })
    }.enabled(this.selectedShapeIds.length > 0)

    MenuItem({ startIcon: IconResource.placeInstance, text: '放置实例' }).onClick(() => this.openInstanceDialog())
    MenuItem({ text: '进入子 Cell' }).enabled(this.selectedShapeIds.length === 1).onClick(() => this.onContextEnterCell())
    MenuItem({ startIcon: IconResource.netTrace, text: '运行 DRC' }).onClick(() => this.runDrcAction())
    MenuItem({ text: '定位违规' }).onClick(() => this.locateIssue())
    MenuItem({ startIcon: Icon.reset, text: '重置视图' }).onClick(() => this.resetView())
    MenuItem({ startIcon: Icon.delete, text: '删除' }).enabled(this.selectedShapeIds.length > 0).onClick(() => this.onContextDelete())
  }
}

// 在画布 Column 上绑定（替换原 LongPressGesture）
Column() {
  // ... 画布内容
}
.bindContextMenu(this.buildCanvasContextMenu, ResponseType.RightClick)
```

- [ ] **Step 3: 删除原 ContextMenu.ets 与相关状态**

删除 `entry/src/main/ets/components/workbench/ContextMenu.ets`，删除 Index.ets 中 `@State contextMenuVisible/X/Y`、`showContextMenu()`、`<ContextMenu>` 渲染块（971-1034行）。

- [ ] **Step 4: 构建验证**

Run: `hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`
Expected: BUILD SUCCESSFUL

- [ ] **Step 5: 手动验证**

- 桌面端：右键画布 → 弹出原生上下文菜单（带图标与子菜单）→ 点击各项功能正常
- 触屏端：长按画布 → 弹出菜单（bindContextMenu 默认支持长按）
- 选中图形后菜单项 enabled 状态正确

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/components/menus/CanvasContextMenu.ets entry/src/main/ets/pages/Index.ets
git rm entry/src/main/ets/components/workbench/ContextMenu.ets
git commit -m "refactor(menu): 上下文菜单改用 bindContextMenu + Menu/MenuItem"
```

#### Task 3.2: 用 SegmentButton 替换 3 处分段控件

**Files:**
- Create: `entry/src/main/ets/components/segments/ModuleSegment.ets`
- Create: `entry/src/main/ets/components/segments/ViewModeSegment.ets`
- Create: `entry/src/main/ets/components/segments/RulesetSegment.ets`
- Modify: `entry/src/main/ets/components/workbench/WorkbenchTitleBar.ets`
- Modify: `entry/src/main/ets/components/workbench/WorkbenchInspector.ets`

- [ ] **Step 1: 创建 ModuleSegment.ets（模块切换：版图编辑/验证检查/数据管理）**

```typescript
// entry/src/main/ets/components/segments/ModuleSegment.ets
import { SegmentButton, SegmentButtonOptions, SelectedIndexes } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';

export interface ModuleSegmentProps {
  current: number;          // 0=版图编辑, 1=验证检查, 2=数据管理
  drcBadge?: number;        // 验证检查 tab 的 DRC 错误徽标数
  onChange: (index: number) => void;
}

@Component
export struct ModuleSegment {
  @Prop current: number = 0;
  @Prop drcBadge: number = 0;
  onChange: (index: number) => void = () => {};
  @State selectedIndexes: SelectedIndexes = [0];

  aboutToAppear(): void {
    this.selectedIndexes = [this.current];
  }

  build() {
    Column() {
      SegmentButton({
        options: new SegmentButtonOptions({
          buttons: [
            { text: '版图编辑' },
            { text: this.drcBadge > 0 ? `验证检查 (${this.drcBadge})` : '验证检查' },
            { text: '数据管理' }
          ],
          multiple: false,
          selectedIndexes: this.selectedIndexes
        })
      })
      .onSelectedChange((indexes: SelectedIndexes) => {
        if (indexes.length > 0) {
          this.onChange(indexes[0]);
        }
      })
    }
  }
}
```

- [ ] **Step 2: 在 WorkbenchTitleBar 中用 ModuleSegment 替换原 ModeTab 按钮组**

修改 `WorkbenchTitleBar.ets:74-99`，删除 `ModeTab` 子组件与手动 Row 实现，改为 `<ModuleSegment current={...} drcBadge={...} onChange={...} />`。

- [ ] **Step 3: 创建 ViewModeSegment.ets（查看/编辑）**

```typescript
// entry/src/main/ets/components/segments/ViewModeSegment.ets
import { SegmentButton, SegmentButtonOptions, SelectedIndexes } from '@kit.ArkUI';

@Component
export struct ViewModeSegment {
  @Prop current: 'view' | 'edit' = 'view';
  onChange: (mode: 'view' | 'edit') => void = () => {};
  @State selectedIndexes: SelectedIndexes = [0];

  aboutToAppear(): void {
    this.selectedIndexes = [this.current === 'view' ? 0 : 1];
  }

  build() {
    SegmentButton({
      options: new SegmentButtonOptions({
        buttons: [{ text: '查看' }, { text: '编辑' }],
        multiple: false,
        selectedIndexes: this.selectedIndexes
      })
    })
    .onSelectedChange((indexes: SelectedIndexes) => {
      if (indexes.length > 0) {
        this.onChange(indexes[0] === 0 ? 'view' : 'edit');
      }
    })
  }
}
```

- [ ] **Step 4: 在 WorkbenchTitleBar 中用 ViewModeSegment 替换原视图模式 Row**

- [ ] **Step 5: 创建 RulesetSegment.ets（规则集：28nm/14nm/7nm/自定义）**

```typescript
// entry/src/main/ets/components/segments/RulesetSegment.ets
import { SegmentButton, SegmentButtonOptions, SelectedIndexes } from '@kit.ArkUI';
import { RULESET_NAMES } from '../../common/drcRulesets';

@Component
export struct RulesetSegment {
  @Prop current: number = 0;
  onChange: (index: number) => void = () => {};
  @State selectedIndexes: SelectedIndexes = [0];

  aboutToAppear(): void {
    this.selectedIndexes = [this.current];
  }

  build() {
    SegmentButton({
      options: new SegmentButtonOptions({
        buttons: RULESET_NAMES.map(name => ({ text: name })),
        multiple: false,
        selectedIndexes: this.selectedIndexes
      })
    })
    .onSelectedChange((indexes: SelectedIndexes) => {
      if (indexes.length > 0) {
        this.onChange(indexes[0]);
      }
    })
  }
}
```

- [ ] **Step 6: 在 WorkbenchInspector 中用 RulesetSegment 替换规则集 Text 按钮组（259-286行）**

- [ ] **Step 7: 构建验证 + Commit**

```bash
git add entry/src/main/ets/components/segments/ entry/src/main/ets/components/workbench/WorkbenchTitleBar.ets entry/src/main/ets/components/workbench/WorkbenchInspector.ets
git commit -m "refactor(segment): 三处分段控件改用原生 SegmentButton"
```

---

### 阶段四：布局容器重构（三栏 → SideBarContainer）

#### Task 4.1: 用 SideBarContainer(AUTO) 重构主界面三栏布局

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets`（重点 425-810 行）

- [ ] **Step 1: 用 SideBarContainer 重构主布局**

修改 `entry/src/main/ets/pages/Index.ets`，将原 `Row() { Sidebar + Column{Canvas+Inspector} }` 改为嵌套 SideBarContainer：

```typescript
// 外层：左侧栏 + 主区
SideBarContainer(this.sidebarContainerType()) {
  // 左侧栏内容
  WorkbenchSidebar({ ... })

  // 主区：右侧检查器作为第二层 SideBarContainer
  SideBarContainer(SideBarContainerType.Embed) {
    // 画布区
    Column() {
      WorkbenchTitleBar({ ... })
      LayoutCanvasView({ ... })
      EditorToolbar({ ... })
      StatusBar({ ... })
    }

    // 右侧检查器
    WorkbenchInspector({ ... })
  }
  .showSideBar(this.inspectorVisible)
  .sideBarWidth(320)
  .minSideBarWidth(280)
  .maxSideBarWidth(480)
  .sideBarPosition(SideBarPosition.End)
}
.showSideBar(this.sidebarVisible)
.sideBarWidth(280)
.minSideBarWidth(240)
.maxSideBarWidth(400)
.sideBarPosition(SideBarPosition.Start)
.onChange((visible: boolean) => { this.sidebarVisible = visible; })
```

其中 `sidebarContainerType()` 根据断点返回：

```typescript
private sidebarContainerType(): SideBarContainerType {
  return this.breakpoint === 'lg' ? SideBarContainerType.Embed : SideBarContainerType.Overlay;
}
```

- [ ] **Step 2: 删除手动浮层抽屉实现（720-810行）与浮动按钮（810-870行）**

由 SideBarContainer 的原生 Overlay 模式与 showSideBar 双向绑定替代。

- [ ] **Step 3: 添加侧边栏显隐控制按钮到 WorkbenchTitleBar**

在标题栏左侧（Logo 区后）添加菜单按钮，点击切换 `sidebarVisible`；右侧添加检查器切换按钮。

- [ ] **Step 4: 构建验证 + 手动验证 + Commit**

验证：lg 断点下左右栏 Embed 并列；sm/md 断点下点击按钮 Overlay 浮出，点蒙层关闭。

```bash
git add entry/src/main/ets/pages/Index.ets entry/src/main/ets/components/workbench/WorkbenchTitleBar.ets
git commit -m "refactor(layout): 三栏布局改用 SideBarContainer(AUTO)"
```

---

### 阶段五：图标系统全局替换

#### Task 5.1: 替换全项目 Text+Unicode 图标为 SymbolGlyph / Image

**Files:**
- Modify: `EditorToolbar.ets`、`WorkbenchTitleBar.ets`、`StatusBar.ets`、`WorkbenchSidebar.ets`、`LayoutCanvasView.ets`、`ContextMenu.ets`（已删）、`WorkbenchOverlays.ets`、`InstancePlaceDialog.ets`（已删）

- [ ] **Step 1: 替换 EditorToolbar 图标**

将 `EditorToolbar.ets:35-72` 的 `ToolbarCommand` 与 `ZoomCommand` 中 `Text(glyph)` 改为：

```typescript
// 通用操作图标
SymbolGlyph(Icon.undo).fontSize(16).fontColor([COLORS.ink])

// 专业图标（对齐/分布/移动/放置/网络追踪）
Image(IconResource.alignLeft).width(16).height(16).fillColor(COLORS.ink)
```

- [ ] **Step 2: 替换 WorkbenchTitleBar 图标（📁 💾 ⤢ ⟲ ⚠ ✦ ⌗）**

- [ ] **Step 3: 替换 StatusBar 图标（👁 ✎）**

- [ ] **Step 4: 替换 WorkbenchSidebar 图标（? 及可见性 ◉/○）**

可见性切换 `◉/○` 改为 `SymbolGlyph(Icon.visible)/SymbolGlyph(Icon.hidden)` 或 `Checkbox`。

- [ ] **Step 5: 替换 LayoutCanvasView 图标（● ○ ▶ ▼）**

层级展开 `▶/▼` 改为 `SymbolGlyph(Icon.expand)/SymbolGlyph(Icon.collapse)`。

- [ ] **Step 6: 替换 WorkbenchOverlays 图标（× 等）**

- [ ] **Step 7: 构建验证 + Commit**

```bash
git add entry/src/main/ets/components/workbench/ entry/src/main/ets/pages/Index.ets
git commit -m "refactor(icon): 全项目图标改用 SymbolGlyph/Image"
```

---

### 阶段六：动画系统

#### Task 6.1: 违规闪烁动画改用 animateTo

**Files:**
- Modify: `entry/src/main/ets/components/workbench/LayoutCanvasView.ets`（140-201行）

- [ ] **Step 1: 删除 setInterval 实现，改用 animateTo 无限循环**

```typescript
// 替换原 @State violationBlinkOpacity 与 setInterval
@State violationBlinkOpacity: number = 1.0;

// 启动闪烁
private startViolationBlink(): void {
  // animateTo 不直接支持无限循环，改用 animation 修饰器 + @State 切换
  this.violationBlinkOn = true;
}

@State violationBlinkOn: boolean = true;

// 在违规高亮框组件上：
Rect()
  .fill(COLORS.danger)
  .opacity(this.violationBlinkOn ? 1.0 : 0.5)
  .animation({
    duration: 500,
    curve: Curve.EaseInOut,
    iterations: -1,
    playMode: PlayMode.Alternate
  })
```

- [ ] **Step 2: 删除 aboutToDisappear 中的 clearInterval**

- [ ] **Step 3: 构建验证 + Commit**

```bash
git add entry/src/main/ets/components/workbench/LayoutCanvasView.ets
git commit -m "refactor(animation): 违规闪烁改用 animation 修饰器无限循环"
```

#### Task 6.2: 浮层与抽屉转场动画

**Files:**
- Modify: `WorkbenchOverlays.ets`（所有面板）、`Index.ets`

- [ ] **Step 1: 为 WorkbenchOverlays 中各面板（AI/Macro/File/Shortcut/LayerStyle）添加 transition**

```typescript
// 面板组件根节点
Column() {
  // ...
}
.transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut })
  .combine(TransitionEffect.translate({ y: 20 })))
```

- [ ] **Step 2: 用 animateTo 包裹面板显隐状态切换**

```typescript
// 替换原直接赋值
Button('打开 AI').onClick(() => {
  animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
    this.aiPanelVisible = !this.aiPanelVisible;
  });
})
```

- [ ] **Step 3: 构建验证 + Commit**

```bash
git add entry/src/main/ets/components/workbench/WorkbenchOverlays.ets entry/src/main/ets/pages/Index.ets
git commit -m "feat(animation): 浮层与抽屉添加 transition 转场动画"
```

#### Task 6.3: 选中高亮与菜单箭头过渡

**Files:**
- Modify: `WorkbenchInspector.ets`、`LayoutCanvasView.ets`

- [ ] **Step 1: 选中图形高亮边框用 animation 过渡颜色/透明度**

- [ ] **Step 2: 折叠面板箭头（▸/▾）用 rotation 动画过渡**

```typescript
SymbolGlyph(Icon.expand)
  .fontSize(12)
  .rotate({ angle: this.expanded ? 180 : 0 })
  .animation({ duration: 200, curve: Curve.EaseInOut })
```

- [ ] **Step 3: 构建验证 + Commit**

```bash
git commit -m "feat(animation): 选中高亮与折叠箭头过渡动画"
```

---

### 阶段七：手势系统

#### Task 7.1: 画布平移改用 PanGesture + 手势组合

**Files:**
- Modify: `entry/src/main/ets/components/workbench/LayoutCanvasView.ets`

- [ ] **Step 1: 用 PanGesture 替换 onTouch 中的平移逻辑（977-999行）**

```typescript
// 在画布组件上绑定
.gesture(
  PanGesture({ fingers: 1, distance: 5 })
    .onActionStart((event: GestureEvent) => {
      this.panStartOffsetX = this.viewOffsetX;
      this.panStartOffsetY = this.viewOffsetY;
      this.panStartX = event.offsetX;
      this.panStartY = event.offsetY;
    })
    .onActionUpdate((event: GestureEvent) => {
      const dx = event.offsetX - this.panStartX;
      const dy = event.offsetY - this.panStartY;
      this.viewOffsetX = this.panStartOffsetX + dx * 100 / this.zoomPercent;
      this.viewOffsetY = this.panStartOffsetY + dy * 100 / this.zoomPercent;
      this.viewService.setViewOffset(this.viewOffsetX, this.viewOffsetY);
    })
)
```

> 注意：Select 工具下的拖拽预览仍需保留 onTouch 逻辑（区分单击选中与拖拽移动），PanGesture 仅用于 View 工具下的画布平移。需在 handleTouch 中根据当前工具分发。

- [ ] **Step 2: 用 parallelGesture 组合 Pinch + Pan**

```typescript
.gesture(
  GestureGroup(GestureMode.Parallel,
    PinchGesture({ fingers: 2 })
      .onActionStart(...)
      .onActionUpdate(...),
    PanGesture({ fingers: 2, distance: 5 })
      .onActionUpdate((event) => {
        // 双指平移画布
        ...
      })
  )
)
```

- [ ] **Step 3: 保留原 onTouch 用于单指选中/框选（Select 工具）**

- [ ] **Step 4: 构建验证 + 手动验证**

验证：View 工具下单指拖动平移画布；双指捏合缩放；双指平移同时缩放；Select 工具下单指拖动框选/移动图形。

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/components/workbench/LayoutCanvasView.ets
git commit -m "refactor(gesture): 画布平移改用 PanGesture + parallelGesture 组合"
```

---

### 阶段八：列表与滚动统一

#### Task 8.1: WorkbenchSidebar 图层/工具列表改用 List + LazyForEach

**Files:**
- Modify: `entry/src/main/ets/components/workbench/WorkbenchSidebar.ets`（213-295行）

- [ ] **Step 1: 创建 LayerDataSource 实现 IDataSource**

```typescript
// entry/src/main/ets/common/LayerDataSource.ets
import { IDataSource, DataChangeListener } from '@kit.ArkUI';
import { LayerInfo } from './types';

export class LayerDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: LayerInfo[] = [];

  totalCount(): number { return this.items.length; }
  getData(index: number): LayerInfo { return this.items[index]; }

  registerDataChangeListener(listener: DataChangeListener): void { this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) this.listeners.splice(idx, 1);
  }

  setData(items: LayerInfo[]): void {
    this.items = items;
    this.listeners.forEach(l => l.onDataReloaded());
  }
}
```

- [ ] **Step 2: 在 WorkbenchSidebar 中用 List + LazyForEach 替换 Scroll+Column+ForEach**

```typescript
List({ space: 0, scroller: this.layerScroller }) {
  LazyForEach(this.layerDataSource, (layer: LayerInfo) => {
    ListItem() {
      LayerSidebarRow({ layer: layer, ... })
    }
  }, (layer: LayerInfo) => layer.id)
}
.cachedCount(5)
.scrollBar(BarState.Auto)
.divider({ strokeWidth: 0.5, color: COLORS.border })
```

- [ ] **Step 3: 构建验证 + Commit**

```bash
git add entry/src/main/ets/common/LayerDataSource.ets entry/src/main/ets/components/workbench/WorkbenchSidebar.ets
git commit -m "refactor(list): Sidebar 图层列表改用 List + LazyForEach"
```

---

### 阶段九：反馈与系统 API

#### Task 9.1: 用 promptAction.showToast 替换状态栏反馈（部分场景）

**Files:**
- Modify: 全项目（仅对短时操作反馈，状态栏仍保留持久状态显示）

- [ ] **Step 1: 在关键操作后添加 Toast**

```typescript
import { promptAction } from '@kit.ArkUI';

// 复制成功
promptAction.showToast({ message: '已复制', duration: 1500 });

// DRC 完成
promptAction.showToast({ message: `DRC 完成，发现 ${issues.length} 项违规`, duration: 2000 });

// 保存成功
promptAction.showToast({ message: '保存成功', duration: 1500 });
```

> 原则：瞬时操作反馈用 Toast；持久状态（当前坐标、缩放、模式）仍用状态栏。

- [ ] **Step 2: Commit**

```bash
git commit -m "feat(feedback): 关键操作添加 promptAction.showToast"
```

#### Task 9.2: 用 @ohos.measure 替换文本宽度估算

**Files:**
- Modify: `entry/src/main/ets/components/workbench/LayoutCanvasView.ets`（1301行）

- [ ] **Step 1: 替换 (text.length * 8 + 12) 估算**

```typescript
import { measure } from '@kit.ArkUI';

private measureTextWidth(text: string, fontSize: number = 12): number {
  return measure.measureText({
    textContent: text,
    fontSize: fontSize,
    fontFamily: FONT_MONO
  });
}

// 替换原估算
const labelWidth = this.measureTextWidth(labelText);
```

- [ ] **Step 2: Commit**

```bash
git commit -m "refactor(measure): 文本宽度用 @ohos.measure 精确测量"
```

#### Task 9.3: AiService 请求前网络检测

**Files:**
- Modify: `entry/src/main/ets/services/AiService.ets`

- [ ] **Step 1: 添加 @ohos.net.connection 网络检测**

```typescript
import { connection } from '@kit.NetworkKit';

private async checkNetworkAvailable(): Promise<boolean> {
  const netHandle = await connection.getDefaultNet();
  return netHandle !== null;
}

// 在 sendRequest 前
if (!await this.checkNetworkAvailable()) {
  throw new Error('网络不可用，请检查网络连接');
}
```

- [ ] **Step 2: Commit**

```bash
git commit -m "feat(ai): 请求前检测网络连通性"
```

---

### 阶段九·补：材质系统（毛玻璃 / 阴影 / 沉浸式 / 透明度令牌化）

> 项目当前完全零使用鸿蒙原生材质能力（blur/backgroundBlurStyle/ColorMetrics/effectComponent/expandSafeArea/沉浸式窗口 API 全部 0 处）。8 处遮罩靠 rgba(0,0,0,X) 硬编码，11 处阴影靠硬编码 ShadowOptions，59 处 rgba 字符串，0 处沉浸式。本阶段将整体迁移到原生材质 API。

#### 调研数据（材质专项）

| 当前问题 | 数量 | 位置示例 |
|---|---|---|
| rgba(0,0,0,X) 黑色半透明遮罩（6 档透明度） | 20 处 | Index.ets:417,725,791; InstancePlaceDialog.ets:128; LayoutCanvasView.ets:354,611,783,837,1518 |
| rgba(255,255,255,X) 白色半透明（16 档） | 22 处 | LayoutCanvasView.ets 集中 18 处 |
| rgba(R,G,B,X) 彩色半透明 | 17 处 | 选中态/警告/HUD |
| 硬编码 shadow（4 套不同参数） | 11 处 | 见阶段一调研 |
| 圆角值硬编码（4/6/8/12/16 五档） | 82 处 | 全项目 |
| 硬编码 hex 颜色（#F1F3F6/#2BA89C/#2A2F3A 等） | 10+ 处 | WorkbenchOverlays、ContextMenu、CardPage |
| 沉浸式 | 0 处 | EntryAbility.ets 未调 setWindowLayoutFullScreen |
| backgroundBlurStyle / backdropBlur / blur | 0 处 | 全项目零使用 |
| expandSafeArea / systemBarEffect | 0 处 | 全项目零使用 |

#### 原生材质能力对照表

| 原生 API | 起始 API | 用途 |
|---|---|---|
| `backgroundBlurStyle(BlurStyle, options?)` | 9 | 毛玻璃材质（COMPONENT_THIN/REGULAR/THICK/ULTRA_THICK 等） |
| `foregroundBlurStyle(BlurStyle, options?)` | 10 | 前景内容模糊（敏感参数失焦） |
| `backdropBlur(radius, options?)` | 9 | 自定义半径背景模糊（性能较高） |
| `shadow(ShadowStyle.OUTER_*)` | 10 | 离散阴影档位（XS/SM/MD/LG/FLOATING_SM/FLOATING_MD） |
| `shadow(ShadowOptions)` | 7 | 自定义阴影参数 |
| `useShadowBatching(boolean)` | 11 | 同层阴影不重叠（列表场景） |
| `ColorMetrics.alpha()` | 12 | 动态透明度派生 |
| `expandSafeArea([SYSTEM], [TOP/BOTTOM])` | - | 组件延伸到状态栏 |
| `systemBarEffect()` | 12 | 系统栏智能反色+模糊 |
| `window.setWindowLayoutFullScreen(true)` | 9 | 窗口全屏布局 |
| `window.setWindowSystemBarProperties(...)` | 9 | 状态栏/导航栏样式 |
| `$r('app.string.ohos_id_corner_radius_*')` | - | 系统圆角令牌 |

#### Task 9·M.1: 创建材质令牌模块 MaterialTokens.ets

**Files:**
- Create: `entry/src/main/ets/common/MaterialTokens.ets`

- [ ] **Step 1: 创建 MaterialTokens.ets，定义 BlurStyle / ShadowStyle / 圆角 / 透明度令牌**

```typescript
// entry/src/main/ets/common/MaterialTokens.ets
import { BlurStyle, ShadowStyle } from '@kit.ArkUI';

/** 材质层级枚举（对应 Material Elevation 离散化） */
export enum Elevation {
  NONE,        // 无阴影（贴底）
  XS,          // 元素级（卡片内子元素）
  SM,          // 固定栏（标题栏/工具栏）
  MD,          // 浮层（菜单/Tooltip）
  LG,          // 模态（弹窗）
  FLOATING_SM, // 悬浮小（FAB）
  FLOATING_MD, // 悬浮中（半模态）
}

/** 阴影令牌映射到 ShadowStyle 枚举 */
export const SHADOW_BY_ELEVATION: Record<Elevation, ShadowStyle | undefined> = {
  [Elevation.NONE]: undefined,
  [Elevation.XS]: ShadowStyle.OUTER_DEFAULT_XS,
  [Elevation.SM]: ShadowStyle.OUTER_DEFAULT_SM,
  [Elevation.MD]: ShadowStyle.OUTER_DEFAULT_MD,
  [Elevation.LG]: ShadowStyle.OUTER_DEFAULT_LG,
  [Elevation.FLOATING_SM]: ShadowStyle.OUTER_FLOATING_SM,
  [Elevation.FLOATING_MD]: ShadowStyle.OUTER_FLOATING_MD,
};

/** 材质模糊令牌（按 UI 层级） */
export const BLUR_BY_LAYER = {
  STATUS_BAR: BlurStyle.BACKGROUND_THIN,           // 状态栏背板
  TITLE_BAR: BlurStyle.COMPONENT_THIN,             // 标题栏
  TOOLBAR: BlurStyle.COMPONENT_THIN,               // 工具栏
  SIDEBAR: BlurStyle.COMPONENT_REGULAR,            // 侧栏
  INSPECTOR: BlurStyle.COMPONENT_REGULAR,          // 检视器
  HUD: BlurStyle.COMPONENT_ULTRA_THIN,             // 画布 HUD 浮条
  CONTEXT_MENU: BlurStyle.COMPONENT_THICK,         // 上下文菜单
  POPOVER: BlurStyle.COMPONENT_THICK,              // 气泡/Tooltip
  DIALOG_MASK: BlurStyle.BACKGROUND_ULTRA_THICK,   // 弹窗蒙层
  SHEET: BlurStyle.COMPONENT_ULTRA_THICK,          // 半模态面板
} as const;

/** 圆角令牌 */
export const RADIUS = {
  xs: 4,   // 徽标、小图标
  sm: 6,   // 按钮、小元素
  md: 8,   // 浮层容器
  lg: 12,  // 弹窗
  xl: 16,  // 卡片页面
} as const;

/** 透明度令牌（语义化） */
export const ALPHA = {
  OVERLAY_STRONG: 0.5,   // 强蒙层（弹窗）
  OVERLAY_MEDIUM: 0.4,   // 中蒙层（抽屉）
  OVERLAY_LIGHT: 0.26,   // 轻蒙层（HUD）
  DISABLED: 0.4,         // 禁用态
  HOVER: 0.08,           // 悬停态
  SELECTED: 0.12,        // 选中态
  FOCUS: 0.18,           // 聚焦态
} as const;

/** 工具：从 hex 颜色与 alpha 生成 rgba 字符串（替代硬编码 rgba） */
export function withAlpha(hex: string, alpha: number): string {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r},${g},${b},${alpha})`;
}
```

- [ ] **Step 2: 构建验证 + Commit**

```bash
git add entry/src/main/ets/common/MaterialTokens.ets
git commit -m "feat(material): 引入材质令牌模块（阴影/模糊/圆角/透明度）"
```

#### Task 9·M.2: EntryAbility 实现沉浸式状态栏

**Files:**
- Modify: `entry/src/main/ets/entryability/EntryAbility.ets`
- Modify: `entry/src/main/ets/pages/Index.ets`（根容器加 expandSafeArea）

- [ ] **Step 1: 在 EntryAbility.onWindowStageCreate 中启用全屏布局与系统栏样式**

```typescript
// entry/src/main/ets/entryability/EntryAbility.ets
import { window } from '@kit.ArkUI';

onWindowStageCreate(windowStage: window.WindowStage): void {
  windowStage.loadContent('pages/Index', (err) => { /* ... */ });
  windowStage.getMainWindow().then((win) => {
    // 1. 全屏布局，应用内容延伸到状态栏后方
    win.setWindowLayoutFullScreen(true);
    // 2. 保留状态栏与导航栏可见
    win.setWindowSystemBarEnable(['status', 'navigation']);
    // 3. 设置状态栏文字色为深色（浅色主题下），导航栏背景白
    win.setWindowSystemBarProperties({
      statusBarContentColor: '#000000',
      navigationBarColor: '#FFFFFF',
      // 导航栏内容色（API 11+）
      // navigationBarContentColor: '#000000'
    });
  });
}
```

- [ ] **Step 2: 在 Index.ets 根容器上加 expandSafeArea**

让 WorkbenchTitleBar 延伸到状态栏区域：

```typescript
// 顶层 Stack 或 Column
Stack() {
  Column() {
    WorkbenchTitleBar({ ... })
    // ... 其余内容
  }
}
.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
```

并在 WorkbenchTitleBar 顶部 padding 增加 `px2vp(windowAvoidArea.topRect.height)` 以避开状态栏文字。

- [ ] **Step 3: 在 WorkbenchTitleBar 上加 systemBarEffect 与 backgroundBlurStyle**

```typescript
Row() { /* 标题栏内容 */ }
  .backgroundColor(COLORS.surface)                 // 兜底色
  .backgroundBlurStyle(BLUR_BY_LAYER.TITLE_BAR, {  // 毛玻璃背板
    colorMode: ThemeColorMode.SYSTEM,
    adaptiveColor: AdaptiveColor.DEFAULT,
    scale: 1.0
  })
  .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
```

- [ ] **Step 4: 构建验证 + 手动验证**

验证：应用启动后画布占满全屏，标题栏延伸到状态栏后方，状态栏文字可见且为深色，标题栏呈毛玻璃效果透出画布。

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/entryability/EntryAbility.ets entry/src/main/ets/pages/Index.ets entry/src/main/ets/components/workbench/WorkbenchTitleBar.ets
git commit -m "feat(material): 启用沉浸式状态栏与标题栏毛玻璃背板"
```

#### Task 9·M.3: 8 处 rgba(0,0,0,X) 遮罩改用 backgroundBlurStyle

**Files:**
- Modify: `InstancePlaceDialog.ets`、`pages/Index.ets`、`LayoutCanvasView.ets`、所有 `components/dialogs/*.ets`（阶段二新建的）

- [ ] **Step 1: 弹窗蒙层改用 BACKGROUND_ULTRA_THICK 模糊**

将所有弹窗遮罩的 `.backgroundColor('rgba(0,0,0,0.4)')` 或 `0.45`/`0.5` 改为：

```typescript
Column() { /* 蒙层 */ }
  .backgroundColor('rgba(0,0,0,0.2)')                                  // 降低纯色透明度
  .backgroundBlurStyle(BLUR_BY_LAYER.DIALOG_MASK, {
    colorMode: ThemeColorMode.SYSTEM,
    adaptiveColor: AdaptiveColor.DEFAULT,
    scale: 1.0
  })
  .hitTestBehavior(HitTestMode.Block)                                  // 统一拦截点击
```

涉及位置：
- `Index.ets:417`（大文件向导蒙层，0.5 → 模糊）
- `Index.ets:725`（左抽屉蒙层，0.4 → 模糊）
- `Index.ets:791`（右抽屉蒙层，0.4 → 模糊）
- `InstancePlaceDialog.ets:128`（实例放置蒙层，0.4 → 模糊）
- `LayoutCanvasView.ets:783`（MoveDialog 蒙层，0.45 → 模糊）
- `LayoutCanvasView.ets:837`（TextCreateDialog 蒙层，0.45 → 模糊）

> 注：阶段二将这些弹窗迁到 @CustomDialog 后，蒙层由 CustomDialogController 自动管理，本任务主要覆盖仍保留的内联蒙层（抽屉、画布弹窗）。

- [ ] **Step 2: 画布 HUD 浮条改用 COMPONENT_ULTRA_THIN 模糊**

将 LayoutCanvasView 中 3 处 HUD 黑色半透明背景改为毛玻璃：

- `LayoutCanvasView.ets:354`（测量标签，0.75 → 模糊+半透明）
- `LayoutCanvasView.ets:611`（多边形工具条，0.62 → 模糊）
- `LayoutCanvasView.ets:1518`（光标坐标 HUD，0.26 → 模糊）

```typescript
Row() { /* HUD 内容 */ }
  .backgroundColor('rgba(0,0,0,0.3)')
  .backgroundBlurStyle(BLUR_BY_LAYER.HUD, {
    colorMode: ThemeColorMode.SYSTEM,
    adaptiveColor: AdaptiveColor.AVERAGE,
    scale: 1.0
  })
  .borderRadius(RADIUS.sm)
```

- [ ] **Step 3: 构建验证 + 手动验证**

验证：弹窗弹出时背景呈毛玻璃而非纯黑半透明；画布 HUD 浮条透出画布内容。

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/ets/components/workbench/ entry/src/main/ets/pages/Index.ets entry/src/main/ets/components/dialogs/
git commit -m "refactor(material): 8处遮罩+3处HUD改用 backgroundBlurStyle 毛玻璃"
```

#### Task 9·M.4: 11 处硬编码 shadow 改用 ShadowStyle 令牌

**Files:**
- Modify: `WorkbenchOverlays.ets`（5 处浮层）、`InstancePlaceDialog.ets`、`pages/Index.ets`（向导+2 FAB）、`ContextMenu.ets`（阶段三后已删）、`WorkbenchTitleBar.ets`、`LayoutCanvasView.ets`（MoveDialog/TextCreateDialog 补阴影）

- [ ] **Step 1: 浮层面板阴影统一改用 OUTER_FLOATING_MD**

将 WorkbenchOverlays 5 处 `.shadow({ radius: 18, color: 'rgba(0,0,0,0.18)', offsetX: 0, offsetY: 6 })` 改为：

```typescript
.shadow(SHADOW_BY_ELEVATION[Elevation.FLOATING_MD])
```

- [ ] **Step 2: 弹窗阴影改用 OUTER_FLOATING_MD**

InstancePlaceDialog（24,0.22,8）与大文件向导（16,0.25,4）统一改为：

```typescript
.shadow(SHADOW_BY_ELEVATION[Elevation.FLOATING_MD])
```

- [ ] **Step 3: FAB 浮钮阴影改用 OUTER_FLOATING_SM**

Index.ets 两处 FAB（4,0.15,2）改为：

```typescript
.shadow(SHADOW_BY_ELEVATION[Elevation.FLOATING_SM])
```

- [ ] **Step 4: 标题栏模式 Tab 微阴影改用 OUTER_DEFAULT_XS**

WorkbenchTitleBar.ets:165 的条件 shadow(2,0.06,1) 改为：

```typescript
.shadow(this.active ? SHADOW_BY_ELEVATION[Elevation.XS] : undefined)
```

- [ ] **Step 5: 画布弹窗（MoveDialog/TextCreateDialog）补阴影**

LayoutCanvasView 中两处弹窗原本无阴影，补上：

```typescript
.shadow(SHADOW_BY_ELEVATION[Elevation.FLOATING_MD])
```

- [ ] **Step 6: 抽屉浮层（Sidebar/Inspector compact 模式）补阴影**

Index.ets:730-770 与 780-810 的抽屉容器补 `.shadow(SHADOW_BY_ELEVATION[Elevation.FLOATING_SM])`。

- [ ] **Step 7: 构建验证 + 手动验证 + Commit**

验证：所有浮层/弹窗阴影一致；抽屉浮出时有阴影区分；画布弹窗不再"贴平"。

```bash
git add entry/src/main/ets/components/workbench/ entry/src/main/ets/pages/Index.ets
git commit -m "refactor(material): 11处阴影统一改用 ShadowStyle 令牌"
```

#### Task 9·M.5: 59 处硬编码 rgba 改用 withAlpha + COLORS

**Files:**
- Modify: `LayoutCanvasView.ets`（38 处 rgba）、`WorkbenchOverlays.ets`、`WorkbenchSidebar.ets`、`WorkbenchTitleBar.ets`、`constants.ets`

- [ ] **Step 1: 黑色半透明统一用 withAlpha('#000000', ALPHA.X)**

将 20 处 `rgba(0,0,0,0.X)` 替换为 `withAlpha('#000000', ALPHA.OVERLAY_STRONG/MEDIUM/LIGHT)` 或对应语义令牌。

- [ ] **Step 2: 白色半透明统一用 withAlpha('#FFFFFF', alpha)**

将 22 处 `rgba(255,255,255,0.X)` 替换。对画布 HUD 文本色，建议在 COLORS 中新增 `canvasTextPrimary/Secondary/Muted` 三档语义色。

- [ ] **Step 3: 彩色半透明统一用 withAlpha(COLORS.X, alpha)**

将 17 处 `rgba(47,109,246,X)` 统一为 `withAlpha(COLORS.primary, ALPHA.SELECTED)`（注意修正 47,109,246 与 COLORS.primary #007AFF 的色值不一致问题，统一为 #007AFF）。

- [ ] **Step 4: 修正硬编码 hex 颜色**

- `WorkbenchOverlays.ets:589,1021,1098` 的 `'#F1F3F6'` → `COLORS.border`
- `WorkbenchTitleBar.ets:261,267` 的 `'#2BA89C'` → 在 constants.ets 中新增 `COLORS.teal` 后引用
- `ContextMenu.ets:391` 的 `'#2A2F3A'` → 在 constants.ets 中新增 `COLORS.contextMenuBg` 后引用（阶段三删除 ContextMenu 后此条作废）
- `CardPage.ets` 的 6+ 硬编码色 → 复用 COLORS 体系

- [ ] **Step 5: 构建验证 + Commit**

```bash
git add entry/src/main/ets/components/workbench/ entry/src/main/ets/pages/ entry/src/main/ets/common/constants.ets
git commit -m "refactor(material): 59处硬编码rgba改用withAlpha+COLORS，修正色值不一致"
```

#### Task 9·M.6: 82 处圆角值改用 RADIUS 令牌

**Files:**
- Modify: 全项目所有 `.borderRadius()` 调用

- [ ] **Step 1: 全项目替换 borderRadius 硬编码值为 RADIUS 令牌**

用 Grep 找出所有 `.borderRadius(4|6|8|12|16)`，按映射替换：
- `4` → `RADIUS.xs`
- `6` → `RADIUS.sm`
- `8` → `RADIUS.md`
- `12` → `RADIUS.lg`
- `16` → `RADIUS.xl`

- [ ] **Step 2: 构建验证 + Commit**

```bash
git add entry/src/main/ets/
git commit -m "refactor(material): 82处圆角值改用 RADIUS 令牌"
```

#### Task 9·M.7: 停靠面板（侧栏/检视器/工具栏）加毛玻璃背板

**Files:**
- Modify: `WorkbenchSidebar.ets`、`WorkbenchInspector.ets`、`EditorToolbar.ets`、`StatusBar.ets`

- [ ] **Step 1: 侧栏与检视器加 COMPONENT_REGULAR 模糊**

```typescript
// WorkbenchSidebar 根容器
Column() { /* ... */ }
  .backgroundColor(COLORS.surface)
  .backgroundBlurStyle(BLUR_BY_LAYER.SIDEBAR, {
    colorMode: ThemeColorMode.SYSTEM,
    adaptiveColor: AdaptiveColor.DEFAULT
  })

// WorkbenchInspector 同理用 BLUR_BY_LAYER.INSPECTOR
```

- [ ] **Step 2: 工具栏与状态栏加 COMPONENT_THIN 模糊**

```typescript
// EditorToolbar
Row() { /* ... */ }
  .backgroundBlurStyle(BLUR_BY_LAYER.TOOLBAR, { ... })

// StatusBar
Row() { /* ... */ }
  .backgroundBlurStyle(BLUR_BY_LAYER.TOOLBAR, { ... })
```

- [ ] **Step 3: 构建验证 + 手动验证 + Commit**

验证：在画布有内容时，侧栏/检视器/工具栏透出画布毛玻璃效果；画布纯色背景下效果退化为半透明。

> **关键风险**：XComponent 画布的输出能否被 backgroundBlurStyle 正确采样需在目标设备验证。若不能，停靠面板退回纯色背景（去掉 backgroundBlurStyle），仅浮层与弹窗用模糊。

```bash
git add entry/src/main/ets/components/workbench/
git commit -m "feat(material): 停靠面板加毛玻璃背板（侧栏/检视器/工具栏/状态栏）"
```

#### Task 9·M.8: 上下文菜单与弹窗体加 COMPONENT_THICK/ULTRA_THICK 模糊

**Files:**
- Modify: 阶段三新建的 `CanvasContextMenu` 相关、阶段二新建的 `components/dialogs/*.ets`

- [ ] **Step 1: 上下文菜单容器加 COMPONENT_THICK 模糊**

在 bindContextMenu 的 @Builder Menu 容器上（或通过 Menu 的 styles）加：

```typescript
.backgroundBlurStyle(BLUR_BY_LAYER.CONTEXT_MENU, {
  colorMode: ThemeColorMode.SYSTEM,
  adaptiveColor: AdaptiveColor.AVERAGE
})
```

- [ ] **Step 2: 弹窗体加 COMPONENT_ULTRA_THICK 模糊**

各 @CustomDialog 弹窗的根 Column 加：

```typescript
.backgroundBlurStyle(BLUR_BY_LAYER.SHEET, {
  colorMode: ThemeColorMode.SYSTEM,
  adaptiveColor: AdaptiveColor.DEFAULT
})
```

- [ ] **Step 3: 构建验证 + Commit**

```bash
git commit -m "feat(material): 上下文菜单与弹窗体加厚毛玻璃材质"
```

#### Task 9·M.9: 性能与降级策略

**Files:**
- Modify: `MaterialTokens.ets`、`EntryAbility.ets`

- [ ] **Step 1: 在 MaterialTokens 中增加性能降级开关**

```typescript
// 根据设备性能等级动态调整 scale
export const BLUR_SCALE_LOW = 0.5;  // 低性能设备
export const BLUR_SCALE_NORMAL = 1.0;

export function getBlurScale(): number {
  // 简化：可通过 deviceInfo 检测设备等级
  return BLUR_SCALE_NORMAL;
}
```

- [ ] **Step 2: 弹窗关闭时切换 policy 节能**

```typescript
// 弹窗 visible 状态切换时
this.controller.close();
// 若用 @State 控制可见性，可设 policy: BlurStyleActivePolicy.ALWAYS_INACTIVE
```

- [ ] **Step 3: XComponent 之上模糊失败兜底**

在 Task 9·M.7 验证步骤中，若发现停靠面板的 backgroundBlurStyle 无法采样 XComponent 输出（呈现纯透明或纯色），则：
- 停靠面板退回 `.backgroundColor(COLORS.surface)` 不加模糊
- 仅保留浮层与弹窗的模糊（这些不依赖 XComponent 内容采样）

- [ ] **Step 4: 构建验证 + Commit**

```bash
git commit -m "perf(material): 模糊性能降级策略与 XComponent 兜底"
```

---

### 阶段十一（可选）：仓颉（Cangjie）混合开发

> 项目当前 C/C++ 层职责清晰：纯算法层（GDSII/OASIS 解析）、渲染层（OpenGL ES + XComponent）、桥接层（NAPI 手写）。ArkTS 层有 DRC 检查、GDSII 写入、渲染数据序列化等计算密集逻辑，且**全项目零使用并发**（无 TaskPool/Worker）。仓颉最适合承担"高性能算法 + 并行调度 + C++ 桥接"三重角色。

#### 调研结论（仓颉专项）

**A. 仓颉语言关键能力**

| 能力 | 说明 | KLayout 用途 |
|---|---|---|
| 编译型 AOT，基于 LLVM | 性能接近 C++（慢 5-15%），远超 ArkTS（领先 1.5-100 倍） | 算法密集场景 |
| Tracing GC（全并发整理） | GC 暂停 <100μs | 不阻塞 UI |
| 值类型 struct + 单态化泛型 | 栈分配，无堆开销 | Point/ShapeBounds 等纯数据 |
| 有栈协程 M:N，8KB 栈/协程 | 创建数百纳秒，无上限 | 替代 TaskPool（4 线程上限） |
| Channel CSP 模型 | 协程间零拷贝消息传递 | 分块解析/DRC 结果汇总 |
| @extern("C") FFI | 零成本调用 C ABI 库 | 直接调用 libhongtu.so |
| @repr(C) struct | 强制 C 内存布局 | 与 C++ 结构体互操作 |
| CFFI 互操作库 | ArkTS ↔ 仓颉 库级互操作，无需手写 NAPI | 替代 napi_init.cpp |

**B. 项目三层架构推荐**

```
ArkTS（UI 层：ArkUI 声明式、XComponent 宿主）
   ↓ requireCJLib / CFFI
仓颉（逻辑层：并行解析、DRC、几何运算、数据模型、FFI 桥接）
   ↓ @extern("C") FFI
C++（复用层：libhongtu.so 的 OpenGL ES 渲染、EGL、XComponent NDK）
```

**C. 仓颉重写优先级矩阵**

| 优先级 | 模块 | 当前实现 | 仓颉价值 | 是否重写 |
|---|---|---|---|---|
| **P0** | DrcService 并行分块检查 | ArkTS 串行双层循环，无并发 | 协程无 4 线程上限，收益巨大 | ✅ 重写 |
| **P0** | LayoutExportService.GdsByteWriter | ArkTS number[] 字节装箱 | ArrayBuffer 零拷贝 | ✅ 重写 |
| **P0** | NAPI 桥接层 napi_init.cpp | C++ 手写 napi_create_* | CFFI 自动桥接，省样板代码 | ✅ 重写 |
| **P1** | GlCanvas.shapesToBatches | ArkTS 1:1 不合并批次 | 仓颉侧合并批次 + ArrayBuffer | ✅ 重写 |
| **P1** | GDSII/OASIS 解析调度 | C++ 同步阻塞主线程 | 仓颉协程并行分块 | ✅ 调度层重写 |
| **P2** | VerifyService XOR/NetTrace | ArkTS 串行 | 可并行化 | 视情况 |
| **P2** | 数据模型 Point/ShapeBounds | ArkTS interface | 仓颉 value 类型 | 视情况 |
| **不重写** | gl_renderer.cpp + xcomponent_plugin.cpp EGL | C++ OpenGL ES | 仓颉无等价 API | ❌ 保留 C++ |
| **不重写** | UI 组件（pages/components/workbench） | ArkTS ArkUI | 仓颉 UI 生态弱 | ❌ 保留 ArkTS |
| **不重写** | GDSII/OASIS 解析核心算法 | C++ 已验证 | 重写工作量大、风险高 | ❌ 保留 C++ |

**D. 关键风险**

1. **仓颉生态初期**：1.0 LTS 2025-07 发布，社区案例少于 ArkTS
2. **学习曲线**：团队需 3-4 周上手
3. **混合构建复杂度**：cjpm + cmake + hvigor 三套构建系统共存
4. **C++ 互操作边界**：仓颉 GC 与 C++ 手动内存管理需明确所有权
5. **不重写渲染层**：OpenGL ES/EGL/XComponent NDK 仍由 C++ 承担

#### Task 11.1: 仓颉开发环境与混合工程搭建

**Files:**
- Create: `entry/src/main/cangjie/` 目录
- Create: `entry/src/main/cangjie/cjpm.toml`
- Modify: `entry/build-profile.json5`（声明仓颉模块）
- Modify: `oh-package.json5`（声明仓颉依赖）

- [ ] **Step 1: 安装仓颉工具链并验证**

```bash
cjc -v              # 查看编译器版本（需 1.0 LTS）
cjpm --version      # 包管理器
```

预期：cjc 1.0.x LTS，cjpm 可用。

- [ ] **Step 2: 在 DevEco Studio 中创建 Cangjie Hybrid 模块**

在 `entry/src/main/` 下创建 `cangjie/` 目录，初始化 cjpm 工程：

```toml
# entry/src/main/cangjie/cjpm.toml
[package]
name = "hongtu_cj"
version = "0.1.0"
description = "HongTu Cangjie logic layer"
cangjie-version = "1.0.0"

[dependencies]
ohos_ark_interop = { path = "ohos.ark_interop" }

[targets]
so = { name = "libhongtu_cj.so" }
```

- [ ] **Step 3: 在 entry/build-profile.json5 中声明仓颉模块**

```json
{
  "module": {
    "name": "entry",
    "type": "entry",
    "srcEntry": "./ets/entryability/EntryAbility.ets",
    "externalNativeOptions": {
      "path": "./src/main/cpp/CMakeLists.txt"
    },
    "cangjieOptions": {
      "path": "./src/main/cangjie/cjpm.toml",
      "abiFilters": ["arm64-v8a", "x86_64"]
    }
  }
}
```

- [ ] **Step 4: 编写最小仓颉模块验证端到端调用链**

`entry/src/main/cangjie/src/main.cj`：

```cangjie
import ohos.ark_interop.*

// 仓颉侧导出函数
func cjGetVersion(context: JSContext, callInfo: JSCallInfo): JSValue {
    return context.string("hongtu_cj 0.1.0").toJSValue()
}

class Main {
    static init() {
        JSModule.registerModule {
            context, exports =>
            exports["cjGetVersion"] = context.function(cjGetVersion).toJSValue()
        }
    }
}
```

ArkTS 侧验证 `entry/src/main/ets/services/CangjieBridge.ets`：

```typescript
import { requireCJLib } from 'libark_interop_loader.so';

interface CangjieLib {
  cjGetVersion(): string;
}

const cjLib = requireCJLib('libhongtu_cj.so') as CangjieLib;

export function getCjVersion(): string {
  return cjLib.cjGetVersion();
}
```

- [ ] **Step 5: 构建验证 + 手动验证 + Commit**

验证：`hvigorw assembleHap` 通过，应用启动后调用 `getCjVersion()` 返回 "hongtu_cj 0.1.0"。

```bash
git add entry/src/main/cangjie/ entry/build-profile.json5 entry/src/main/ets/services/CangjieBridge.ets
git commit -m "feat(cangjie): 搭建仓颉混合工程并验证端到端调用链"
```

#### Task 11.2: 仓颉 FFI 封装 libhongtu.so（替代 napi_init.cpp 桥接层）

**Files:**
- Create: `entry/src/main/cangjie/src/hongtu_ffi.cj`
- Create: `entry/src/main/cangjie/src/bridge.cj`
- Modify: `entry/src/main/ets/services/NativeHongTuService.ets`（改用仓颉桥接）

- [ ] **Step 1: 在仓颉侧用 @extern 声明 libhongtu.so 的 C 接口**

首先在 C++ 侧为需要被仓颉调用的函数添加 `extern "C"` 导出（修改 `gdsii_reader.cpp`/`oasis_reader.cpp` 暴露纯 C 入口）：

```cpp
// entry/src/main/cpp/gdsii_reader.cpp 末尾添加
extern "C" {
    // 解析 GDSII 文件，结果通过回调返回
    int hongtu_parse_gdsii(const char* path, GdsiiParseResult* outResult);
    int hongtu_quick_info(const char* path, GdsiiParseResult* outResult);
}
```

仓颉侧声明 FFI：

```cangjie
// entry/src/main/cangjie/src/hongtu_ffi.cj
package hongtu_cj

// 与 C++ 结构体 1:1 映射的 @repr(C) struct
@repr(C)
public struct CPoint {
    public let x: Float64
    public let y: Float64
}

@repr(C)
public struct CShape {
    public let type: Int32        // 0=RECT, 1=POLYGON, 2=PATH, 3=TEXT, 4=INSTANCE
    public let layerNumber: Int32
    public let datatype: Int32
    public let pointCount: Int32
    public let points: CPointer<CPoint>
    public let pathWidth: Float64
    public let cellId: Int32
    public let rotation: Float64
    public let mirror: Int32      // 0=none, 1=x, 2=y
}

@repr(C)
public struct CLayerInfo {
    public let number: Int32
    public let datatype: Int32
    public let name: CString
    public let elementCount: Int32
}

@repr(C)
public struct CParseResult {
    public let success: Int32
    public let errorMessage: CString
    public let shapeCount: Int32
    public let shapes: CPointer<CShape>
    public let layerCount: Int32
    public let layers: CPointer<CLayerInfo>
    public let cellCount: Int32
    public let cells: CPointer<CCellInfo>
}

// 声明 libhongtu.so 的 C 函数
@extern("C", library: "hongtu")
public unsafe func hongtu_parse_gdsii(path: CString, outResult: &mut CParseResult): Int32

@extern("C", library: "hongtu")
public unsafe func hongtu_quick_info(path: CString, outResult: &mut CParseResult): Int32

@extern("C", library: "hongtu")
public unsafe func hongtu_free_parse_result(result: &mut CParseResult): None
```

- [ ] **Step 2: 在仓颉侧实现安全封装层并导出给 ArkTS**

```cangjie
// entry/src/main/cangjie/src/bridge.cj
package hongtu_cj

import ohos.ark_interop.*

// 仓颉侧安全封装：解析 GDSII
public func parseGdsii(filePath: String): ParseResult {
    unsafe {
        var cResult = CParseResult()
        let cPath = CString.fromStr(filePath)
        let ret = hongtu_parse_gdsii(cPath, &cResult)
        if (ret != 0 || cResult.success == 0) {
            let msg = cResult.errorMessage.toStr()
            return ParseResult(success: false, errorMsg: msg, shapes: Array<Shape>(), layers: Array<LayerInfo>())
        }
        // 将 C 结构体数组转为仓颉 Array
        let shapes = convertShapes(cResult.shapes, cResult.shapeCount)
        let layers = convertLayers(cResult.layers, cResult.layerCount)
        hongtu_free_parse_result(&cResult)
        return ParseResult(success: true, errorMsg: "", shapes: shapes, layers: layers)
    }
}

// 导出到 ArkTS
func jsParseGdsii(context: JSContext, callInfo: JSCallInfo): JSValue {
    let path: String = callInfo[0].toString()
    let result = parseGdsii(path)
    // 转为 JSValue 对象
    let obj = context.object()
    obj.set("success", context.boolean(result.success).toJSValue())
    obj.set("errorMsg", context.string(result.errorMsg).toJSValue())
    let shapesArr = context.array()
    for (shape in result.shapes) {
        let shapeObj = context.object()
        shapeObj.set("type", context.number(Float64(shape.type)).toJSValue())
        shapeObj.set("layerNumber", context.number(Float64(shape.layerNumber)).toJSValue())
        // ... 其余字段
        shapesArr.set(shapesArr.length(), shapeObj.toJSValue())
    }
    obj.set("shapes", shapesArr.toJSValue())
    return obj.toJSValue()
}

class Main {
    static init() {
        JSModule.registerModule {
            context, exports =>
            exports["parseGdsii"] = context.function(jsParseGdsii).toJSValue()
            exports["cjGetVersion"] = context.function(cjGetVersion).toJSValue()
        }
    }
}
```

- [ ] **Step 3: 在 ArkTS 侧用仓颉桥接替代原 NativeHongTuService**

修改 `NativeHongTuService.ets`：

```typescript
import { requireCJLib } from 'libark_interop_loader.so';

interface CangjieLib {
  cjGetVersion(): string;
  parseGdsii(path: string): {
    success: boolean;
    errorMsg: string;
    shapes: NativeShape[];
    layers: LayerInfo[];
    cells: CellInfo[];
  };
  // 其余方法...
}

const cjLib = requireCJLib('libhongtu_cj.so') as CangjieLib;

export class NativeHongTuService {
  static parse(filePath: string): GdsiiResult {
    const result = cjLib.parseGdsii(filePath);
    // 转换为现有 GdsiiResult 类型
    return { ... };
  }
}
```

- [ ] **Step 4: 构建验证 + 性能对比 + Commit**

对比原 NAPI 实现与新仓颉桥接的解析耗时（用同一 GDS 文件），预期仓颉桥接因省去逐字段 napi_create 开销，大文件解析应有明显提升。

```bash
git add entry/src/main/cangjie/ entry/src/main/cpp/ entry/src/main/ets/services/NativeHongTuService.ets
git commit -m "feat(cangjie): 用仓颉 FFI 替代 napi_init.cpp 桥接层"
```

#### Task 11.3: 仓颉重写 GDSII 写入器（替代 LayoutExportService.GdsByteWriter）

**Files:**
- Create: `entry/src/main/cangjie/src/gdsii_writer.cj`
- Modify: `entry/src/main/ets/services/LayoutExportService.ets`

- [ ] **Step 1: 在仓颉侧用 ArrayBuffer 实现 GDSII 写入器**

```cangjie
// entry/src/main/cangjie/src/gdsii_writer.cj
package hongtu_cj

public class GdsiiWriter {
    private let buffer: ArrayBuffer
    private var pos: Int = 0

    public init(capacity: Int) {
        this.buffer = ArrayBuffer(capacity)
    }

    // 写入 16 位大端整数
    public func writeInt16(value: Int16): None {
        let view = DataView(this.buffer)
        view.setInt16(this.pos, value, bigEndian: true)
        this.pos += 2
    }

    // 写入 GDSII 8 字节浮点（与 C++ gdsiiFloatToDouble 互逆）
    public func writeReal8(value: Float64): None {
        // GDSII 浮点格式：1 位符号 + 7 位指数 + 56 位尾数
        let absVal = if (value < 0) -value else value
        let sign: UInt8 = if (value < 0) 0x80 else 0x00
        if (absVal == 0.0) {
            for (_ in 0..<8) { writeByte(0) }
            return
        }
        var exp: Int16 = 0
        var mantissa: Float64 = absVal
        while (mantissa >= 1.0) { mantissa /= 16.0; exp += 1 }
        while (mantissa < 0.0625) { mantissa *= 16.0; exp -= 1 }
        let byte0 = sign | UInt8(((exp & 0x7F) | 0x40))
        writeByte(byte0)
        // 7 字节尾数
        var m = mantissa * 16.0
        for (i in 0..<7) {
            let digit = Int64(m) & 0xFF
            writeByte(UInt8(digit))
            m = (m - Float64(digit)) * 256.0
        }
    }

    public func writeByte(b: UInt8): None {
        let view = DataView(this.buffer)
        view.setUInt8(this.pos, b)
        this.pos += 1
    }

    public func writeBytes(bytes: Array<UInt8>): None {
        for (b in bytes) { writeByte(b) }
    }

    // 写入 GDSII 记录
    public func writeRecord(recordType: Int16, dataType: Int16, data: Array<UInt8>): None {
        let len = Int16(data.size + 4)
        writeInt16(len)
        writeByte(UInt8(dataType & 0xFF))
        writeByte(UInt8((recordType >> 8) & 0xFF))
        writeByte(UInt8(recordType & 0xFF))
        writeBytes(data)
    }

    public func getBuffer(): ArrayBuffer {
        return this.buffer.slice(0, this.pos)
    }
}
```

- [ ] **Step 2: 导出到 ArkTS 并替换 LayoutExportService 中的 GdsByteWriter**

将 `LayoutExportService.ets` 中的 `GdsByteWriter` 类替换为调用仓颉侧 `GdsiiWriter`：

```typescript
// ArkTS 侧
private cjWriter = cjLib.createGdsiiWriter(1024 * 1024);
// 写入操作转发到仓颉
this.cjWriter.writeReal8(value);
// 最终获取 ArrayBuffer
const buf = this.cjWriter.getBuffer();
```

- [ ] **Step 3: 性能对比 + Commit**

用同一组 Shape 数据导出 GDSII，对比 ArkTS `number[]` push vs 仓颉 ArrayBuffer 的耗时。预期仓颉版在大文件导出时快 5-10 倍。

```bash
git add entry/src/main/cangjie/src/gdsii_writer.cj entry/src/main/ets/services/LayoutExportService.ets
git commit -m "feat(cangjie): GDSII 写入器用仓颉 ArrayBuffer 替代 number[] 字节装箱"
```

#### Task 11.4: 仓颉重写 DrcService 并行分块检查

**Files:**
- Create: `entry/src/main/cangjie/src/drc_engine.cj`
- Modify: `entry/src/main/ets/services/DrcService.ets`

- [ ] **Step 1: 在仓颉侧用协程 + Channel 实现并行 DRC 分块检查**

```cangjie
// entry/src/main/cangjie/src/drc_engine.cj
package hongtu_cj

import std.sync.*

public struct DrcTile {
    public let minX: Float64
    public let minY: Float64
    public let maxX: Float64
    public let maxY: Float64
    public let index: Int
}

public struct DrcViolation {
    public let ruleName: String
    public let layerNumber: Int
    public let x: Float64
    public let y: Float64
    public let severity: String   // "error" | "warning"
    public let message: String
}

public class DrcEngine {
    // 并行分块检查
    public static func runTiledParallel(
        shapes: Array<Shape>,
        rules: Array<DrcRule>,
        tileSize: Float64,
        bounds: ShapeBounds
    ): Array<DrcViolation> {
        // 生成 tile 列表
        var tiles = Array<DrcTile>()
        var idx = 0
        var y = bounds.minY
        while (y < bounds.maxY) {
            var x = bounds.minX
            while (x < bounds.maxX) {
                tiles.add(DrcTile(x, y, x + tileSize, y + tileSize, idx))
                idx += 1
                x += tileSize
            }
            y += tileSize
        }

        // 创建 Channel 收集结果
        let resultChan = Channel<Array<DrcViolation>>(capacity: tiles.size)

        // 为每个 tile 启动协程
        for (tile in tiles) {
            spawn {
                let tileShapes = filterShapesInTile(shapes, tile)
                let violations = checkRulesOnTile(tileShapes, rules, tile)
                resultChan.send(violations)
            }
        }

        // 汇总结果
        var allViolations = Array<DrcViolation>()
        for (_ in 0..<tiles.size) {
            let tileViolations = resultChan.receive()
            allViolations.addAll(tileViolations)
        }
        return allViolations
    }

    // 空间网格索引优化 O(N²) 间距检查
    public static func checkMinSpacingGrid(
        shapes: Array<Shape>,
        minSpacing: Float64
    ): Array<DrcViolation> {
        // 构建空间网格
        let gridSize = minSpacing * 2
        let grid = buildSpatialGrid(shapes, gridSize)
        var violations = Array<DrcViolation>()

        for (shape in shapes) {
            let candidateCells = queryNearbyCells(grid, shape, gridSize)
            for (other in candidateCells) {
                if (other.id == shape.id) { continue }
                let dist = shapeDistance(shape, other)
                if (dist < minSpacing) {
                    violations.add(DrcViolation(...))
                }
            }
        }
        return violations
    }
}
```

- [ ] **Step 2: 导出到 ArkTS 并替换 DrcService 的分块逻辑**

修改 `DrcService.ets` 的 `runRuleTiled`：

```typescript
// 原 ArkTS 串行双层循环替换为仓颉并行
const violations = cjLib.runTiledParallel(
  this.shapes,
  rules,
  this.tileSize,
  bounds
);
```

- [ ] **Step 3: 性能对比 + Commit**

用大版图（10000+ shapes）运行 DRC，对比原 ArkTS 串行 vs 仓颉并行。预期提速 5-20 倍（取决于 tile 数量与核数）。

```bash
git add entry/src/main/cangjie/src/drc_engine.cj entry/src/main/ets/services/DrcService.ets
git commit -m "feat(cangjie): DRC 分块检查用仓颉协程并行化，提速 5-20 倍"
```

#### Task 11.5: 仓颉重写渲染数据序列化（shapesToBatches）

**Files:**
- Create: `entry/src/main/cangjie/src/render_serializer.cj`
- Modify: `entry/src/main/ets/components/GlCanvas.ets`

- [ ] **Step 1: 在仓颉侧实现批次合并 + ArrayBuffer 序列化**

```cangjie
// entry/src/main/cangjie/src/render_serializer.cj
package hongtu_cj

public class RenderSerializer {
    // 合并同层同类型批次，减少 GL draw call
    public static func shapesToBatchesMerged(shapes: Array<Shape>): ArrayBuffer {
        // 按图层+类型分组
        let groups = HashMap<String, Array<Shape>>()
        for (shape in shapes) {
            let key = "${shape.layerNumber}-${shape.type}"
            groups.getOrDefault(key, Array<Shape>()).add(shape)
        }

        // 合并每组为一个 batch
        var batches = Array<RenderBatch>()
        for ((key, groupShapes) in groups) {
            let mergedVertices = mergeVertices(groupShapes)
            batches.add(RenderBatch(...))
        }

        // 序列化为 ArrayBuffer（直接给 C++ 零拷贝）
        return serializeToArrayBuffer(batches)
    }

    private static func mergeVertices(shapes: Array<Shape>): Array<Float32> {
        var vertices = Array<Float32>()
        for (shape in shapes) {
            if (shape.type == RECT) {
                // 矩形扩展为 4 顶点
                let p0 = shape.points[0]
                let p1 = shape.points[1]
                vertices.add(Float32(p0.x)); vertices.add(Float32(p0.y))
                vertices.add(Float32(p1.x)); vertices.add(Float32(p0.y))
                vertices.add(Float32(p1.x)); vertices.add(Float32(p1.y))
                vertices.add(Float32(p0.x)); vertices.add(Float32(p1.y))
            } else {
                for (p in shape.points) {
                    vertices.add(Float32(p.x)); vertices.add(Float32(p.y))
                }
            }
        }
        return vertices
    }

    private static func serializeToArrayBuffer(batches: Array<RenderBatch>): ArrayBuffer {
        // 计算总大小
        var totalSize = 0
        for (batch in batches) {
            totalSize += 32 + batch.vertices.size * 4  // header + vertices
        }
        let buffer = ArrayBuffer(totalSize)
        let view = DataView(buffer)
        var offset = 0
        for (batch in batches) {
            view.setInt32(offset, batch.type); offset += 4
            view.setInt32(offset, batch.layerNumber); offset += 4
            view.setFloat32(offset, batch.color[0]); offset += 4
            // ... color[1..3]
            view.setInt32(offset, batch.vertices.size); offset += 4
            for (v in batch.vertices) {
                view.setFloat32(offset, v); offset += 4
            }
        }
        return buffer
    }
}
```

- [ ] **Step 2: C++ 侧 NapiSetRenderData 改为接收 ArrayBuffer**

修改 `xcomponent_plugin.cpp` 的 `NapiSetRenderData`，用 `napi_get_typedarray_info` 直接拿裸指针，零拷贝访问 vertices。

- [ ] **Step 3: ArkTS 侧 GlCanvas 改用仓颉序列化**

```typescript
// GlCanvas.ets
private updateGLRenderData(): void {
  const arrayBuffer = cjLib.shapesToBatchesMerged(this.shapes);
  this.nativeModule.setRenderDataFromBuffer(arrayBuffer);
}
```

- [ ] **Step 4: 性能对比 + Commit**

对比原 ArkTS 1:1 batches vs 仓颉合并 batches，预期 draw call 减少 50%+，NAPI 边界开销减少 80%+。

```bash
git add entry/src/main/cangjie/src/render_serializer.cj entry/src/main/cpp/xcomponent_plugin.cpp entry/src/main/ets/components/GlCanvas.ets
git commit -m "feat(cangjie): 渲染数据序列化用仓颉合并批次+ArrayBuffer 零拷贝"
```

#### Task 11.6: 仓颉 value 类型优化数据模型

**Files:**
- Create: `entry/src/main/cangjie/src/models.cj`
- Modify: `entry/src/main/ets/models/GdsiiData.ets`

- [ ] **Step 1: 在仓颉侧定义 value 类型数据模型**

```cangjie
// entry/src/main/cangjie/src/models.cj
package hongtu_cj

// 纯 value 类型，栈分配
public struct Point {
    public let x: Float64
    public let y: Float64

    public init(x: Float64, y: Float64) {
        this.x = x
        this.y = y
    }

    // 运算符重载
    public operator func +(other: Point): Point {
        return Point(this.x + other.x, this.y + other.y)
    }

    public operator func -(other: Point): Point {
        return Point(this.x - other.x, this.y - other.y)
    }
}

public struct ShapeBounds {
    public let minX: Float64
    public let minY: Float64
    public let maxX: Float64
    public let maxY: Float64

    public func width(): Float64 { return maxX - minX }
    public func height(): Float64 { return maxY - minY }
    public func contains(p: Point): Bool {
        return p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }
    public func intersects(other: ShapeBounds): Bool {
        return !(other.minX > maxX || other.maxX < minX || other.minY > maxY || other.maxY < minY)
    }
}

// Shape 是引用类型（可变 selected 状态）
public class Shape {
    public var id: String
    public var type: Int32         // 0=RECT, 1=POLYGON, 2=PATH, 3=TEXT, 4=INSTANCE
    public var layerNumber: Int32
    public var datatype: Int32
    public var points: Array<Point>
    public var selected: Bool = false
    public var pathWidth: Float64 = 0
    // ... 其余字段
}
```

- [ ] **Step 2: 几何计算函数用 value 类型优化**

```cangjie
public func getShapeBounds(shape: Shape): ShapeBounds {
    if (shape.points.isEmpty) {
        return ShapeBounds(0, 0, 0, 0)
    }
    var minX = shape.points[0].x
    var minY = shape.points[0].y
    var maxX = minX
    var maxY = minY
    for (i in 1..<shape.points.size) {
        let p = shape.points[i]
        if (p.x < minX) { minX = p.x }
        if (p.x > maxX) { maxX = p.x }
        if (p.y < minY) { minY = p.y }
        if (p.y > maxY) { maxY = p.y }
    }
    return ShapeBounds(minX, minY, maxX, maxY)
}

// Shoelace 公式计算多边形面积
public func getPolygonArea(points: Array<Point>): Float64 {
    if (points.size < 3) { return 0 }
    var area: Float64 = 0
    for (i in 0..<points.size) {
        let j = (i + 1) % points.size
        area += points[i].x * points[j].y
        area -= points[j].x * points[i].y
    }
    return (area / 2.0).abs()
}
```

- [ ] **Step 3: 导出到 ArkTS 供 EditService/AdvancedEditService 调用**

- [ ] **Step 4: Commit**

```bash
git add entry/src/main/cangjie/src/models.cj
git commit -m "feat(cangjie): 数据模型用 value 类型优化（Point/ShapeBounds）"
```

#### Task 11.7: 仓颉并行化 GDSII/OASIS 解析调度

**Files:**
- Create: `entry/src/main/cangjie/src/parallel_parser.cj`
- Modify: `entry/src/main/ets/services/FileImportService.ets`

- [ ] **Step 1: 在仓颉侧用协程实现并行解析调度**

```cangjie
// entry/src/main/cangjie/src/parallel_parser.cj
package hongtu_cj

import std.sync.*

public class ParallelParser {
    // GDSII 按 CELL 边界分块并行解析
    public static func parseGdsiiParallel(filePath: String): ParseResult {
        // 第一遍：快速扫描获取 CELL 偏移量表
        let cellOffsets = quickScanCellOffsets(filePath)

        // 创建 Channel 收集各 CELL 解析结果
        let resultChan = Channel<CellParseResult>(capacity: cellOffsets.size)

        // 为每个 CELL 启动协程并行解析
        for (offset in cellOffsets) {
            spawn {
                let cellResult = parseCellAtOffset(filePath, offset)
                resultChan.send(cellResult)
            }
        }

        // 汇总所有 CELL 结果
        var allShapes = Array<Shape>()
        var allLayers = Array<LayerInfo>()
        for (_ in 0..<cellOffsets.size) {
            let cellResult = resultChan.receive()
            allShapes.addAll(cellResult.shapes)
            allLayers.addAll(cellResult.layers)
        }
        return ParseResult(success: true, shapes: allShapes, layers: allLayers)
    }

    // OASIS CBLOCK 并行解压
    public static func parseOasisParallel(filePath: String): ParseResult {
        // OASIS 文件由多个 CBLOCK 组成，可并行解压
        let cblockOffsets = quickScanCblockOffsets(filePath)
        let resultChan = Channel<CblockResult>(capacity: cblockOffsets.size)

        for (offset in cblockOffsets) {
            spawn {
                let decompressed = decompressCblock(filePath, offset)
                let shapes = parseDecompressedBlock(decompressed)
                resultChan.send(CblockResult(shapes: shapes))
            }
        }

        var allShapes = Array<Shape>()
        for (_ in 0..<cblockOffsets.size) {
            let result = resultChan.receive()
            allShapes.addAll(result.shapes)
        }
        return ParseResult(success: true, shapes: allShapes)
    }
}
```

- [ ] **Step 2: ArkTS 侧 FileImportService 改用仓颉并行解析**

```typescript
// FileImportService.ets
async function parseImported(sandboxPath: string): Promise<GdsiiResult> {
  const ext = sandboxPath.split('.').pop()?.toLowerCase();
  if (ext === 'gds' || ext === 'gdsii') {
    return cjLib.parseGdsiiParallel(sandboxPath);  // 仓颉并行
  } else if (ext === 'oas' || ext === 'oasis') {
    return cjLib.parseOasisParallel(sandboxPath);  // 仓颉并行
  }
}
```

- [ ] **Step 3: 性能对比 + Commit**

用大 GDS/OASIS 文件（≥50MB）对比原 C++ 同步解析 vs 仓颉并行解析。预期提速 2-4 倍（取决于 CELL 数量与核数）。注意：仓颉并行调度层调用 C++ 解析核心（通过 FFI），不重写解析算法本身。

```bash
git add entry/src/main/cangjie/src/parallel_parser.cj entry/src/main/ets/services/FileImportService.ets
git commit -m "feat(cangjie): GDSII/OASIS 解析用仓颉协程并行调度"
```

---

### 阶段十（可选）：状态管理升级到 V2

> ⚠️ 此阶段工作量大且需整体迁移，V1/V2 不可混用。建议在其余阶段全部完成且稳定后，单独作为一次大型重构。本阶段仅给出任务大纲，不展开代码。

#### Task 10.1: 核心模型迁移到 @ObservedV2 + @Trace
- `models/GdsiiData.ets`：Layer/Cell/Shape 加 @ObservedV2 + @Trace
- `workbench/WorkbenchModels.ets`：ViewState/CanvasState 等

#### Task 10.2: 组件迁移到 @ComponentV2
- 全项目 @Component → @ComponentV2
- @State → @Local，@Prop → @Param + @Once，@Link → @Param + @Event
- @Watch → @Monitor

#### Task 10.3: 全局存储迁移到 AppStorageV2 / PersistentStorageV2
- AppStorage.SetOrCreate → AppStorageV2.connect
- PersistentStorage.PersistProp → PersistentStorageV2.connect
- 验证：最近文件、图层搜索、AI 配置、宏、快捷键、视图预设 持久化均正常

#### Task 10.4: 暗色模式完整适配
- EntryAbility.onConfigurationUpdate 中监听颜色模式变化，调 ThemeManager.toggleDark
- 全项目颜色引用通过 COLORS（已是动态对象）自动响应

---

## 风险与回退

| 风险 | 影响 | 回退方案 |
|---|---|---|
| SymbolGlyph HMSymbol 字符码点不对 | 图标显示为方框 | 该图标回退用 Image + SVG 资源 |
| bindContextMenu 在某些设备行为不一致 | 右键菜单不弹 | 回退用 bindMenu + 显式触发按钮 |
| SideBarContainer(AUTO) 在折叠屏异常 | 布局错乱 | 回退用原 Row + layoutWeight + 断点判断 |
| SegmentButton 视觉与设计稿不符 | 样式不一致 | 自定义 SegmentButton 样式或回退用 Tabs |
| V2 装饰器迁移引入 bug | 状态不响应 | 整体回退到 V1（git revert 阶段十） |
| LazyForEach 与现有过滤逻辑冲突 | 图层列表不刷新 | DataSource setData 时手动 notifyDataReloaded |
| **backgroundBlurStyle 无法采样 XComponent 输出** | 停靠面板毛玻璃失效（呈现纯色或透明） | 停靠面板退回纯色背景，仅浮层/弹窗用模糊 |
| **多层 backgroundBlurStyle 叠加 GPU 负载高** | 滑动卡顿、发热 | 同视觉栈只保留 1-2 层实时模糊，其余改半透明纯色或 effectkit 静态模糊 |
| **沉浸式 setWindowLayoutFullScreen 后内容被状态栏遮挡** | 标题栏文字被状态栏覆盖 | WorkbenchTitleBar 顶部 padding 加状态栏高度避让 |
| **ShadowStyle.OUTER_FLOATING_LG 在 V14 枚举不可见** | 编译报错 | 改用 OUTER_FLOATING_MD 或自定义 ShadowOptions |
| **毛玻璃在深色模式下文字可读性下降** | 文字与背景对比度不足 | 模糊层下叠加半透明纯色兜底，或调整 BackgroundBlurStyleOptions.adaptiveColor |
| **仓颉生态初期，社区案例少** | 遇到问题难找参考 | 锁定 1.0 LTS 版本，优先用 FFI 复用 C++ 而非全量重写 |
| **仓颉 GC 与 C++ 手动内存管理所有权冲突** | 双重释放或内存泄漏 | FFI 边界明确所有权：C++ 分配的由 C++ 释放，仓颉分配的由仓颉 GC 回收 |
| **cjpm + cmake + hvigor 三套构建共存复杂** | 构建失败、CI 配置复杂 | 先在最小模块验证混合构建链路，再逐步扩大仓颉覆盖范围 |
| **仓颉协程并行 DRC 结果顺序不确定** | 违规列表顺序变化影响测试 | 用 Channel 按 tile index 排序汇总，或结果排序后再返回 |
| **仓颉 @repr(C) struct 与 C++ 结构体布局不一致** | FFI 调用读到错误字段 | 用单元测试断言 sizeof 和 offsetofs，或用 oasis_smoke.cpp 作回归基准 |

## 验证清单（每阶段完成后执行）

1. **构建**：`hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon` 通过
2. **核心流程**：打开 GDS → 浏览 → 选中 → 编辑（移动/对齐/改图层）→ DRC → 保存导出，全流程无报错
3. **持久化**：重启应用后，最近文件、图层搜索关键字、AI 配置、宏、快捷键、视图预设 均保留
4. **多设备**：sm（手机）/ md（小平板）/ lg（大平板/PC）三断点下布局正确
5. **触控**：双指缩放、单指拖动平移、长按菜单、双击进子 Cell 均正常
6. **桌面**：鼠标右键菜单、滚轮缩放（若已实现）、键盘快捷键 均正常
7. **回归**：原 PRD 4.x 节描述的所有功能（GUI 弹窗放置实例、GUI 开关配置 DRC、图层搜索持久化、右键菜单集成编辑/测量/对齐/改图层/DRC、画布两点移动+长按微调+框选、Cell 层级默认2级+滑块）均不受影响

---

## 执行顺序建议

1. **阶段一**（基础设施：主题色/字体/图标）→ 必须最先，阻塞其余
2. **阶段九·补 Task 9·M.1**（材质令牌模块）→ 与阶段一并列，提供 Elevation/Blur/RADIUS/ALPHA 令牌
3. **阶段二**（弹窗）→ 独立性高，可并行
4. **阶段三**（菜单+分段）→ 依赖阶段一的 Icons
5. **阶段五**（图标）→ 可与阶段二/三并行
6. **阶段四**（布局）→ 较大改动，建议在阶段二/三验证稳定后
7. **阶段六**（动画）→ 依赖布局稳定
8. **阶段七**（手势）→ 独立
9. **阶段八**（列表）→ 独立
10. **阶段九**（反馈+系统API）→ 独立
11. **阶段九·补 Task 9·M.2~9·M.9**（材质系统：沉浸式/毛玻璃/阴影/透明度令牌化）→ 依赖阶段一、二、三、四完成（弹窗与布局已稳定），是视觉收口阶段
12. **阶段十一**（仓颉混合开发）→ 独立于 UI 重构，可与阶段四之后任意阶段并行；建议先做 Task 11.1（环境搭建）验证可行性，再按 P0（11.2/11.3/11.4）→ P1（11.5/11.7）→ P2（11.6）顺序推进
13. **阶段十**（V2 状态管理）→ 最后，可选

每个阶段完成后独立 commit、独立验证、可独立回退。
