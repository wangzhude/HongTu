# 操作面板视觉模板 — 2026-10-01

生成方式：内置 image_gen。先生成、检查并展示，再实现原生 ArkUI 控件。两张图片是视觉参考，不能作为应用验收证据。

- `boolean-preview-template.png`：布尔源 A/B、交换、操作类型、结果预览、当前 Cell、输出 layer/datatype、保留原图、DBU 与提交/取消。
- `command-search-template.png`：按任务搜索命令、可读的不可用原因、当前选区与下一步、键盘操作。

沿用鸿图现有工作台、主题令牌和组件。实现中对象数量、坐标、条件和快捷键来自真实文档与配置，不复制图片中的示意值。原工作台导航不调整。

## 生成提示词

### 布尔预览

Create a high-fidelity UI design reference for a new Boolean operation preview dialog in the existing HongTu 鸿图 HarmonyOS NEXT professional chip layout editor on a 3:2 desktop 2-in-1 display. This is an engineering utility, not marketing. Preserve a dense professional white/light-gray workbench, Harmony blue #0A59F7, dark ink #182431, thin gray dividers, native HarmonyOS form controls, small restrained rounded corners. Background: thin chip-layout grid and colored mask polygons with a left layer list, top HongTu toolbar. Center a readable native dialog titled 布尔运算预览. Show source A #12 L1/D0 in blue and source B #19 L2/D5 in orange with small geometry thumbnails and a 交换 A/B button. Segmented operation options 并集 / 交集 / A 减 B / 异或, A 减 B selected. Side-by-side before/after geometry preview with accurately drawn subtraction. Below show 作用范围 当前 Cell TOP, output fields 图层 1 and Datatype 0, a checked 保留原图 checkbox, result count 2 个多边形, and a concise precision line DBU 1 nm. Bottom native buttons 取消 and 应用结果, blue primary. Small text explains cancelling does not modify source. Ensure legible Chinese labels and clear information hierarchy with adequate spacing; no pricing, no membership, no decorative illustration, no fake scientific results, no giant pills, no navigation redesign.

### 命令搜索

Create a high-fidelity UI design reference for a new task-oriented command search dialog in the existing HongTu 鸿图 HarmonyOS NEXT professional chip layout editor, desktop 3:2 display. Preserve professional light-gray/white native workbench with Harmony blue #0A59F7, dark ink #182431, thin gray separators and restrained corners. Background existing HongTu toolbar, layer sidebar, thin chip-layout grid and mask geometry, softly dimmed. Center a compact native dialog titled 搜索命令. At top a focused native search field placeholder 输入任务或命令，例如：只改一个阵列成员. Search value 布尔. A clean vertical command list shows 布尔运算预览, 批量修改属性, 为此处创建独立变体, 放置圆形, 每项 with a small consistent line icon, a short explanation and shortcut badge where relevant. Boolean row shows amber availability explanation 需要选择两个矩形或多边形 rather than unexplained gray disabled state; row remains readable. A details area displays 当前 Cell TOP · 已选 1 个对象, action buttons 定位所需对象 and 执行命令 with correct disabled primary for unsatisfied conditions. Footer Esc 关闭 · Enter 执行. Show clear task labels, keyboard access and concise next-step explanations, native HarmonyOS TextInput/Button/List components, no marketing, no pricing, no membership, no giant pills, no new navigation shell. This image is a UI template, not a screenshot of implemented code.
