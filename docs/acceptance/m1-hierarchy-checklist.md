# M1 验收清单：层级几何展开（对齐 KLayout hierarchy depth）

> 状态：验收模板（实现 Phase B 时填写）  
> 日期：2026-07-21  
> 关联：[差距矩阵](../roadmaps/klayout-feature-gap-matrix.md) · [恢复路线](../roadmaps/2026-07-11-native-port-recovery-roadmap.md)

## 1. 目标语义

| 行为 | KLayout 期望 | 鸿图 M1 必达 |
|------|--------------|--------------|
| `depth = 1` | 仅当前 Cell 本地几何；实例不展开子几何 | 同左；INSTANCE 可显示为轻量占位（可选） |
| `depth = 2` | 本地几何 + 直接子实例内一层几何（经变换） | **必须**把直接子 Cell 的 BOUNDARY/PATH/TEXT 变换后绘制 |
| `depth ≥ 3` | 继续递归展开 | 同左，上限与 UI 滑块一致（当前 1–5） |
| 进入子 Cell | 编辑/查看上下文变为该 Cell 本地坐标 | 双击 INSTANCE + 面包屑；显示数据切到该 Cell |
| 返回 Top | 恢复上一上下文并保持视图合理 | 面包屑返回后 fit/居中 |

**失败定义：** 仅显示 INSTANCE 框+名称、子 Cell 矩形未出现在父坐标系 → **未通过**。

---

## 2. Fixture 要求

| ID | 描述 | 建议路径 | 参考工具摘要 |
|----|------|----------|--------------|
| F-H1 | 双 Cell + 单 SREF（无旋转） | `tools/fixtures/` 或现有 `gdsii_smoke.gds` | Top 见实例；depth≥2 见子矩形 |
| F-H2 | SREF 含旋转 90/180/270 | 待补 | 与 KLayout 轮廓重合 |
| F-H3 | SREF 含 mirrorX + mag | 待补 | 与 KLayout 一致 |
| F-H4 | AREF 2×3 阵列 | 待补 | 各拷贝位置对齐（或文档声明「展开为多 SREF」） |
| F-H5 | 三层 Cell（A→B→C） | 待补 | depth=1/2/3 逐级可见 |
| F-H6 | 多 Top 候选 | 待补 | `primaryTopCellId` 合理；可切换 |

每条 fixture 应附：

- 文件名、来源、库名、Cell 列表  
- KLayout 打开截图（depth=1/2/3）或坐标级参考摘要  
- 预期 Top Cell 名 / ID  

---

## 3. 自动化

| 检查 | 命令 / 方法 | 通过标准 | 结果 |
|------|-------------|----------|------|
| GDS/OASIS smoke | `tools/run_native_smoke.ps1` | 全部 PASS | ☐ |
| **Hierarchy expand smoke** | 同上脚本中的 `hierarchy_smoke` | mag/mirror/rot 角点与期望一致 | ☐ 已加入脚本 |
| Top Cell / owner | smoke 或 unit | 与参考摘要一致 | ☐ |
| 变换展开（native） | `Layout::flattenHierarchy` + `expandHierarchy` NAPI | depth=1/2 语义正确 | ☐ 已实现 API |
| ArkTS 展开 | `HierarchyExpandService.expandCellShapes` | 画布 depth 滑块驱动展开绘制 | ☐ 已实现 |
| GPU 主路径 | `GlCanvas` ← 展开 shapes → `setRenderData` | GL 活跃时非叠加 ShapeNode 不铺全量节点 | ☐ 已实现 |
| 视口裁剪 | `cullShapesToViewport` / native batch cull | 缩放平移时批次数随视口变化 | ☐ 已实现 |
| Native batch | `expandHierarchyToBatches` | 解析后 Layout 已加载时可用；失败回退 ArkTS | ☐ 已实现 |
| 相机对齐 | `GlCanvas.updateGLCamera` + `gl_renderer.updateMVP` | 与 ShapeNode 同映射（含 Y 翻转） | ☐ 已实现 |
| HAP 构建 | `hvigorw assembleHap` | 成功 | ☐ |

---

## 4. 模拟器 / 真机手测（对照 KLayout）

环境：______（设备/模拟器） · 构建：______ · 日期：______

### 4.1 F-H1 基础层级

| 步骤 | 期望 | 通过 |
|------|------|------|
| 系统选择器打开 fixture | 无伪成功；状态栏有库/Cell 信息 | ☐ |
| Top + depth=1 | 仅本地几何；子几何不可见（或仅实例框） | ☐ |
| Top + depth=2 | 子 Cell 几何出现在实例变换后位置 | ☐ |
| 与 KLayout 同文件 depth=2 对比 | 轮廓一致（允许颜色/线型差异） | ☐ |
| 双击实例进入子 Cell | 仅子 Cell 本地几何；坐标合理 | ☐ |
| 面包屑回 Top | 恢复 Top 显示；视图重新适配 | ☐ |

### 4.2 变换（F-H2 / F-H3）

| 步骤 | 期望 | 通过 |
|------|------|------|
| 旋转实例 depth=2 | 几何旋转与 KLayout 一致 | ☐ |
| 镜像 + mag | 与 KLayout 一致 | ☐ |

### 4.3 阵列与多层（F-H4 / F-H5）

| 步骤 | 期望 | 通过 |
|------|------|------|
| AREF | 各拷贝位置正确 | ☐ |
| depth 1→2→3 | 逐级出现更深几何 | ☐ |
| depth 从 3 调回 1 | 更深几何消失，无残留错图 | ☐ |

### 4.4 稳定性

| 步骤 | 期望 | 通过 |
|------|------|------|
| 缩放/平移 连续操作 | 无崩溃、无明显错图 | ☐ |
| 切换图层显隐 | 展开几何跟随图层 | ☐ |
| 30 分钟中型文件（有则测） | 无崩溃 | ☐ |

---

## 5. 截图点（建议归档路径）

建议目录：`docs/acceptance/screenshots/m1-hierarchy/`

| 编号 | 内容 | 鸿图 | KLayout |
|------|------|------|---------|
| S1 | Top depth=1 | ☐ | ☐ |
| S2 | Top depth=2 | ☐ | ☐ |
| S3 | 子 Cell 内部 | ☐ | ☐ |
| S4 | 旋转/镜像样例 depth=2 | ☐ | ☐ |
| S5 | depth=3 三层样例 | ☐ | ☐ |

---

## 6. 已知限制（可接受的文档声明）

在验收通过时可写入 README / 路线图：

- [ ] AREF 以「展开为多个 SREF 点」实现，非原生阵列对象保留  
- [ ] PATH 线宽 / 凹多边形填充精度有限  
- [ ] 属性 PROPATTR 可能丢失  
- [ ] OASIS 仍为实验性  

---

## 7. 签核

| 角色 | 姓名 | 日期 | 结论 |
|------|------|------|------|
| 实现 | | | ☐ 通过 / ☐ 不通过 |
| 对照（KLayout） | | | ☐ 通过 / ☐ 不通过 |

**不通过时阻塞：** 不得在 README 宣称「层级显示与 KLayout 一致」或「完整 hierarchy depth」。
