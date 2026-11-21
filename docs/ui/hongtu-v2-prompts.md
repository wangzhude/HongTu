# 鸿图参考图第二轮提示词

数据管理最终稿还应用了 [局部调整提示词](hongtu-v2-data-refinement-prompt.md)，去掉重复导航及绘图专用控件。

模式：内置 image_gen 生图。用途：概念参考图，示例数据；本轮不修改应用源码。

参考图：`hongtu-b-light-white-canvas.png`。

## 01 全幅画布

输出：`hongtu-v2-01-canvas.png`

```text
Use case: ui-mockup.
Asset type: one high fidelity flat desktop application screenshot concept for the Chinese EDA layout editor 鸿图 / HongTu EDA. Landscape 16:10, approximately 1600 by 1000 pixels, no surrounding device mockup or presentation board.
Input image 1 is a STYLE REFERENCE for the approved clean light UI, white surfaces, thin cool-gray dividers, vivid blue active controls, restrained rounded corners, crisp simplified Chinese typography. Substantially redesign the information layout as specified below; do not preserve its permanent right sidebar.
Keep the same recognizable brand, a narrow far-left module rail labelled 版图, 验证, 数据, a quiet thin top command bar with 打开, 保存, undo/redo and compact 100% zoom controls, and a thin bottom status bar. Use high legibility and realistic functional UI density. No dark theme, dramatic glow, heavy glass, gradients across the whole interface, decorative dashboard cards, or stock photos.
Critical: NO fixed full-height panel on the right, NO empty 属性 column, NO unused right gutter. Use the recovered width for the actual task. Draw only the requested screen, no explanatory arrows or comparison collage. Labels should be concise and correctly written. All technical content is illustrative concept data; show a discreet 示例数据 label.
Screen: default layout editing workspace, module 版图 selected, nothing selected.
Keep a compact 200px layers/Cell sidebar immediately after the 56px module rail. Eight clean rows with small colored swatches and eye icons: 金属1, 金属2, 金属3, 多晶硅, 有源区, N井, P井, 通孔1. Search field above. Remove the oversized multi-column feeling of the reference. A slim 40px floating vertical drawing-tool bar sits near the upper-left edge of the canvas, icon-only with selection, measure, rectangle, polygon, path, text, instance, one active blue button. Toolstrip is secondary.
The white canvas extends all the way to the window's right edge and takes at least 78% of available work area width. Very subtle blue-gray small grid, slightly stronger widely spaced major grid, much quieter than the reference. Top-left document tab reads 示例版图 · demo.gds. Center-left of the large canvas show a small sparse believable 2D semiconductor layout: thin blue/cyan metal tracks with orthogonal bends, purple nested rectangular boundaries, a few red/green rectangles and yellow square contacts. No photographic chip, no motherboard illustration, no filled colorful background. Keep generous visible canvas around the geometry. No objects selected and no property popover. Canvas is the focus. Bottom status contains 就绪, X: 0.000, Y: 0.000, 100%, 网格 10 nm.

```

## 02 按需属性浮层

输出：`hongtu-v2-02-selection.png`

```text
Use case: ui-mockup.
Asset type: one high fidelity flat desktop application screenshot concept for the Chinese EDA layout editor 鸿图 / HongTu EDA. Landscape 16:10, approximately 1600 by 1000 pixels, no surrounding device mockup or presentation board.
Input image 1 is a STYLE REFERENCE for the approved clean light UI, white surfaces, thin cool-gray dividers, vivid blue active controls, restrained rounded corners, crisp simplified Chinese typography. Substantially redesign the information layout as specified below; do not preserve its permanent right sidebar.
Keep the same recognizable brand, a narrow far-left module rail labelled 版图, 验证, 数据, a quiet thin top command bar with 打开, 保存, undo/redo and compact 100% zoom controls, and a thin bottom status bar. Use high legibility and realistic functional UI density. No dark theme, dramatic glow, heavy glass, gradients across the whole interface, decorative dashboard cards, or stock photos.
Critical: NO fixed full-height panel on the right, NO empty 属性 column, NO unused right gutter. Use the recovered width for the actual task. Draw only the requested screen, no explanatory arrows or comparison collage. Labels should be concise and correctly written. All technical content is illustrative concept data; show a discreet 示例数据 label.
Screen: editing one selected rectangular layout object. Module 版图 selected. Same compact 56px module rail, 200px layer sidebar and 40px icon-only floating drawing strip as the redesign. Broad uninterrupted white canvas with very faint adaptive grid.
Show sparse simple illustrative 2D metal geometry around the middle of the canvas. A single horizontal rectangular shape in the central area has blue selection outline, faint blue fill and eight small square resize handles. All other geometry stays subdued.
A COMPACT floating contextual property popover appears just to the right of the selected object, separated from the window edge by clearly visible canvas. Popover approximately 260px wide and 270px high, small radius, thin border, subtle shadow. It floats inside the white canvas and DOES NOT stretch vertically, does not attach to the app edge, does not resize the canvas. Header 矩形 #12, with tiny pin icon and close x. A small layer dropdown 图层 M1. Two-column input grid with X 1200, Y 800, 宽 800, 高 420, units nm. Small footer actions 复制 and 删除. Omit long read-only metadata tables. The shape and its values are intentionally illustrative.
The rightmost quarter of the workspace visibly remains canvas, with grid continuing on all sides of this popover. A very subtle document label 示例版图 and 示例数据 in bottom status. This is a focused contextual inspector design, not a permanent right sidebar.

```

