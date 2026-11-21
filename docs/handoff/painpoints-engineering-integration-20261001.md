# 工程内容与依赖集成（2026-10-01）

本批扩展已有工程面板与服务，没有新增页面。Index 由根会话集成，Canvas/编辑/导出/native 文件未在本批修改。默认打开工程只校验并保留内容，不执行代码，也不覆盖全局脚本、模板或规则。

## 已实现的接口

`EngineeringProjectService.ets`：

- `buildBundle(snapshot: EngineeringProjectSnapshot): EngineeringProjectBundle`：选择允许字段，保存 Python 草稿/模板、当前 `workspaceId` 的文档宏、DRC JSON、工艺 JSON 与 PCell 意图。宏集合中的全局宏和其它文档宏在构建时排除。规则/技术复用现有纯解析器并规范化，未知服务配置字段不会进入结果。
- `validateBundle(input: EngineeringProjectBundle | string)`：版本/预算/结构和五段变更摘要校验，返回独立副本。导入时包含全局或其它文档的宏会失败。摘要算法名是 `fnv1a32-utf16-change-detection`，仅用于检测内容变化，**不是签名、认证或对抗性完整性承诺**。
- `dependencyReport(bundle, environment)`：`availablePCells: string[]` 必填；可提供 `pythonAvailable`、`klayoutAvailable`、`toolVersions`、`availableDeckIds`、`verifierAvailable`。未知版本保持空值并提示未实测。工艺实际名称/版本进入 manifest，工艺声明的 `drcDeckId/lvsDeckId` 自动登记为外部依赖。仅有同名 PCell 不证明参数定义或输出几何一致。
- `restoreTools(bundle, targetWorkspaceId)`：纯返回 `{python, macrosJson, drcDeckJson, technologyJson, sourceWorkspaceId, targetWorkspaceId}`；仅把保存的文档宏身份改为明确目标文档，不写存储、不执行代码。

`canView/canEdit` 表示经过校验的现有几何仍可继续使用。`canRegenerate` 需要 PCell/脚本运行依赖全部可用。`canVerify` 还要求调用方明确传 `verifierAvailable:true` 并已有规则且工艺/deck依赖齐备；这是重新运行的准备状态，不能展示成已检查、通过或签核。

`PythonWorkspaceService.ets`：

- `exportBundle(): PythonWorkspaceBundle`：仅草稿与模板，排除执行历史、artifact 及服务配置。草稿允许尚未完成的参数 JSON。
- `validateBundle(bundle)`：验证并克隆；模板参数/扫参必须通过原有解析方法，草稿可以继续编辑。此方法不写全局工具内容。
- `restoreBundle(bundle, restoreDraft = true): PythonBundleRestoreResult`：仅显式恢复动作调用。模板合并，同名异内容加“（工程 n）”，已有同内容导入项不会重复。容量超过 32 项整批拒绝；存储写入后回读验证，失败时尝试恢复并回读验证原模板和草稿。结果包含 `importedTemplates/draftRestored/renamedTemplates`。`restoreDraft:false` 可保留当前全局编辑草稿。不会运行脚本或动历史。

`WorkspaceService.ets`：

- `WorkspaceDocument.engineering?: EngineeringProjectBundle`。已有无该字段的工程保持兼容；`parseDocument` 使用真实 `validateBundle`。存档、版本与工程文件自然包含该可选内容。
- 打开工程会生成新的文档 ID，因此保留 bundle 原 `workspaceId` 作为来源身份；恢复按钮再重绑定宏。不要用来源 ID 自动执行宏，也不要把新目标 ID 与 bundle 来源 ID 不同当成损坏。

## Index 最小接入

明确保存工程时，构建 snapshot 并将 bundle 放入本次 `WorkspaceDocument.engineering`：

```ts
const snapshot: EngineeringProjectSnapshot = {
  workspaceId: document.id,
  python: pythonWorkspaceService.exportBundle(),
  macrosJson: macroService.exportAllMacros(),
  drcDeckJson: JSON.stringify({ name: drcService.ruleSourceText(), rules: drcService.getRules() }),
  technologyJson: technologyService.serialize(),
  pcells: document.pcells,
  toolVersions: {}
};
document.engineering = engineeringProjectService.buildBundle(snapshot);
```

这里只是接口示例，ArkTS 中给 DRC JSON 的对象使用命名 interface 和明确变量类型，避免 `JSON.stringify` 内未标注的对象字面量。`toolVersions` 只能填实际测得的版本；不要根据应用日期/依赖名猜版本。工程内的脚本/模板是当前编辑工具快照；导入后其它文档不能因自动保存而被当前全局工具内容无提示覆盖。

切换/载入文档时保留 `document.engineering`，运行 `dependencyReport` 更新面板状态；没有 bundle 时清空依赖显示并禁用恢复按钮。不要在 `openProject` 或普通标签切换中调用 `restoreBundle`、宏导入、规则加载或技术激活。

显式恢复按钮流程：

1. `restoreTools(bundle, activeWorkspaceId)` 准备 payload，并捕获文档身份/版本，防止等待期间恢复到另一标签。
2. 全部预验证：`pythonWorkspaceService.validateBundle(payload.python)`；非空 DRC 通过 `parseRuleSetText`；非空技术通过 `parseTechnologyPackage`；文档宏须匹配当前目标文档并满足 `macroService.validSteps`。空 rules 数组是保存的“无规则”状态，需要明确清空规则，不能静默回退到内置预设。
3. 通过后才调用 `restoreBundle`、导入宏和恢复规则/技术。所有执行仍由原有运行入口触发。面板明确说明当前草稿会被替换、同名旧模板保留。
4. 展示实际恢复数量、模板重命名及失败原因。依赖 manifest 的 available 不等于脚本运行成功；外部 deck 的注册不等于工艺签核资格。

## ProjectPanel props

- `engineeringDependencies: EngineeringDependency[]`
- `toolBundleAvailable: boolean`
- `restoreToolContentsAction: () => void`
- `recentEdits: string[]`（显示前八项摘要）
- `recoveryEntries: ProjectRecoveryEntry[]`，该类型 extends 真实 `FileRecoveryEntry`
- `recoverAction(entry)`：按钮“导出安全副本”，调用 `FileRecoveryService.exportBackup(context, entry, protectedTargets)`。`protectedTargets` 由 Index 收集全部打开文档的 saveUri/projectUri/sourcePath；服务拒绝原目标或任何已经存在的选中目标。原备份保留，无删除入口、无执行操作。

面板标题固定，全部内容使用同一 Scroll，避免 manifest/安全副本/版本同时出现时布局溢出。设备上的排版和滚动还需根会话使用目标构建验证。

## 宿主证据

- `node --experimental-transform-types tools/engineering_project_bundle_host_check.mjs`：12 组通过。包括允许字段、当前文档宏、未完成草稿、内容变化、缺依赖、真实 schema、显式模板合并/重名/重复恢复、容量失败、存储失败回滚、Workspace 兼容/回读。
- `node --experimental-transform-types tools/python_panel_workflow_host_check.mjs`：13 组通过，包含既有流程、任务取消与完成竞争、存储失败及历史失败产物保护；AppStorage stub 与 SDK 一致，写入接口返回 void。
- `node --experimental-transform-types tools/workspace_recovery_host_check.mjs`：25 组通过。
- 本批没有进行 HAP 全量构建、安装或设备验收，没有提交。
