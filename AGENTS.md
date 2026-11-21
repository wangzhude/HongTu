# 鸿图项目开发与界面规范

修改原生界面前阅读 [docs/ui-design-system.md](docs/ui-design-system.md)，复用 `entry/src/main/ets/common/UiTokens.ets` 和主题 `COLORS`。伴随端与接口边界参考 [docs/python-api.md](docs/python-api.md) 与 [docs/ai-assistant-guide.md](docs/ai-assistant-guide.md)。

- 应用按钮明确使用 `ButtonType.Normal`，最终圆角 8vp；输入控件 8vp，分段选择外 8vp/内 6vp，悬浮面板 12vp，模态弹窗 16vp。边框不能覆盖最终圆角。系统控件与画布几何按规范中的例外处理。
- 使用固定的主操作、次操作、危险操作和文字动作角色；沿用真实禁用条件、回调和数据状态。
- 功能菜单最多两级，一级不超过 7 个入口；二级每组不超过 7 个动作、整层不超过 12 个动作。动态数据枚举使用原生选择器或可滚动列表。
- 统一间距、字号、表单与表格列对齐、顶部滚动对齐及窄窗口排布。新增 HarmonyOS 页面仍先按用户全局要求生成并检查每页视觉模板，再实现原生组件。
- 变更后运行真实有效的自动化验证命令：
  - Python 伴随端与跨端契约回归：`python -m unittest discover -s python/tests -v` 与 `python python/check_contracts.py`；
  - HarmonyOS 本地单元测试（DevEco Studio / SDK 环境）：执行 `entry/src/test/` 下的 `@ohos/hypium` 测试套件（`hvigorw test --mode module -p module=entry -p product=default`）及 `hvigorw assembleHap` 构建检查。单元测试与静态契约校验不能替代目标设备真机验证。
