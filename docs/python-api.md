# 鸿图 Python 版图 API 与电脑伴随服务

## 实现位置与边界

本轮使用 **CPython 3.11 + 官方 `klayout.db 0.30.12`**。`import hongtu as db`
直接重导出 KLayout 的真实 Python 数据库类，不把 JSON 命令或宏语言称为 Python。
可用 `Layout`、`Cell`、`Box`、`Polygon`、`Path`、`Region`、`Trans`、
`CellInstArray` 及完整 `klayout.db` API。可信脚本支持 GDS/OASIS 读取、写出、
层级单元、阵列、变换、孔洞及布尔运算。

执行器当前位于 **Windows 电脑**，通过 HDC 连接 HarmonyOS 电脑模拟器；
没有把 CPython 或 KLayout 嵌入 HarmonyOS 应用。应用生成/编辑 Python 后请求
本机服务，收到完整 GDS 和独立 SVG 预览，再由用户选择载入。仅生成预览不会修改
当前 native 版图文档。设备断开后需恢复 HDC 转发；电脑端服务需持续运行。

## 安装与启动

在 `D:\HongTu\hongtu` 中执行（只安装到仓库局部虚拟环境）：

```powershell
py -3.11 -m venv python/.venv
./python/.venv/Scripts/python.exe -m pip install --index-url https://pypi.org/simple -r python/requirements.txt
./python/.venv/Scripts/python.exe -m pip install --no-deps -e ./python
./python/.venv/Scripts/python.exe -m pip check
./python/.venv/Scripts/python.exe -c "import hongtu.assistant; print('Agent dependencies import successfully')"
./tools/start_python_bridge.ps1
```

`requirements.txt` 与 `pyproject.toml` 的四项运行依赖一致，包括 KLayout、Pydantic AI Harness、
带 OpenAI/AG-UI extras 的 Pydantic AI SDK 和 AG-UI 协议。必须先完成完整依赖安装，
再执行 `--no-deps` 的本地项目安装；只安装 KLayout 能运行普通 Python 几何生成，不能运行 Agent。
启动前以实际隔离解释器检查依赖；缺少 Agent SDK 会明确提示，普通几何服务仍可使用。
`/health` 只在固定版本实际检测且入口可导入时声明 `assistant-ag-ui`；这不证明模型在线或工具任务成功。
Agent 或 artifact 请求遇到缺失/不兼容依赖时返回可恢复的 503，按以上步骤修复依赖并重启服务。

脚本默认选择唯一连接的 `2in1` 电脑模拟器，并建立 `rport tcp:7865 tcp:7865`。
可用 `-Target 127.0.0.1:5555` 指定；`-SkipForward` 只启动电脑服务。
`-Restart` / `-Stop` 先核对绝对可执行文件、完整命令、PID 和创建时间；
不会批量终止 Python 进程。启动窗口隐藏。服务只监听 `127.0.0.1:7865`。

本机凭据在 `%LOCALAPPDATA%\HongTu\python-bridge\config.json`：

```json
{
  "endpoint": "http://127.0.0.1:7865",
  "port": 7865,
  "token": "随机生成的本机令牌"
}
```

首次启动生成随机令牌；文件 ACL 限定当前用户和 SYSTEM。实际令牌不写源码、
命令行、日志、测试报告或 Git。日志在同一用户目录，仅记录服务启动。

## 真正的 Python 示例

```python
import hongtu as db

layout = db.Layout()
layout.dbu = 0.001  # 单位为 µm；整数坐标一格 = 1 nm
top = layout.create_cell("TOP")
unit = layout.create_cell("UNIT")
metal = layout.layer(1, 0)
unit.shapes(metal).insert(db.Box(0, 0, 1000, 500))
top.insert(db.CellInstArray(unit.cell_index(), db.Trans(),
                           db.Vector(2000, 0), db.Vector(0, 1500), 4, 3))
```

`Box/Point/Path` 使用整数 DBU；`DBox/DPoint/DPath` 使用 µm。转换应通过
KLayout 的 `to_itype/to_dtype` 或 `D*` API 明确完成。几何坐标保留输入的 x/y；
当前鸿图与 SVG 预览均按 y 向下显示，不在写 GDS 时额外镜像几何。

