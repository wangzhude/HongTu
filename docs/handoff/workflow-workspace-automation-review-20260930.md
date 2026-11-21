# 工作区与自动化逐流程复查 — 2026-09-30

本代理查看真实可见控件、追踪回调到实际服务，并提取真实 ArkTS 方法做宿主回归，未操作由其他应用占用的 5555 设备。生产源码冻结后的最终日志核对已完成；root 的 Release HAP 构建日志确认成功。下文宿主“通过”不代表设备交互或在线模型验收，设备收尾由 root 单独记录。

## 本轮修复

1. `WorkspaceService.importProject` 不再继承文件内保存前的脏标记；重新打开已保存工程为干净状态。自动草稿仍保留真实未保存状态，历史恢复仍由 Index 创建脏副本。旧 sandbox GDS 路径和 URI 不再继承。
2. `WorkspaceDocument.viewMode` 保存 `edit`/`viewer`；旧文档缺省 `edit`，其他值拒绝。root 的 Index 捕获/激活同步该值，查看 A → 新建 B → 切回 A 不串模式。
3. Python 面板保存完整编辑草稿：脚本、范围、参数、需求、扫参和模板名称。关闭重开不再把依赖当前文档的脚本误放到“生成新文档”范围。未写完的参数 JSON 也能保留，运行前另行校验。
4. Python 模板保存扫参配方；旧模板清空上一个模板的扫参。历史行只代表一项实际运行，选择历史会清除旧扫参，避免重跑一项却执行整个旧扫描。失败历史/修改输入清除旧预览、摘要和标准输出。
5. Python AI 运行在等待模型前取得文档快照和上下文，并先校验参数。等待期间切换文档不能把为 A 生成的脚本偷偷应用到 B 的输入。取消后不会继续启动 Python；整个扫参结束后统一清理该次输入快照。
6. 宏同文档播放中任一步失败或抛异常，恢复整批开始前的 `EditSession`，包含几何、选区、剪贴板、undo/redo、脏基线与 ID 分配器；失败不发布前缀视图操作，成功仍一次撤销。此前的来源文档拒绝规则保持。
7. `ProjectPanel` 与 `ComponentLibraryPanel` 加 `actionStatus` 可见反馈；root 在两处构造回调传入 `this.statusText`，保存/打开/收藏/导入/删除失败可直接在面板内读取。
8. root 修复候选文档只在激活成功后发布，异步读取项目/版本后再次检查 8 标签上限；本代理以真实 Index 方法补充并发与失败回归。
9. Index 的系统选择/最近文件打开共享 `importInProgress` 守卫，各 await 后检查容量。大文件向导取消会闭合 Promise，finally 清理未使用的导入文件并把当前文档重新同步到 native。解析失败、非法几何或新文档 native 激活失败不发布候选、不改原文件关联；最近文件失败不删除其可复用来源。`applyParsedResult(imported, mode=EDIT)` 先完整验证 WorkspaceDocument，成功激活后发布，旧单参调用保持兼容。
10. root 的 Cell 结构接口让新建/重命名/删除共享单条几何+元数据 undo；此前的编辑历史保留，删除确认检查文档/版本及引用/导航/图层状态。实际方法测试覆盖所有权重排与 Cell 属性随 undo/redo 一同恢复。
11. root 将 AI 请求和待确认方案绑定文档 ID；后台生成跨文档 chunk 忽略，完成时拒绝文档或版本变化，应用时再检查文档 ID。测试特意保持两文档同 revision/Cell/选择数字，证明不会仅靠数值巧合放行。
12. 独立审查 Cell history 发现并先复现了剪贴板实例引用没有随结构变化更新的问题。`EditService.restoreStructure(from, to)` 现在在应用/撤销/重做时同步当前剪贴板：重命名保留 ID 并更新名字，增删按唯一 Cell 名称重映射，已不存在的实例引用丢弃，普通图形保留。覆盖结构变更前与变更后复制，防止粘贴越界或指向错误 Cell。
13. `EditService` 撤销/重做现在也把 `pathWidth`、`text` 恢复为原本的 `undefined`；此前条件赋值会留下后来的值。增加前后两个方向的真实方法回归。
14. 库/PCell 插入不再分别写几何与 Cell 表；候选文档经 `commitCellStructure` 一次提交。新增 Cell、依赖引用、Cell 属性分片及库属性一起撤销/重做。`EditStructureState.libProperties` 可选，兼容旧记录；不保存图层显示快照，撤销不会回滚用户后来改的颜色/可见性。分配 ID 以 session.nextId 为下限，避免复用历史中删除过的 ID。
15. `commitCellStructure` 自身保护完整编辑 session 和结构元数据；新建/重命名/删除后若元数据或刷新回调抛错，回滚几何、选择、undo/redo、剪贴板、dirty 基线及结构。恢复阶段再次刷新失败被捕获并报告，数据仍已恢复。库插入外层同时保护新增图层合并与提交后的刷新失败。
16. 补齐框选放大的快捷入口：默认 `KF`、中文标签“框选放大”、分类“视图”。`consumeInput` 仅续接已有助记码前缀，避免 `KF` 的 `F` 被单键适配抢走；空缓冲仍保留 `B` 矩形、`F` 适配。旧配置与导入配置仅补缺失的框选放大动作，已有自定义码及其前缀不被占用；备用短码也检查双向前缀冲突。安全双字母候选全部占用时保留未绑定动作供用户编辑。参数配置重开同时正确恢复数值型 DrawTool，避免矩形等工具值变成字符串。

