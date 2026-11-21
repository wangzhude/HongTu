# 新功能验证路径 — 2026-09-30

此文档提供设备验收路径，不把宿主测试或编译成功写成设备交互已通过。设备与 HAP 必须由 root 记录本轮实际值。

## 本轮已验证

- `tools/check_all.sh` 当前纳入 13 个 Node 宿主套件。首批 9 套 163 项通过；后续工作区 Index、工程面板上下文、工程文件、Python 输入清理 4 套共 29 项通过。相关自动化/保存套件已随清理改动复跑；原有套件不重复执行。
- Python：`test_bridge.GeneratedLayouts` 5 项、`test_workspace` 6 项、`test_verification` 6 项，共 17 项通过。使用真实 CPython/KLayout 子进程；HTTP 测试自行创建临时 loopback 服务，不占用 7865、不读取用户 token。
- `bash -n tools/check_all.sh` 与该文件的 `git diff --check` 通过。未在本代理运行 native/HAP 全量构建或设备验收。
- 新统一入口要求 `python/.venv` 已安装 `python/requirements.txt` 与项目包；也可用 `HONGTU_TEST_PYTHON` 指定完整解释器路径。缺依赖直接失败，不静默跳过。旧 `test_bridge.HttpContract` 依赖用户常驻服务，因此不纳入无外部状态的统一门禁；临时 HTTP 套件覆盖 generate/verify 与鉴权边界。
- 后续增加 Index AI 原子批处理 6 项与宏文档归属 7 项；统一入口现为 15 个 Node 套件。宏归属改动后自动化工作区 7 项和图层访问 29 项复跑通过；以上均为宿主证据，不代表设备路径已验收。

## Python 服务归属与启动

本次只读检查时，Get-NetTCPConnection、netstat、CIM 均未发现 7865 listener 或 HongTu bridge 进程，`/health` 连接失败。旧记录 PID `38312` 已不存在，不能用它推断当前服务仍在运行。

| 项目 | 核实路径或值 |
| --- | --- |
| 启动器 | `D:\HongTu\hongtu\tools\start_python_bridge.ps1` |
| 解释器 | `C:\Users\28384\AppData\Local\Programs\Python\Python311\python.exe` |
| 精确启动参数 | `-I "D:\HongTu\hongtu\python\bridge_entry.py"` |
| 工作目录 | `D:\HongTu\hongtu` |
| 配置 | `C:\Users\28384\AppData\Local\HongTu\python-bridge\config.json`，存在，未读取/输出 token |
| 进程记录 | 同目录 `process.json`，旧记录创建时间 `2026-09-29T17:16:05.277434Z` |
| 日志 | 同目录 `service.log`、`service-error.log` |

由 root 在准备好后执行；本代理未执行启动/停止/重启。启动器按 PID、解释器、完整命令行、创建时间同时匹配归属；发现端口被其他进程占用会拒绝，不批量终止 Python。

```powershell
# 只启动电脑服务；-Restart 也能安全处理当前已失效的进程记录。
& 'C:\Users\28384\AppData\Local\Programs\PowerShell\7\pwsh.exe' -NoProfile -File 'D:\HongTu\hongtu\tools\start_python_bridge.ps1' -Restart -SkipForward

# 先用本轮实际 hdc list targets 核实目标。仅当 5555 仍为已连接 2in1 时使用：
& 'C:\Users\28384\AppData\Local\Programs\PowerShell\7\pwsh.exe' -NoProfile -File 'D:\HongTu\hongtu\tools\start_python_bridge.ps1' -Target '127.0.0.1:5555'

# 此接口不含凭据，检查 version=0.2.0 和当前 PID。
Invoke-RestMethod 'http://127.0.0.1:7865/health' | Select-Object ok,service,version,pid,engineVersion,capabilities
```

预期 capabilities 含 `generation/document-input/selection-input/parameters/registered-verification`。界面已有令牌通过原有设置复用；若需导入配置，不把 token 复制进聊天、截图、命令行或仓库。`/v1/verify` 请求体上限 46 MiB，支持 32 MiB GDS 编码和 2 MiB 参考网表；生成接口维持较小预算。

