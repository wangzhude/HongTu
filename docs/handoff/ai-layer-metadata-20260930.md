# AI Python 图层元数据交接（2026-09-30）

## 最终接口

`PythonBridgeService.ets` 导出：

```ts
export interface PythonLayerDefinition {
  layerNumber: number;
  datatype: number;
  name: string;
}
// PythonLayoutArtifact 中新增：
layerDefinitions?: PythonLayerDefinition[];
```

`generate(script, context, options)`、`cancelGeneration()`、输入模式和现有 Python 面板的手动预览/载入行为不变。新 worker 的每次成功响应都显式返回 `layerDefinitions`，包含没有图形的已定义图层。`layerCount` 包含这些空层并必须等于数组长度。Artifact 字段可选仅用于兼容旧运行历史；新 Bridge 响应缺少定义会明确拒绝并提示更新伴随服务。

最终限制：1–256 个定义；layer/datatype 为 **0–32767** 的整数，与 `WorkspaceService` 现有图形/图层校验及 native int16 图层键一致。名称允许空字符串，最多 256 UTF-8 字节，禁止 C0/C1 控制字符；拒绝重复 layer/datatype。早期拟议 65535 上限已撤回，不应据此放宽 Index/Workspace。Bridge 在写生成文件前校验并独立复制定义。现有 `PythonWorkspaceService.record/history` 会将整个 Artifact 序列化，已实际验证新元数据保留与旧历史缺字段兼容。

Index 由 automation 代理接线：解析 GDS 几何后，以这些定义补齐空层并应用非空名称，保留已有层样式。GDS 本身不承载这份命名/空层信息，不能从 GDS 几何反推。聊天自动生成/执行/新文档入口由 root/automation 负责，本交接不声明该设备流程已通过。

## 修改范围

- `python/hongtu/worker.py`：生成独立 layerDefinitions，严格校验后与 GDS 一起返回。
- `entry/src/main/ets/services/PythonBridgeService.ets`：新接口、响应校验、独立 Artifact 元数据。
- `python/tests/test_bridge.py`：新增 4 个实际 Python/KLayout 测试，纳入已有 GeneratedLayouts 门禁组。
- `tools/python_layer_metadata_host_check.mjs`：8 项实际 Bridge 响应/历史序列化回归。
- `tools/check_all.sh`：仅新增上述宿主测试的一行入口。

没有改 Index、PythonLayoutPanel、PythonWorkspaceService、AiService 或生产服务启动配置，没有打印/读取用户 API 凭据，没有修改官方参照或把参照导入应用。

## 验证

证据目录 `artifacts/ai-inverter-20260930/`：

- `python-layer-metadata-host.log`：8/8，包括命名/空层、缺字段、类型/数值/UTF-8/控制字符、重复项、数量、旧历史兼容；HTTP/文件传输由受控宿主适配器提供。
- `python-layer-metadata-bounds-final.log`：实际 worker 4/4，包含 32767 成功与 32768 拒绝、命名/空层、重复项和预算。
- `python-panel-compatibility.log`：已有面板 7/7。
- `python-cleanup-compatibility.log`：输入快照清理 9/9。
- `python-layer-metadata-regression.log`：最终 32767 限额下，GeneratedLayouts + WorkspaceExecution + VerificationTests 完整 Python 组 **27/27 通过（26.467 秒）**；临时 HTTP 测试自有随机端口/测试配置，不使用生产凭据。

## 常驻服务与生效范围

只读健康请求确认本机 7865 当前为 `ok=true`、bridge 0.2.0、CPython + KLayout 0.30.12。本代理未重启或停止服务。

磁盘 `bridge.py:86` 每次生成均创建新的 `base Python -I worker.py` 进程；`:98` 直接读取并返回 worker result.json，不过滤返回字段。因此使用此同路径实现的父服务下一次请求应读取新 worker 文件，理论上无需仅为本字段重启父进程。但源码/health 不足以证明当前常驻进程身份和本次真实请求已使用新结果；root 应通过其 owned 进程核对及实际 AI 请求确认，不将宿主回归或源码推断当成设备已验收。