## 控件到行为核对

| 实际入口/控件 | 流程与失败边界 | 证据 |
| --- | --- | --- |
| 更多功能 → 新建/工程与恢复；标签栏 `+` | 库名、顶层名、正有限 DBU 验证；新建独立标签，失败保留原编辑态和标签容量 | ProjectPanel 输入/新建回调；Index workspace 新建失败与模式回归 |
| 标签标题、`×` | 切换保留每个文档的几何/undo/选区/图层/视图；关闭脏文档经保存/放弃确认；切换或激活失败不得关闭错误标签 | Index workspace 36 项 |
| Cell 树“新建/重命名/删除”及撤销/重做 | Cell 元数据与几何共享一条历史；复制的实例引用同步结构编号；锁层导致整批拒绝；空 Cell 可撤销，保存基线与切页会话保留 | Index workspace 结构回归，含属性分片 dtype/顺序/快照隔离、非零 Top 与选区、clipboard 双向历史 |
| 工程面板“保存工程/打开工程” | 保存前冻结快照；保存期间切页或新增 Cell 不能标清新修改；打开后去旧缓存来源、保持工程模式且干净 | Index workspace + Workspace recovery |
| “创建版本/恢复为副本” | 不覆盖当前编辑；版本读取后新 ID、无原保存 URI、可独立修改；等待期间容量满则不发布候选 | Workspace recovery 不可变历史；Index 并发历史与副本回归 |
| 自动草稿/应用重开 | 写完整文档再原子发布索引；索引损坏回退 previous，单文档损坏不阻止其他标签；清理保留 current/previous/checkpoint | Workspace recovery 22 项；设备强制重启本轮未执行 |
| 个人器件库“收藏当前 Cell/收藏 PCell 参数” | Cell 收藏包含依赖层级；参数收藏要求已选 PCell；保存失败不改变内存库，队列后续操作可继续 | 可见 enabled 条件；真实 ComponentLibraryService 并发/失败/重开测试 |
| 库搜索、坐标、“放置/删除/导入/导出” | 搜索名称/分类/类型；坐标须非空有限；导入总量预算和全量校验，发布失败保留旧库；同名同分类导入去重 | ComponentLibraryPanel/Service 源码；Workspace recovery 库部分 |
| 库/PCell 放置 → 撤销 → 重做 | 插入完整候选经结构事务；几何、引用、Cell 定义与属性、库属性一次恢复；不回滚图层显示设置；锁层或回调失败保留旧 session | features_editor 37 项，实际 Index 插入/结构方法、EditService 与 WorkspaceService |
| AI 助手输入 → 发送 → 方案 → 确认/取消 | 命令先预览，文档 ID/版本/选区/当前 Cell/层改变时拒绝；执行失败整批恢复，成功一次 undo，几何修改后 DRC | index_ai_batch 本轮 10 项、既有 readonly 10 项；本轮未请求在线模型 |
| Python 范围选择、参数 JSON、“运行脚本/AI 生成并运行” | new/document/selection 副本；参数错误先拒绝，快照绑定运行开始文档；AI 等待期间取消不得执行 | 新 python_panel_workflow 7 项；input cleanup 9 项 |
| 扫参名称/数值、“取消” | 一个数字参数 1–16 值；每项独立原始输入，空值拒绝；已完成结果保留，取消不执行后续项 | automation workspace 9 项；input cleanup 全扫参生命周期 |
| Python 预览、“载入版图/合并到当前版图” | 载入打开新标签；document 模式隐藏合并，其他可合并；传递 artifact 原文档/版本，Index 在 parse 前后校验，拒绝保留预览；多个独立顶层不得合并 | 面板真实 loadGenerated 回归；Index applyPythonResult 源码边界 |
| 个人模板、运行历史、打开/导出脚本 | 模板保存 scope/params/sweep；历史选中还原单次参数和结果；失败记录无陈旧预览；脚本文件经 bounded UTF-8 picker；重开恢复完整草稿 | automation workspace + python_panel_workflow |
| 宏“录制/停止/取消” | 起始来源 workspace ID；切页前保存旧录制；激活失败保留旧录制；取消丢弃录制、不撤销手工绘图 | 宏服务来源回归；Index workspace 录制切页/激活失败 |
| 宏“管理·编辑/导入/导出” | 名称、说明、步骤 JSON、顺序、另存副本/删除；内置宏不能直接覆盖；导入集合先全量校验再添加；来源随复制/持久化/导出保留 | automation workspace + macro scope 9 项；实际 manager save 方法 |
| 宏“运行” | 固定 shape/Cell ID 必须原文档；旧无归属敏感宏整批拒绝；同文档 stale ID 或 throw 也整批恢复；纯创建跨文档可用 | macro scope 9 项，含真实 EditService/执行器 |