### 稳定端口 API（`ports-v1`）

受限 Python 脚本可以创建和编辑真实 Cell 端口；`GET /health` 的能力列表包含
`ports-v1`。以下代码只创建端口定义，仍是有效版图输出：

```python
import hongtu as db
layout = db.Layout()
layout.dbu = 0.001
cell = layout.create_cell("PORT_ONLY")
port = db.add_port(cell, "in", (123, -456), 500, 37, 7, 3,
                   frame_mirror=True, frame_magnification=1.2,
                   info={"purpose": "input", "nested": [1, True]})
db.update_port(cell, port["id"], {"centerNm": {"x": 200, "y": -456}})
print(db.get_ports(cell))
```

`add_port(cell, name, center_nm, width_nm, orientation_deg, layer_number,
datatype=0, port_type='optical', frame_mirror=False, frame_magnification=1.0,
info=None)` 使用 nm 位置和本征宽度、度方向。有效宽度由本征宽度乘完整 frame
倍率得到；调用者不能预先把倍率乘入 `width_nm`。任意有限方向和镜像均保留。
`get_ports(cell)` 返回独立副本，包含稳定 `id/ownerCellKey`、完整 frame、
`crossSectionKey/version`、`infoJson/provenance`。

`update_port(cell, id, changes)` 接受 `name/centerNm/orientationDeg/widthNm/
layerNumber/datatype/portType/frameMirror/frameMagnification/infoJson/provenance`，
身份和归属不可修改；`infoJson/provenance` 须为 JSON 对象字符串。修改共享的已知
对称 CrossSection 的 width/layer 时生成独立描述符，不改变其他端口。非对称或未知
描述符的改宽操作明确拒绝，避免留下陈旧定义。`remove_port(cell, id)` 删除定义；
被外部 KFactory pin 引用的端口要求显式 pin 事务，当前直接删除会失败。

普通几何生成依赖 `klayout.db 0.30.12`；Agent 另需上述固定 SDK 依赖，不安装 gdsfactory/kfactory。输出同时保存
HongTu 的三个 versioned META 载体及已支持的 KFactory v3 端口/截面格式；互通测试
固定使用独立环境的 **gdsfactory 9.51.0 / kfactory 3.0.4 / KLayout 0.30.12**。
真实 GDS/OASIS context 与普通 GDS 属性是两条独立存储链；普通属性保真不能代替
端口支持。未知外部版本保留原 context 并返回能力诊断，不把它解释成已支持端口。

端口总数上限 100000，CrossSection 4096，单个 `infoJson/provenance` 64 KiB、
描述符 256 KiB；JSON 对象含有限数值，拒绝 `__proto__/constructor/prototype` 键
及非 JSON 的原生 typed 对象。Python 的完整 GDS 与端口 sidecar 各受 8 MiB 限制，
完整返回包受 14 MiB 限制；截面宽度及 enclosure 数值须能精确表示为当前 DBU。
每个独立 `infoJson/provenance/definitionJson` 最多 8192 个 JSON value nodes：
对象、数组、标量、null 各计一个，字典键不计；这与工作台模型和 native reader 一致。
JSON root 深度按 0 计：`infoJson` 最大 31，以便外层 KF port wrapper 能在深度 32
内导出；`provenance/definitionJson` 最大 32。同 owner 的真实 foreign provenance
可保留深度 32；其他 provenance 若转换后放入 `previous` 导致超限，更新入口就会拒绝。
单个 owned inner JSON 和单个生成 known TL Variant 各限制 300000 value nodes、
深度 32；字节/节点/深度同时满足才可发布，100000 的文档总量不保证单 Cell 全部可编码。
任一验证或预算失败不会发布成功 artifact。工作台载入时以真实原生读回内容为准，
逐 Cell 身份、端口/截面以及 context 字节与归属核对 sidecar。

该 API 保存端口定义和实例投影所需的数据；它不代表自动布线、完整网络提取、
电气连接或工艺签核已经完成。专项证据见
[端口契约](validation/closure8-20261002/ports-contract.md)。

自有例子在 `python/examples/`：层级阵列、孔洞布尔、变长 PATH 互连、光子晶体
三角晶格和梳齿。它们是几何例子，不代表满足某个制造工艺。

