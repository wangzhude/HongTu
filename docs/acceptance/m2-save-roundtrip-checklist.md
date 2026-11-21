# M2 验收清单：结构化保存与往返（open → save → reopen）

> 状态：实现切片验收模板  
> 日期：2026-07-21  
> 关联：[差距矩阵](../roadmaps/klayout-feature-gap-matrix.md) · [恢复路线](../roadmaps/2026-07-11-native-port-recovery-roadmap.md)

## 1. 目标语义

| 行为 | KLayout 期望 | 鸿图 M2 必达 |
|------|--------------|--------------|
| 按 Cell 结构写出 | 每个 STR 仅含本 Cell 本地几何 + SREF/AREF | **必须**按 `ownerCellId` 分组；禁止把全库图形塞进 Top |
| 子 Cell 几何 | 保留在被引用 Cell 内 | 导入后 `advEditService` Cell 表同步；导出用 live shapes |
| 实例变换 | STRANS/MAG/ANGLE/XY 写回 | 已有 `writeInstance`（mirror/rot/mag） |
| UNITS | 与源文件一致 | 导入同步 `docUserUnits` / `docPhysicalUnits` 并写回 |
| Dirty | 编辑后标脏；保存后清脏 | `editService.isDirty` + 状态栏/标题 `*` |
| 重开比对 | 结构摘要一致 | 同文件 reopen：cell 数、Top、SREF 目标、子 BOUNDARY 归属正确 |

**失败定义：** 导出后 KLayout/鸿图重开时，子 Cell 矩形出现在 Top 本地坐标系且无 SREF → **未通过**。

---

## 2. 实现落点

| 组件 | 路径 | 说明 |
|------|------|------|
| 结构化写出 | `LayoutExportService.buildStructuredByOwner` | `cellNames` + `ownerCellId` |
| 兼容路径 | `buildLegacyFlatTop` | 无 `cellNames` 时（空白手绘） |
| Cell 表同步 | `AdvancedEditService.loadCellsFromImport` | `applyParsedResult` 调用 |
| Dirty | `EditService.pushUndo` → dirty；`markClean` 保存后 | UI：`documentDirty` |
| 导出入口 | `Index.saveCurrentLayout` | 传 `cellNames` / `topCellId` / units |

---

## 3. 手测步骤（设备 / 模拟器）

环境：______ · 构建：______ · 日期：______

### 3.1 双 Cell + SREF（`gdsii_smoke.gds` 或等价）

| 步骤 | 期望 | 通过 |
|------|------|------|
| 打开 fixture | Top 见 INSTANCE；depth≥2 见子几何 | ☐ |
| 不编辑直接导出 | 警告含「按 ownerCell 结构化写出 N 个 Cell」 | ☐ |
| 用鸿图重开导出文件 | cellCount≥2；Top 仅有 SREF；CHILD 有 BOUNDARY | ☐ |
| KLayout 打开导出文件 | 层级与源一致（允许 AREF 已拆 SREF） | ☐ |

### 3.2 编辑后 Dirty

| 步骤 | 期望 | 通过 |
|------|------|------|
| 移动/新建一个图形 | 标题文件名带 `*`；状态栏「● 未保存」 | ☐ |
| 保存成功 | `*` 消失；toast「保存成功」 | ☐ |
| 进入子 Cell 新建矩形后保存 | 新矩形出现在该 Cell 的 STR，不在 Top | ☐ |

### 3.3 单位

| 步骤 | 期望 | 通过 |
|------|------|------|
| 源文件非默认 UNITS（若有） | 导出 UNITS 与导入 `userUnits/physicalUnits` 一致 | ☐ |

---

## 4. 自动化（host）

| 检查 | 命令 | 通过标准 | 结果 |
|------|------|----------|------|
| Native roundtrip | `tools/run_native_smoke.ps1` 中 `roundtrip_smoke` | parse→`WriteGdsii`→reparse：TOP 有 SREF+PATH，CHILD 持有 BOUNDARY，变换保留 | ☐ 已接入脚本 |
| GDS/OASIS/hierarchy | 同上脚本其余 smoke | 全部 PASS | ☐ |

实现：`entry/src/main/cpp/gdsii_writer.{h,cpp}` · `tools/roundtrip_smoke.cpp`

## 5. 已知限制（可文档声明）

- [ ] AREF 读入时已拆为多 SREF，写出不再合并为 AREF  
- [ ] PROPATTR / 文本样式 / 路径端点类型可能丢失  
- [x] 写出真源：`editService` shapes + ownerCellId（dirty 走 `writeGdsiiDocument`）  
- [x] Host 自动化往返：`roundtrip_smoke`（native writer）  
- [x] NAPI `writeGdsii` / `writeGdsiiDocument` + 失败回退 ArkTS  
- [x] writeGdsiiDocument 仅写出成功后 commit `g_layout`  
- [x] `editDepth` 与 undo 栈丢弃对齐  
- [x] 未保存确认：打开/最近文件两轮（取消 / 丢弃 / 保存并继续）；返回键丢弃后需再按一次  
- [x] 保存 `skippedShapes` 强提示  
- [x] 导出拷贝：copyFile + 1MiB 分块  
- [x] ArkTS 回退写出：1MiB 分块 writeSync  
- [ ] Ability 进程被杀无法确认（系统限制）

---

## 6. 签核

| 角色 | 姓名 | 日期 | 结论 |
|------|------|------|------|
| 实现 | | | ☐ 通过 / ☐ 不通过 |
| 对照（KLayout） | | | ☐ 通过 / ☐ 不通过 |

**不通过时阻塞：** 不得在 README 宣称「无损 GDS 保存」或「往返与 KLayout 一致」。