## 03 底部验证结果

输出：`hongtu-v2-03-verification.png`

```text
Use case: ui-mockup.
Asset type: one high fidelity flat desktop application screenshot concept for the Chinese EDA layout editor 鸿图 / HongTu EDA. Landscape 16:10, approximately 1600 by 1000 pixels, no surrounding device mockup or presentation board.
Input image 1 is a STYLE REFERENCE for the approved clean light UI, white surfaces, thin cool-gray dividers, vivid blue active controls, restrained rounded corners, crisp simplified Chinese typography. Substantially redesign the information layout as specified below; do not preserve its permanent right sidebar.
Keep the same recognizable brand, a narrow far-left module rail labelled 版图, 验证, 数据, a quiet thin top command bar with 打开, 保存, undo/redo and compact 100% zoom controls, and a thin bottom status bar. Use high legibility and realistic functional UI density. No dark theme, dramatic glow, heavy glass, gradients across the whole interface, decorative dashboard cards, or stock photos.
Critical: NO fixed full-height panel on the right, NO empty 属性 column, NO unused right gutter. Use the recovered width for the actual task. Draw only the requested screen, no explanatory arrows or comparison collage. Labels should be concise and correctly written. All technical content is illustrative concept data; show a discreet 示例数据 label.
Screen: verification workspace, module 验证 selected. Retain compact left layers panel and very narrow toolstrip, white canvas extends to right edge. The upper approximately 68% of main work area remains a useful layout canvas with a sparse realistic 2D layout and one selected red issue marker with a short measurement bracket.
A docked bottom results tray occupies approximately 28% of the main work area height, below the canvas and spanning from the layer sidebar boundary to the right window edge. This tray is the clear focus of the verification workflow; no right inspector at all.
Tray title 验证结果 with a small badge 3 条示例问题. Tabs 全部 3, 错误 2, 警告 1. Right side of tray header has 规则设置 secondary button, 重新检查 blue action and a collapse chevron.
Below is a calm readable table with columns 级别, 规则, 图层, 说明, 位置. Three concise rows: 错误 / 最小线宽 / M1 / 线宽低于规则值 / 1200,800 ; 错误 / 最小间距 / M2 / 间距低于规则值 / 2600,1100 ; 警告 / 包围检查 / VIA1 / 建议检查包围范围 / 3200,1700. First row softly blue-selected; its selection corresponds to the red highlight in the canvas above. Indicate illustrative UI data through small 示例数据, not an actual fabricated signoff claim. Avoid giant statistics cards or PASS badges. White gray blue palette remains identical to source style.

```

## 04 独立数据工作区

输出：`hongtu-v2-04-data.png`

```text
Use case: ui-mockup.
Asset type: one high fidelity flat desktop application screenshot concept for the Chinese EDA layout editor 鸿图 / HongTu EDA. Landscape 16:10, approximately 1600 by 1000 pixels, no surrounding device mockup or presentation board.
Input image 1 is a STYLE REFERENCE for the approved clean light UI, white surfaces, thin cool-gray dividers, vivid blue active controls, restrained rounded corners, crisp simplified Chinese typography. Substantially redesign the information layout as specified below; do not preserve its permanent right sidebar.
Keep the same recognizable brand, a narrow far-left module rail labelled 版图, 验证, 数据, a quiet thin top command bar with 打开, 保存, undo/redo and compact 100% zoom controls, and a thin bottom status bar. Use high legibility and realistic functional UI density. No dark theme, dramatic glow, heavy glass, gradients across the whole interface, decorative dashboard cards, or stock photos.
Critical: NO fixed full-height panel on the right, NO empty 属性 column, NO unused right gutter. Use the recovered width for the actual task. Draw only the requested screen, no explanatory arrows or comparison collage. Labels should be concise and correctly written. All technical content is illustrative concept data; show a discreet 示例数据 label.
Screen: Data management as a PURPOSE-BUILT FULL WORKSPACE, module 数据 selected. Replace the drawing canvas completely with a data workspace, and replace the layers sidebar with meaningful file navigation. No grid, no drawing tools, no property panel. Do not merely put file details in a skinny sidebar next to an empty canvas.
Keep the same 56px far-left module rail and brand/top command style as source. A compact 190px secondary navigation has 文件库, 最近打开, and Cell 层级. 文件库 selected. Main spacious but purposeful area begins with title 数据管理, a small 示例数据 label, and a blue 打开文件 button near top right. Under the heading a quiet tab row 文件, Cell 层级, 导入记录, with 文件 active.
Main content is one large well-designed file table, not scattered cards: columns 文件名, 格式, 顶层 Cell, Cell 数量, 大小, 最近打开. Three clear illustrative rows demo.gds / GDSII / TOP / 12 / 248 KB / 今天 ; array.oas / OASIS / ARRAY_TOP / 36 / 1.2 MB / 昨天 ; device.gds / GDSII / DEVICE / 8 / 96 KB / 昨天. Select demo.gds with pale blue row fill and a small file icon. Search field above table at left. Beneath the table a compact full-width details band for the selected file: demo.gds, TOP, 12 Cells, with 打开版图 primary text action and 查看 Cell 层级 secondary action. Keep the remainder as clean table/workspace space, no enormous blank right gutter, no permanent right detail column.
Use precise crisp Chinese, gentle gray white surfaces, blue selection, understated separators. This must clearly look like a different functional workspace in the same application.

```