### 可信本地 CLI：完整 API

```powershell
./python/.venv/Scripts/python.exe -m hongtu.cli python/examples/hierarchy_array.py --output python/generated/array.gds
./python/.venv/Scripts/python.exe -m hongtu.cli python/examples/region_holes.py --output python/generated/holes.oas
```

CLI 执行用户信任的完整 Python 文件，可使用 `layout.read(...)`、
`layout.write(...)`、其他 Python 库和文件操作。`--output` 为可选便捷入口，
要求最终全局变量 `layout` 是 `Layout`。这是普通本地代码执行权限。

### AI/界面脚本：有限 API 与资源控制

HTTP 路径接受受限几何与端口生成脚本，最终全局变量必须为 `layout`。服务负责写出
固定临时 GDS 并删除临时目录；脚本不能指定输出路径。

- 可导入 `hongtu`、`klayout.db`、受限 `math`；支持 `for/range`、`if`、普通
  `def/return`、列表/字典/生成式、计算、布尔 Region 运算与显式几何方法。
- 禁止 `os/subprocess/socket/pathlib`、`open/read/write`、`eval/exec`、动态
  导入、私有属性、装饰器、`while` 等。精确清单见 `python/hongtu/policy.py`。
- 每次执行独立进程；Windows Job 限制 768 MiB、10 秒 CPU，父进程限制
  15 秒墙钟。限制生成脚本 64 KiB、GDS 8 MiB、2000 Cell、256 层、32 层级、
  20 万展开图形。超限失败，不将被截断布局当成功文件返回。
- SVG 最多呈现 3000 个展开图形或约 1.5 MB 字符；超限明确设置
  `previewTruncated=true`。**完整 GDS 不截断**。多个顶层 Cell 时预览首个，
  标为截断；完整文件仍保留全部顶层。

AST 白名单、令牌和资源上限是纵深防护，**不是强 OS 安全沙箱**。原生扩展与
CPython 在本机用户权限下运行；不可将该服务开放到公网或承诺安全执行任意不可信
Python。浏览器 Origin 请求被拒绝，没有文件读取或 shell HTTP 端点。

## HTTP 契约

`GET /health` 可匿名读取，返回引擎/版本、执行位置、上限、进程 PID；不返回凭据。
如果请求带有 Authorization，则仍校验令牌，错误令牌返回 401。

`POST /v1/generate`：`Authorization: Bearer <本机令牌>`，JSON 请求：

```json
{"script":"import hongtu as db\nlayout = db.Layout()\n..."}
```

成功响应：

```json
{
  "success": true,
  "fileName": "python-generated.gds",
  "gdsBase64": "完整GDS的base64",
  "cellCount": 2,
  "shapeCount": 2,
  "layerCount": 1,
  "expandedShapeCount": 26,
  "stdout": "脚本输出，最多16000字符",
  "previewSvg": "<svg ...>...</svg>",
  "previewTruncated": false,
  "engine": "CPython + klayout.db",
  "engineVersion": "0.30.12"
}
```

`shapeCount` 是各 Cell 中存储的原始形状数，`expandedShapeCount` 是顶层展开
估计数，实例本身不计为可绘制图形。失败返回 `{"success":false,"error":"..."}`；
401 未认证，413 请求过大，429 已有任务运行。错误不返回 traceback 或环境变量。

## 已完成验证

```powershell
./python/.venv/Scripts/python.exe -m unittest discover -s python/tests -v
./python/.venv/Scripts/python.exe python/verify_sky130_subset.py
./python/.venv/Scripts/python.exe python/verify_klayout_lvs.py
```

2026-09-30 本机结果：

| 范围 | 结果 |
|---|---|
| 独立 worker / 认证 HTTP / API 契约 | 8 项 unittest 通过 |
| 5 个自有几何脚本 | 全部真实执行，GDS 重读；GDS→OASIS→重读，逐层 Region XOR 为空 |
| 资源与文件控制 | 非白名单 import/read/write 拒绝；过大阵列拒绝；长任务终止；预览截断单独标识 |
| 真实公开 GDS | SKY130 inv: 1 Cell / 22 层 / 54 图形；NAND2: 1 / 22 / 58；KLayout ringo: 9 / 13 / 146 |
| SKY130 met1 子集 | 合规例 0 项；故意缩窄/缩间距/缩面积分别触发对应 1 项；两个官方单元该三条子集均为 0 项 |
| KLayout 官方 inverter LVS | 实际 MOS4 提取 PMOS+NMOS，与官方参考网表匹配；故意改连线后的网表被拒绝 |

