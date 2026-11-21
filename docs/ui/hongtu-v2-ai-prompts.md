# AI 入口与助手参考图提示词

生成方式：内置 image_gen。仅用于界面概念参考；本轮不修改应用源码。

输入参考图：`hongtu-v2-01-canvas.png`。

## 主工作台 · AI 入口

输出：`hongtu-v2-05-ai-entry.png`

```text
Use case: ui-mockup.
Input image 1 is the exact edit target: the approved light HongTu EDA canvas-first desktop concept.
Make ONE precise UI edit: add a clearly visible global AI assistant button to the TOP RIGHT of the main toolbar, just left of the existing hamburger menu, using the ample blank area on the right of the zoom controls. The button is a tasteful rounded rectangle approximately 112px wide and 36px high with pale blue fill, thin blue outline, small blue sparkle icon and clearly legible exact Chinese label "AI 助手". This is a real primary application entry point with a text label, not an ambiguous icon. Align it vertically with 打开, 保存 and the existing zoom controls. Leave appropriate breathing room before the menu icon. Show the assistant CLOSED in this screen.
Preserve everything else from the input faithfully: landscape aspect ratio, brand, module rail, layer list, slim icon-only drawing toolbar, document tab, exact sample layout geometry, generous white canvas extending to the right edge, quiet blue-gray grid, bottom status bar and existing toolbar actions. Do not add a sidebar, floating dialogue, instructions, extra overlays, decorative graphics or large marketing text. No dark colors or new visual style. Clean native desktop software screenshot concept, crisp Chinese typography.
This is a UI reference image only; no code or real application screenshot claims.
```

## AI 助手 · 指令与修改预览

输出：`hongtu-v2-06-ai-assistant.png`

```text
Use case: ui-mockup.
Input image 1 is the layout and style reference: the approved clean light HongTu EDA canvas-first desktop. Generate the OPEN AI ASSISTANT state of this exact desktop application. Single flat landscape 16:10 UI screenshot concept, no device mockup.
Keep the recognizable brand, far-left module rail with 版图 active, compact layer/Cell sidebar, narrow icon-only drawing-tool strip, white canvas, faint blue-gray grid and illustrative semiconductor geometry from the input. Never recreate the former permanent full-height property sidebar.
IMPORTANT GLOBAL ENTRY: add a rounded 112px by 36px blue active button labelled exactly "AI 助手" with a small sparkle icon in the top-right toolbar, immediately left of the hamburger menu. The button is visibly active because the assistant is open. All other header controls retain their positions.
Open a purposeful floating assistant panel in the right part of the canvas: approximately 380px wide and 660px high, inset from the window right and bottom edges so the canvas remains visibly continuous around it. This is an on-demand, closable panel with small radius, thin neutral border and restrained shadow. It does not permanently divide the window or cover the sample geometry on the left.
Inside the panel use this clear practical hierarchy:
- Header "AI 版图助手", small pin and close x at the right.
- Compact row "模型" with a dropdown showing "已配置模型" and a small settings gear.
- Context chips "demo.gds", "TOP", "选中 1 个图形".
- A concise user instruction bubble: "把选中的 M1 矩形宽度改为 800 nm".
- Assistant response: "修改预览已生成".
- One modest modification card titled "待应用的修改", showing "对象：矩形 #12", "图层：M1", "宽度：600 → 800 nm", and "影响 1 个图形". At its bottom put the blue primary button "应用修改" and secondary "取消". Keep this card readable, avoid excessive prose.
- Beneath the card, one quiet previous-result row: "上一步：已移动 1 个图形" with a small "撤销" action. This shows where execution results appear, not an overall success badge for the pending change.
- Bottom composer anchored inside panel: multiline input placeholder "继续描述你的需求…" and a blue send arrow button. Above it, subtle suggestion chips "解释当前图形" and "检查选中区域".
On the canvas left of the assistant, select one blue M1 rectangle from a small illustrative layout with visible handles, show a faint dashed blue extension indicating the proposed width and a small nearby label "预览 · 未应用". Do not move other geometry. Allow ample white canvas around the preview.
Color scheme is white, very light cool gray, blue accents and near-black text, consistent with input. No multicolor AI gradient, giant sparkles, empty giant chat area or ambiguous empty right column. Render Chinese cleanly and accurately. A discreet bottom status label "示例数据 · 界面参考" makes the content clearly conceptual.
```