## 本轮已执行门禁

- `tools/workspace_recovery_host_check.mjs`：22/22。
- `tools/index_workspace_host_check.mjs`：36/36；在原工作区测试中加入真实导入方法和 Cell 结构方法，避免重复套件。结构审查先以 4 项失败证实问题；后补创建/重命名/删除回调异常及恢复刷新重复异常的回滚检查。
- `tools/index_ai_batch_host_check.mjs`：10/10；新增真实请求回调与待确认应用边界。
- `tools/macro_document_scope_host_check.mjs`：9/9。
- `tools/automation_workspace_host_check.mjs`：9/9。
- 新增 `tools/python_panel_workflow_host_check.mjs`：7/7，已加入 `check_all.sh`。
- `tools/python_input_cleanup_host_check.mjs`：9/9。
- `tools/layer_access_host_check.mjs`：29/29。
- `tools/features_editor_host_check.mjs`：37/37；harness 接入实际 Index 结构提交/恢复方法及真实 EditService 回调，覆盖库/PCell 元数据 undo/redo、完整 session 拒绝恢复与历史 ID 不复用。
- 指定改动文件 `git diff --check`、`bash -n tools/check_all.sh` 通过。

以上 9 套共 **168 项**，最终统一证据为 `artifacts/workflow-completion-20260930/host-final.log`：layer_access 第 71 行、features_editor 第 109 行、workspace_recovery 第 132 行、index_workspace 第 169 行、automation_workspace 第 179 行、macro_document_scope 第 189 行、index_ai_batch 第 236 行、python_input_cleanup 第 263 行、python_panel_workflow 第 271 行。旧的 `editor-features_editor.log` 是 34 项的较早运行，不用于最终计数；完整 Cell/library 结构撤销以统一日志的 37 项为准。

补充最终证据：`python-final.log` 为 18/18（test_bridge 5、test_workspace 6、test_verification 7）；`build-release-final.log` 第 584 行确认 `BUILD SUCCESSFUL`。`host-final.log` 最后停在旧 keyboard 断言失败，不能将整份日志描述为全量门禁通过；后续 `keyboard-final.log` 第 11 行单套 10/10 已通过。以上日志均在 `artifacts/workflow-completion-20260930/`，本次仅核对记录，没有重跑或修改生产源码。

随后追加框选放大可达性修复：`tools/shortcut_profile_host_check.mjs` 为 10/10，证据 `artifacts/workflow-completion-20260930/shortcut-profile-final.log`，已加入统一入口。该套执行真实 ShortcutService 和 Index 单键方法，覆盖 KF、B/F 不变、旧配置迁移、码/前缀冲突、参数类型、重开及无绑定空间。root 接入续码优先顺序后的 `canvas_keyboard_host_check.mjs` 本代理专项复跑为 11/11（新增已有拼音前缀优先于单键）；此追加记录不改变上文旧日志的实际内容和 9 套 168 项计数。源码修改仅 ShortcutService，Index 入口由 root 完成。