### API24 2in1 设备流程与独立读回

2026-09-30 在真实运行应用的 MateBook 2in1、API24 x86_64 模拟器完成以下操作。
Python 仍在电脑伴随服务中执行；随后用官方 KLayout 独立读取设备保存产物。

| 设备操作 | 独立验证 |
|---|---|
| 实际 DeepSeek 生成 12×12 光子晶体阵列 Python → 执行 → SVG 预览 → 载入 → 保存；将阵列 X 改为 120 nm 后再保存、picker 重开 | 2 Cell、12×12 AREF 与步进保留；相对预期 `(120,0)` nm 平移结果的 Region XOR 面积为 0 |
| 打开官方 SKY130 inverter，应用标准 LYP；67/44 与 67/20 分别显隐/锁定；设备导出 LYP | 54 图形、22 个 layer/datatype；KLayout 读回 22 对的名称、frame/fill 颜色、宽度与可见性符合预期，67/44 隐藏而 67/20 可见 |
| 设备上两方形相减得环，保存重开；再将整个环侵蚀 -100 nm，保存重开 | 面积分别为 3,000,000 与 1,800,000 nm²，均为 1 孔；两份结果各自与 KLayout 预期 XOR=0 |

这些是指定样本/操作的设备验收。记录为
`artifacts/industrial-foundation-20260930/ai-ui-roundtrip.json`、
`device-lyp-report.json`、`device-geometry-roundtrip.json`，流程与截图入口见
[本轮统一报告](validation/industrial-foundation-20260930.md)。
它们不代表 API26/arm64 真机、任意层级/样式组合、大版图性能或完整工业签核已通过。

### SKY130 公开规则的范围

