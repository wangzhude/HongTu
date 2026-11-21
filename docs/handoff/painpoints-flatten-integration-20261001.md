# 单层实例展开接线（2026-10-01）

新增 `services/FlattenPreviewService.ets`，没有修改 Index 或原生 job 文件。现有 `Index.flattenInstanceList` 使用循环创建/删除；新的入口准备完整候选文档，再一次提交，用于替换选中实例与 Cell 树打平入口的实际 mutation。

## 接口与作用域

- `estimate(document, instanceIds): FlattenPreviewResult` 只计数，不分配展开几何，不写编辑服务。`estimate` 包含实例记录数、阵列成员数、新对象数、删除数、结果对象/顶点数、保留嵌套实例数和风险提示。
- `prepare(document, instanceIds)`：验证源文档，估算预算，使用真实 `instanceTransformMat` 生成一层展开结果，验证完整候选文档，返回 `preview`。仅复制目标 Cell 的本地对象；嵌套引用保留为变换合成后的实例，不递归打平。
- `apply(preview, currentDocument, currentStructure)`：比对文档 ID、编辑服务 revision、当前 Cell、nextShapeId、源和候选 fingerprint，再检查锁层与结构匹配，调用一次 `editService.applyDocumentStructure`。提交异常恢复完整 session；旧几何、undo/redo、clipboard、nextId 均回滚。成功清空选区，可一次撤回整个展开。

选中实例入口传明确的选中 INSTANCE IDs；Cell 树入口仍可按原行为收集 `shape.type===INSTANCE && shape.cellId===targetCellId` 的所有 ID，包括多个父 Cell 的引用。不要把 Cell 树 ID 列表再次按当前 Cell 限制，也不要对每个实例单独调用 apply。准备时若导航路径正经过将被删除的实例，完整文档校验会拒绝，提示先返回父/顶层后再操作；不会静默破坏实例路径。

单次新建上限 100,000，对象总数上限 1,000,000、顶点总数上限 4,000,000。计数超限在生成几何前拒绝。空 Cell 引用也会显示“只删除空引用”的风险，再由确认动作提交。新 ID 使用 `getNextShapeId()`，不复用已删除历史对象的 ID。

## Index 最小流程

1. 保留 `assertEditMode()` / `workspaceReady` 的实际入口检查，先结束当前手势事务。
2. `const document = this.workspaceDocument()`；收集明确 IDs；调用 `estimate` 展示实例数、数组成员数、输出对象数、嵌套引用与风险。大对象结果不能只提示“展开成功”。
3. `prepare(document, ids)` 成功后保存其 preview。使用已有原生确认弹窗展示例如“2 条实例记录，7 个阵列成员，新增 42 个对象；仅展开一层，保留 7 个嵌套实例”。prepare 不修改几何，取消不需要恢复。
4. 确认动作再检查编辑可用状态，并调用 `apply(preview, this.workspaceDocument(), this.cellStructureState())`。服务自身拒绝过期文档/Cell/版本、后改锁层、改过源对象或预览对象。不要调用原有循环 flatten mutation。
5. 不论成功或回滚后异常，都刷新 `syncShapesFromEditService()/readPCellVariants()/rebuildCellTree()` 以更新 UI 缓存；成功将 `selectedShapeId=-1`，保存草稿并显示实际结果数量。

源/候选 fingerprint 排除时间戳、视图位置、独立 selectedIds，但保留几何/Cell/导航/单位/精度/PCell 意图。预览期间刷新 updatedAt 不会自行使预览失效。服务不会执行脚本，也不会改变 Cell 定义数量或保存位置。

## 保真与测试

矩形展开为四点多边形；PATH 端型、绝对宽度、带符号的端扩展、TEXT presentation/文字及合成变换、NODE 类型/数据类型、嵌套 AREF 步长和属性保留。所有新输出移除 `HONGTU_PCELL_V1:` 属性，防止普通展开图形被误识别成关联 PCell；原变体 Cell 的图形/属性仍保留。

`node --experimental-transform-types tools/flatten_preview_host_check.mjs` 13 组通过：计数、旋转镜像/负步长、全部主要元数据、Cell 树跨父作用域、历史 ID、锁层、过期/直接源修改/候选篡改、事务结构不匹配、异常回滚、预算/坐标溢出、无效 ID/只读、空 Cell 一次撤销。使用真实模型、层级矩阵、Workspace 校验与 EditService 事务，平台/native query transport 隔离。已加入 `tools/check_all.sh`。

既有 EditService 重放会按其规则重新排列对象数组并选择重做创建的当前 Cell 对象；测试确认每个 ID 的几何与元数据往返，不把对象数组位置/成功后选区当成稳定存档语义。本批没有进行 HAP/设备验收。

## Workspace 外部保存补漏

`Workspace.initialize(context)` 与 `exportProject(context)` 配置 `safeFilePublishService.configureRecoveryDirectory(context.filesDir)`。`writeAllToUri` 对普通路径和 provider URI 全部走真实 Safe.publishBuffer。`atomicWrite` 的内部 `.pending` 改用 private `writeOwnedText`，内部文件更新保留既有完整写入/flush/rename 语义。工作流代理负责真实 Safe 平台 fixture 与 ComponentLibrary 普通路径导出故障验证；其结果以根会话最终门禁为准。