## 设备验收顺序

每条保留入口截图、关键结果截图和实际保存文件；失败场景同时观察原版图是否保留。先完成 1–4，再做依赖外部服务/模型的 5–8。

### 1. 菜单可发现性与新建

桌面、紧凑、旧标题栏都打开「更多功能」，确认新建、另存为、工程与历史、搜索、个人器件库、比较、工艺管理、工艺 DRC/LVS 可达；数据模块也可打开文件相关菜单。

「新建版图」进入工程面板，输入 `TEST_A/TOP_A/DBU 1 nm` 后新建；再建 `TEST_B/TOP_B/DBU 5 nm`。两标签标题、单位各自独立。非法/空名称或非正 DBU 应显示错误且不增加标签。

### 2. 工作区、撤销、草稿与版本

在 A 画不同层/dtype 的两图形，改一处属性、放标尺、隐藏一层、进入子 Cell；在 B 画一个图形。反复切换，确认几何、选区、Cell 栈、单位、视图、图层和撤销历史不串文档。A 撤销不能改变 B。

等待状态显示草稿已保存，再重启应用；两个标签与未保存修改恢复。先在测试工程完成此项，不以线上用户文档做强制退出实验。创建版本、继续修改、恢复版本：旧版本应打开为新副本，现用文档保留。关闭脏标签选择取消应保留；保存失败或取消文件选择后不能关闭。

### 3. 保存与当前编辑态

在 A 保存 GDS，再修改后普通保存：复用同一 URI；另存为重新选择路径。独立重新导入文件核对几何、dtype、PATH 宽度/端点和层级属性。取消选择、不可写目标应保持脏标识。

在系统保存窗口停留期间，如平台允许，切换文档或继续编辑；保存完成不能把新文档标清或把新 URI 挂给它。对应并发逻辑已由 Index 实际方法 6 项宿主测试覆盖，设备不允许跨模态交互时记录为不可触发，不伪造结果。

保存 `.hongtu` 工程后重新打开，检查 PCell 参数、Cell 空节点、工艺、图层、标尺与视图。新导入 GDS 不应继承另一个文档的工艺/旧验证结果/标尺。

### 4. 搜索、器件库与 PCell

「搜索与筛选」按 Cell、shape type、layer/datatype、文本/属性筛选；同层不同 dtype 应可分开；结果定位和多选只作用当前 Cell，锁定/不可选图层不能绕过访问控制。

把含子 Cell/压缩阵列的单元收藏到器件库，切换 B 后按坐标放置：子依赖、变换和属性保留，一次撤销移除整次放置。导入/导出库后重启再核对。非法库文件不能留下部分条目。

放置 PCell，打开「修改参数」，参数更改应更新该变体的所有引用；一次撤销恢复几何与原参数。原生参数弹窗不出现双层壳，输入按键不触发画布快捷键。库名称过长与窄屏不挤掉放置/删除按钮。

### 5. Python 当前文档、选区、模板和扫参

入口「AI 助手 → Python 版图」。先测试连接，确认运行桥为 0.2.0。选择「当前文档副本」，参数 JSON `{"dx":100}`，执行：

```python
import hongtu as db
current_cell.transform(db.Trans(params['dx'], 0))
print(source_layout.dbu)
```

只运行/预览时原画布不变；DBU 沿用原文档。载入后几何平移 100 DBU（DBU=5 nm 时为 500 nm），层级与 dtype 保留。运行后更改原文档或切换标签，再载入旧结果应拒绝并要求重新运行，不覆盖新文档。

选择两个图形，范围换「当前选区副本」，同一脚本运行并「合并到当前版图」：原对象保留，仅插入结果及必需子 Cell；一次撤销恢复。锁定目标层时合并应整体失败，不留下部分新图形。

保存个人模板、关闭重开，确认脚本/范围/参数一致。扫参 `dx=[10,20,30]` 应产生 3 个各自基于原快照的历史结果，不累计平移 10→30→60。历史失败保留原因；切换模板/输入后旧预览不能误载。