`verify_sky130_subset.py` 使用真实 `Region.width_check/space_check` 及合并多边形
面积，只检查 **met1 drawing = 68/20**：m1.1 宽度 ≥0.140 µm、m1.2 间距
≥0.140 µm、m1.6 面积 ≥0.083 µm²。阈值来源为 [SKY130 Periphery Rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html#m1)，
层映射来源为 [Layers Reference](https://skywater-pdk.readthedocs.io/en/main/rules/layers.html)。
可导入鸿图的规则文件为 `python/rules/sky130-met1-subset.json`，长度换算为
140 nm，面积换算为 83000 nm²，精确指定 layer=68/datatype=20。文件描述保留
“公开三规则子集、非签核”。应用的该预设已接入 Clipper2 合并区域，native 的
宽度/间距/面积违例有无经过独立 KLayout 对照；API24 应用打开官方 inverter 时
该三条子集实测 0 项，与独立检查一致。这不等于所有 DRC 标记的位置、数量或
任意输入都已与 KLayout 等同；ArkTS 回退缺少合并覆盖时仍给完整性告警。
该子集没有覆盖 huge-metal 例外、包围、孔洞面积、密度、天线、其他层或器件规则；
输出明确 `foundrySignoff=false`，不能把子集零违规称为完整 SKY130 DRC 通过。

应用几何核心的 1,833 例对照是另一套测试：833 例要求精确 XOR=0，1,000 个
斜边案例按预先约定的 DBU 量化界判断；host/OHOS、核心/编辑输出分别执行。
DRC 对照的随机布局为 Manhattan 合并区域，只判断三规则违例是否存在；固定
案例会在不同种子批次重复，不能把各批次数量直接相加为互不重复的案例。
各批计数、种子、上限和未验证范围见 [几何与 DRC 详细报告](validation/geometry-20260930.md)。

### LVS 独立对照的范围

`verify_klayout_lvs.py` 将 [KLayout 官方 LVS 入门例子](https://www.klayout.de/doc-qt5/manual/lvs_intro.html)
接到真实 `LayoutToNetlist`、MOS4 提取器与 `NetlistComparer`，读取官方
`inv.oas` 与 `inv.cir`。结果为 2 器件、6 网络：PMOS L=0.25 µm/W=1.5 µm；
NMOS L≈0.25 µm/W=0.9 µm。它使用官方**演示工艺**，不冒充 SKY130 器件提取。
此独立 CLI 对照也不意味着鸿图当前 native LVS 已获得相同能力或通过生产签核。

公开样本的固定 revision、SHA-256、来源与许可证见 `python/samples/manifest.json`。
只取小样本，不下载完整 PDK。自有脚本保留源码，生成文件在
`python/generated/`（忽略的运行产物）；已保留的验证报告在
`python/verification/` 和相应 `artifacts/` 目录。

### SKY130 图层显示与标准 LYP 互通

`python/rules/sky130-public-display.lyp` 是真实 `klayout.lay` 写出的标准 LYP，
包含 29 个精确 layer/datatype 条目，覆盖这里两个官方 HD 单元各自的全部 22 层。
名称和数字来自 [SKY130 GDS Layers Information](https://skywater-pdk.readthedocs.io/en/main/rules/layers.html#gds-layers-information)，
颜色是本项目显示选择。`68/20`、`68/16`、`68/5`、`68/0` 分别独立；未能从该表
确认用途的 `236/0` 保留 `L236/0`。此配置只改显示名称和颜色，不改源 GDS 层号、
不安装 PDK、不定义额外工艺规则。

```powershell
./python/.venv/Scripts/python.exe python/build_sky130_layer_profile.py
node --experimental-transform-types --disable-warning=ExperimentalWarning tools/lyp_standard_host_check.mjs
node --experimental-transform-types --disable-warning=ExperimentalWarning tools/ai_datatype_host_check.mjs
```

标准 LYP 导入支持 `<layer-properties>/<properties>/<group-members>` 及 `layer/datatype@cellview`；
旧鸿图 XML 仍可读。导出按钮现在写标准 KLayout XML。Host 检查实际执行
`LypService.ets` 解析/序列化，并让独立 KLayout reader 读取其导出文件，验证
29 组层号、datatype、名称、frame/fill 颜色、可见性和宽度完全一致。
结果与 SHA-256 记录于 `python/verification/sky130-layer-profile-report.json` 和
`python/verification/lyp-interop-report.json`。这部分是 host 证据；本轮另已在
API24 2in1 上通过系统 picker 导入该配置，更新样本的 22 个已有图层，并验证
设备实际导出的 22 对 LYP（见上方 `device-lyp-report.json`）。完整样式/动画组合
及其他设备的验收仍未完成。

范围限制：图层组拍平为最内层组名；非当前 cellview 索引应用到当前文档并提示；
通配符/非数字 source 不会用于猜测图层；未知数值二元组保留，未匹配的文档层不动。
百分比透明度导出为布尔 transparent，自定义线型/填充图案使用默认显示；
选择锁定、VAS、动画未完整映射。`lypExportWarnings()` 与导出 XML 注释明确列出损失，
不能称为任意 LYP 显示属性的完整往返。

AI JSON 指令与 Python 提示词也保留完整 layer/datatype，支持范围为整数 0..32767，
其中 0 是精确类型。省略 datatype 时，仅当前 layer 继承当前 datatype，其他 layer
默认 0。旧本地 Demo 解析不支持用途类型，因此非零 datatype 文档须使用真实模型；
未连接时明确提示，不自动套用演示层。AI host case 执行真实 AiService/Parser 源码，
验证转换、默认值、五类创建、选择、显隐合并和锁定；编辑后端/系统 API 使用桩，
不把这些断言计为 native 或设备验证。

## 一手 API 资料

- [官方独立 Python 包](https://www.klayout.org/klayout-pypi/)
- [Layout、DBU 与整数/微米坐标](https://www.klayout.org/klayout-pypi/overview/layout/)
- [CellInstArray 与实例](https://www.klayout.org/klayout-pypi/overview/instances/)
- [Region 几何 API](https://www.klayout.de/doc-qt5/code/class_Region.html)
- [LayoutToNetlist API](https://www.klayout.de/doc-qt5/code/class_LayoutToNetlist.html)
- [固定安装版本 PyPI](https://pypi.org/project/klayout/0.30.12/)