## 仍需区分的范围

- Python 历史只保留 40 条、模板 32 个，结果文件不会因历史淘汰而自动删除；文件缓存被系统清理后，历史不是完整文档归档。完整保留应载入后保存工程/GDS。
- 扫参是单参数扫描，没有多参数笛卡尔积。Python 选区结果可作为新 Cell 合并，未提供“就地替换原选区”。
- 宏是可编辑命令 JSON，不是图形化步骤设计器；不做跨文档 literal ID 重映射。来源 workspace ID 不同需重新录制。
- 文件选择器、真实凭据连接、在线 AI、设备重启恢复和小屏排版由 root 的设备记录单独说明。本代理未执行这些交互，未据宿主通过推断设备可用。
- 最终 ArkTS/HAP 构建由 root 统一执行且已有成功日志；宿主按真实服务逻辑验证，构建与宿主通过均不替代实际弹窗/文件选择器交互。

## 后续逐流程复查：编辑状态与参数窗口

本追加批次修改后已冻结源码，未操作设备、未运行共享 HAP 构建；上文早期日志的计数保持不变。

- `Index.workspaceReady` 改为 `@State`，使异步恢复结束能更新属性 Popover 和 Canvas 的 `editable` 输入。旧 private 字段不构成 ArkUI 状态依赖。宿主同时执行真实 Popover 方法证明 readonly→editable 后才能提交，设备实际显示由 root 验证。
- 属性 Popover 的草稿身份包含文档 ID、revision 和选择 ID；切换到另一文档的相同数字 ID 也会重置草稿。Index 提交回调再次校验模式、恢复状态、文档、revision 和当前选区，拒绝不会改变编辑 session。
- PCell 参数编辑在打开时捕获文档、revision 和当前 Cell；提交前变化则保留原几何并要求重新打开，避免修改另一个同编号 Cell。
- Instance、Array、Size、PCell 放置四处可见入口保留，统一捕获文档、revision、当前 Cell、选区、模式和恢复状态；四个 Dialog 的 `contextProvider` 与 Index 后端各自校验。前三确认回调返回 boolean，拒绝或异常保持弹窗供纠正。数字完整性校验和 Dialog 错误提示由 editing 代理完成。
- Instance 提交捕获服务拒绝并报告失败；editing 代理在实际 `EditService.createInstance` 增加锁层、有限参数、直接/间接循环和展开预算校验。旧入口在 TOP 放 TOP 可生成自引用的问题已不再放行。
- 初始恢复先验证全部候选，在 native 激活成功后再发布文档集合和标签；失败保留当前标签、记录与 session，成功移除被替换的初始空文档记录。恢复草稿 dirty、干净文档基线和切换后的状态以实际 Index/服务方法验证。

本批必要专项均通过，日志位于 `artifacts/workflow-completion-20260930/`：

| 专项 | 当前项数 | 本批日志 |
| --- | --- | --- |
| `features_editor_host_check.mjs` | 44/44 | `automation-parameter-final.log` |
| `index_workspace_host_check.mjs` | 41/41 | `automation-workspace-final.log` |
| `canvas_keyboard_host_check.mjs` | 11/11 | `automation-keyboard-final.log` |
| `shared_shape_readonly_host_check.mjs` | 10/10 | `automation-readonly-final.log` |

共 106 个套件检查项。参数拒绝矩阵在一项检查中覆盖四动作 × 六种失效上下文，不将其另计成 24 个套件检查项；成功路径使用实际 Index、AdvancedEditService、EditService 与 WorkspaceService，native 几何运输边界由 stub 提供确定结果。四套均已由原统一入口调用，无新增重复门禁。指定修改文件 `git diff --check` 通过，仅有仓库 LF/CRLF 提示。

root 设备报告小艺输入法首次启动后工程面板消失。源码只读核对未发现 `aboutToDisappear` 或 `onBackground` 主动关闭工程面板：关闭状态只由用户关闭、新建/打开/历史恢复成功设置。root 随后确认旧 uinput 点击对输入法窗口无效、改 uitest click 才能操作；环境焦点/输入法交互原因仍待查，不能据此归因为应用缺陷，也未宣称修复。对应手工复画状态记录为 `artifacts/manual-redraw-20260930/workspace-state-review.md`。