把末尾改为 `x=1/0` 或请求 `import os`，应显示失败，源文档/文件不变。取消运行后不能出现迟到的预览自动应用；无需停止其他进程来测试取消。

每次扫参结束、失败、取消或面板关闭后，本次 `cacheDir/python-input-{date}-{serial}.gds` 与 `python-selection-...gds` 应删除；一轮扫参中间不能提前删除。验证面板同样在 finally 清理输入。只删除直接位于应用缓存目录、完全匹配受控文件名的两类文件，生成输出/历史结果保持可载入。快照提供者在返回前失败时需自行清理已经创建的文件。

### 6. 宏管理

「更多功能 → 宏面板 → 管理」：录制至少两步，重命名、改顺序/参数、删除一步，保存后重启确认保留。内置宏只能另存副本后编辑。导出 JSON、删除自定义宏并导回，步骤一致。

集合里放一条格式非法步骤再导入，应整体拒绝；有效前缀条目也不能泄漏进列表。原编辑图层锁定时拒绝操作。

在 A 录制「创建矩形 → 移动已有图形」，录制中切到 B：录制应结束并保存 A 的宏，B 的后续编辑不进入它。在 B 播放应提示来源不符且连前面的创建步骤也不执行；回到 A 播放可执行。导出后核对 JSON 的 `originDocumentId`，另存副本与重新导入应保留；手动删除该字段后导入的固定 ID 宏只能拒绝播放，不能修改恰好同 ID 的图形。仅创建矩形/多边形/路径/文字的宏应可在 B 正常播放。创建实例的宏依赖 Cell ID，也应执行同样的来源检查。

### 7. AI 有证据定位、预览、应用与复检

此项需要真实配置的模型；无模型时记录限制，不能把本地固定文本判为 AI 完成。先让当前文档出现一个可定位 DRC 问题，选中相关图形并请求「按当前 Cell 中的 shape ID 定位问题，提出修改并预览」。检查上下文实际含 Cell 层级、selectedShapes、带坐标问题与网络信息；未运行的检查不能当作已验证事实。

方案待确认期间画布源数据保持不变。先取消，再生成并应用，一次撤销可恢复。换文档、进入另一 Cell、改选区或编辑后应用旧方案，应被门禁拦截。shapeIds 指向其他 Cell 或不存在对象应拒绝。应用后重新 DRC，问题数与位置必须来自新版本结果；网络结果同样在修改后失效并需重算。

### 8. 工艺 DRC、器件 LVS 和版图比较

新建 DBU=1 nm 文档；工艺管理选择「SKY130 M1 子集 → 应用到当前文档」，在 L68/D20 放 100×1000 nm 矩形。「工艺 DRC/LVS → DRC → 运行当前文档验证」应出现真实违例，点定位落到相应包围盒；将宽改为 1000 nm 后重跑应通过所选三条规则。保存报告需包含 engine、scope、输入哈希与 `foundrySignoff:false`。

导入 `python/samples/klayout-inv.oas`，绑定「MOS4 演示」，器件 LVS 载入同目录 `klayout-inv.cir`：相符网表通过；只改参考网表器件连接后失败。不能用普通网络连通统计冒充器件 LVS。空参考、未注册 deck、不匹配工艺应明确失败；验证期间编辑/切换文档后迟到结果不应用。

比较 A/B：相同版图结果无差异；在一方修改一图形后对应层 added/removed 区域非空，点结果定位正确。修改任一参与文档后旧差分不可继续代表当前版图；保存导出的差异 GDS 后独立重新导入确认区域。比较与验证均保留原编辑文档。

## 宿主门禁重跑命令

```powershell
# 仅 Python 与临时 HTTP；不启动/停止常驻服务。
Set-Location 'D:\HongTu\hongtu\python\tests'
& 'D:\HongTu\hongtu\python\.venv\Scripts\python.exe' -m unittest -v test_bridge.GeneratedLayouts test_workspace test_verification
```

完整统一入口仍为仓库根目录 `bash tools/check_all.sh`，`--skip-hap` 只跳过 HAP 打包，仍包含宿主/Python/NDK。由 root 统一调度，避免和其他构建抢占输出目录。
