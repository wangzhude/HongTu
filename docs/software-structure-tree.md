# 鸿图软件结构树（MC20 手绘验收进行中，完整专业范围保留）

## MC20 当前状态：手绘与常规原生验收进行中

[AI 原任务恢复与第三次桌面验收](validation/ai-task-recovery-20261006-01/report.md)已由专门6.1-sol / ultra代理修复、双审及ROOT合入 `d3afc45b`。保留原目标/只读生成策略/固定反相器检查，压缩失败及加载取消的目标副本脱敏闭合，面板与详情区分当前编辑Cell/Top。ROOT主树后台80、AI宿主302（完整Index86）全通过；新HAP `59995DA0…F79B6D6`实际构建和15558保留草稿安装成功，337生产/323工具稳定。当前UNIT_A/Top TOP_A、详情、供应商模型入口、空白兼容草稿、固定GET/地址反馈、模型区域和显式关闭通过截图/树复核。原71图形/14Cell/5端口文档逐字节保持；HIER两图形/两Cell仅冷恢复revision22→1和time变化，全部其它字段保持。真实供应商任务、新包原生继续/重试/写入撤销、OS凭据及取消worker终态仍待验；电脑伴随服务未部署，需单独运行更新源码。

[普通 UI 嵌套层级验收进度](validation/multi-layout-20261006-02/progress-01.md)：当前 `d3afc45b` / HAP `59995DA0…F79B6D6` 已完成 TILE_A 3×2 斜向压缩 AREF，以及 TOP_A 2×3 斜向 AREF和单 UNIT 的 R90 / X 镜像 / MAG1.5。实际3 Cell、5物理记录、0端口，展开37 UNIT / 74叶图元；两用途完整filled Region XOR均0，原UNIT属性/有序点及原manual文档字节保持。独立复核通过；随后普通菜单depth3/Fit显示六组阵列和单独变换实例，完整文档仅五个具名视图字段改变。该资格限此层级core与显示检查点；PATH/TEXT/PAD、其它层级操作、另外两张完整图及31组88项继续开放，未获得本批文件导出或物理设备资格。

[手绘 HIER 单项 Boolean 检查点](validation/multi-layout-20261006-01/boolean-checkpoint-01/README.md)在此前安装包完成两矩形的Union、普通Apply/Undo/Redo：实际6点凹L、面积3,200,000 nm²，8用途Region XOR均0，Undo/Redo完整文档只排除revision/time后恢复。该资格仅属旧包单项检查点；该检查点为2Cell/2物理记录，三张手绘版图、完整专业范围及88项验收继续开放。

[AI 多供应商、模型发现与 Agent 修复](validation/ai-agent-providers-20261005/review.md)已本地合并为 `628eec5e`，伴随服务连接清除修复为 `77ef35d4`：每个供应商独立保存多个模型、参数和系统凭据；一键获取 OpenAI 兼容、Ollama 或自定义地址的模型列表，并保留手动 ID。Agent 使用现有 Python 伴随服务，显示计划、工具参数、实际结果及任务状态，支持携带历史的继续/重试；一键模型发现可独立工作。新增“断开并清除连接”，运行期间禁止修改连接，失败读回与回滚有明确反馈。

[2026-10-06 AI 入口与发现草稿修复](validation/ai-discovery-draft-20261006/README.md)由 6.1-sol / ultra 子代理在独立分支完成，已本地合并为 `015611d8`：普通入口明确“供应商/模型”，当前供应商/模型和 Agent 连接摘要移出聊天滚动区；GET 固定在设置底部操作区。新增供应商默认空白兼容协议草稿；选中获取的同名模型不再加载旧地址/密钥，GET 不受生成参数草稿阻断。已有供应商原凭据未读入时，空白草稿不能覆盖密钥；提供重读与显式替换。7 组宿主回归共 179 项通过，使用方法见 [AI 助手说明](ai-assistant-guide.md)。

[本轮独立桌面验收与原始回执](validation/ai-assistant-followup-20261006-01/README.md)绑定实际构建源码 `015611d8`、HAP `4B575A2C…CB703DAD` 和独立目标 `15558`；336 生产文件、323 工具构建前后稳定，构建与保留草稿安装通过。普通入口、新供应商空白兼容草稿、固定 GET/空地址反馈、滚动时模型管理与 Agent 连接入口、显式关闭返回工作台已由根与独立复核查看实际截图/树。原 71 图形版图整份逐字节保持；新 HIER_MATRIX 草稿仅冷恢复 revision 6→1、updatedAt 变化，全部其它字段、字段缺失、类型和次序保持，索引仅对应文件指针变化。Escape 按键虽 ACK，Python 面板未关闭，按原有未设置关闭快捷键行为单列，未授予关闭资格。真实供应商、当前包完整 Agent 执行、原生凭据失败场景及物理设备仍待验；未重跑全软件门禁，历史资格保持原绑定。

[第二次 AI 主树集成验收](validation/ai-runtime-main-20261006-01/README.md)由同规格子代理修复、独立复核并由 ROOT 合入 `e8e6f7b`：补齐新安装遗漏的三个 Agent SDK，健康接口核验实际版本与导入结果，缺 SDK 不再宣称 Agent 可用；经过原鉴权的 Agent/artifact 请求返回可恢复 503，普通几何仍可执行。ROOT 主树新跑 64/64 后台回归及实际隔离启动预检通过，7 个修复文件与冻结源一致；客户端相关 310 个源文件与此前构建保持一致。仅修改 Python 伴随服务、安装、启动和默认回归，没有新增 HAP/原生 UI 资格；初次隔离依赖失败与既有真实供应商、持久化、写入、取消终态及物理设备待验边界保留。

[SDK23/24 历史原生验收及独立复核](validation/manual-complex-20261004/sdk24-ai-final-01/README.md)记录实际构建、保留草稿安装与受控服务测试：SDK23 普通界面保存两供应商/多个模型、获取 4 模型及负例 401；SDK24 当前测试配置冷恢复后无需重输密钥即可 GET 4 模型，鉴权结果结合源码支持系统凭据读回的推断，不扩展到全部配置。PythonBridge/Pydantic SDK 实际完成 5 轮模型交互和规划/版图读取/计划读取/步骤更新 4 项工具；模型响应来自本地 fixture，工具返回实际 71 图形、17 图层、当前 Cell 23 对象。清连接及普通面板重开通过；该轮最后整份草稿与验收前仅更新时间不同。测试供应商已删除，原演示配置保留。真实供应商、推理质量、物理设备、原生写入 Apply/Undo/版本拒绝、运行取消与服务 worker 终态、失败后继续/重试、全部配置冷恢复及清连接后冷启动仍待验，31 组/88 项整体范围未完成。

[AI/Python 面板焦点修复与该轮验收](validation/ai-panel-focus-20261005-01/README.md)的生产源码为 `74c54ebd`：最终关闭后在渲染空闲帧恢复画布焦点；跨面板、弹窗、文档与页面变化会撤销旧请求。主树专项 host 40/40、UI 审计 0 违规、实际构建与保留草稿安装通过。该轮安装包 HAP `1D4DB170…CF66B861`，与历史 SDK24 包分列。AI 配置输入框聚焦→普通关闭→无画布点击 Ctrl+K 实际打开搜索已独立复核；Python 地址输入框聚焦→普通关闭→画布焦点恢复有原生截图/树，Python 后续 Ctrl+K 成功仅作补充观察，采集截图查看时序单独保留。最终 3 次索引/2 次文档回读稳定，完整草稿对安装前实际 1081 仅视口 X/Y 与更新时间不同，71 图形、14 Cell、5 端口、17 图层及整个工程数据保持；锁屏、截图失败与恢复中记录不算功能通过。标题 toggle、输入焦点下跨面板切换及迟到弹窗仍待原生专项。

[SDK21 全层表达式局部原生复核](validation/manual-complex-20261004/sdk21-p08-expression-native-01/report.md)确认非法表达式拒绝、深度 0 合法预览及取消均保留完整草稿。1022/1025/1027/1029 的 8 份文档和 12 份索引逐字节一致，仍为 71 条记录、14 Cell、5 端口、revision 16、选区 [82]。合法预览实际显示 4 个来源 / 4 次放置 / 3 个结果；面积仅记录界面观察，输出几何未作独立资格。深度 1/2、Apply 与 Undo/Redo 尚待执行。

SDK22 实例选框修复已本地提交 `33f503bc`：选中实例使用成功解析的可见层级世界边界；空层级、隐藏图形、预算失败或非有限边界保留原入口标记，不改图形与历史数据。[候选宿主检查](validation/manual-complex-20261004/sdk22-instance-selection-bounds-candidate-01/README.md)17/17 通过，[全局 UI 静态检查](validation/manual-complex-20261004/sdk22-ui-audit-01/control-audit-global.json)为 193 个源文件、393 个按钮、0 违规。[本包构建、保留草稿安装及绑定审查](validation/manual-complex-20261004/sdk22-actual-cohort-review-01/report.md)实际通过，安装 HAP `7F53C048…75F153`。[1030–1037 原生局部审核](validation/manual-complex-20261004/sdk22-instance-selection-native-01/actual-audit-1037-03.json)确认普通恢复、最大化、取消选择、重新选择的文档与真实截图/树：蓝框包住圆的世界边界，取消后消失，重新命中 #82。三张选中截图实际解码像素符合 4px 外描边容差，旧长蓝框消失；取消选择没有额外像素量化，不借用选中帧。71 记录、14 Cell、5 端口、17 图层与完整几何/metadata/engineering 保留；普通恢复的 revision 16→1 及窗口 camera 变化具名记录，最大化后回到原 wide camera。取消/重选只改变选区与对应 flags/updatedAt。缩放、平移、其它旋转/MAG 的原生显示仍待验，旧 SDK21 的失败报告原样保留。

[SDK21 四种普通曲线原生验收](validation/manual-complex-20261004/sdk21-curve-gallery-native-01/report.md)已有 4/4 实际 Apply、Undo、Redo 独立资格，冻结评价器 48 项检查全部 qualified。Circle、Ellipse、Donut、Arc 的有序点数分别为 32/36/66/66，逐点误差均为 0；面积、圆环孔洞、圆弧角域、误差界和 attr126 参数来源逐项核对。各次 Undo 完整恢复实际 pre，Redo 完整恢复 Apply，仅排除顶层 revision/updatedAt；原图形、13 Cell、5 端口、完整工程与图层样式顺序保持。普通图形 gallery 终态 1014 为 69 条记录、13 Cell、5 端口、16 个图层，revision=13、选区及 flags 均 [80]，四图保留。先前 Apply-only 报告保留其当时历史待验结论，不回写旧证据。[Circle 参数实例数据与历史审核](validation/manual-complex-20261004/sdk21-circle-instance-native-01/report.md)及独立第二审通过：新增本地圆 #81、CIRCLE_1 与引用 #82，完整旧 metadata、ports、样式与整个 engineering 保留；Undo 恢复 1014，Redo 恢复同一组身份。当前 1022 为 71 条记录、14 Cell、5 端口、17 个图层，revision=16、选区及 flags 均 [82]。蓝色选择框仍使用锚点及固定屏幕入口尺寸，未包住真实圆的世界边界，UI 待 SDK22 修复与原生复验；本项只资格化数据/历史，不声明实例整项 UI 通过。31 个专业组、P07 整体及 88 项总范围仍未完成。

[SDK21 构建、保留草稿安装与恢复](validation/manual-complex-20261004/sdk21-install-recovery-01/report.md)已实际通过，源码本地提交 `d11449fa`，65 条记录、13 Cell、5 端口及完整工程草稿保留。[当前生产选择历史宿主专项检查](validation/manual-complex-20261004/sdk21-selection-current-host-01/README.md)为 P08 30/30、参数器件库插入18/18；[旧通用宿主检查器的新副本环境修复](validation/manual-complex-20261004/sdk21-general-host-repair-01/README.md)已取得 Clip 22/22、Index 编辑闭合 16/16，均 terminal、exit 0，并通过独立审核。只补齐真实依赖 staging 和宿主 fixture，原测试断言保持；7 个生产文件哈希稳定，原工具及模块/方法缺失的旧失败证据原样保留。这些宿主结果不作为 P08 原生通过。[SDK21 圆角反馈原生复验](validation/manual-complex-20261004/sdk21-round-feedback-native-01/report.md)已修正 SDK20 的两项提示缺陷：非法半径显示实际原因，有效预览及取消清除旧错误。973/975/977/979 的完整文档逐字节相同，没有借用旧包的几何 Apply 资格。正在继续四种曲线及 P08 原生流程，31 个专业组及完整 P07–P19/88 项总范围仍未完成。

[SDK20 负偏置与空侵蚀复核](validation/manual-complex-20261004/sdk20-offset-negative-empty-native-01/report.md)新增 −2000 nm 空侵蚀的完整原生资格：Apply 删除 #75、输出选区为空，Undo 和最终 Undo 恢复完整原文档及 [75]，Redo 恢复删除后的完整文档；L1/0 物理计数 16→15，其余 64 条记录、13 Cell、5 端口及工程数据保留。−200 nm 的几何和历史端点正确，但操作 927 缺少最终截图，仍未取得完整视觉资格，后续启动截图不补算旧操作通过。

[SDK20 圆角原生审核](validation/manual-complex-20261004/sdk20-p07-round-native-01/report.md)确认半径 200 nm 的 28 顶点、面积 23964233.14164921 nm²、弦高 1.711027725 nm，以及即时 Apply/Undo/Redo/最终 Undo 的完整端点；非法半径、prepare 与取消均未修改文档。仍发现失败提示误称“尺寸调整”和旧错误状态未清除，两项反馈问题保持待复验。当前源码已接入具体失败原因、成功校验及取消反馈，并将参数器件库插入、全层表达式、层级 Clip、区域 Fill 的结果选择纳入同一次结构事务；新版构建和原生验收另记，不能将这些源码修改视为已通过。四种曲线及完整 P07–P19、88 项专业范围继续开放。

P07 的 [SDK18 实际相减与异或复验](validation/manual-complex-20261004/sdk18-p07-boolean-native-01/report.md)已通过独立检查 19/19。两条源矩形 #75/#76 保留，输出均为 L121/0：相减 #77 面积 20000000 nm²，异或 #78/#79 合计 40000000 nm²。Apply 选中输出，Undo 与最终 Undo 恢复 [75,76] 及完整应用前文档，Redo 恢复输出与选区；只有顶层 revision/updatedAt 单独记账。原始主选择 selectedId 未持久化，仍不可观察；全 P07、全部预览及完整手绘流程未完成，负偏置、空侵蚀和曲线实际应用尚待验。

[SDK20 +200 nm 常规原生复验](validation/manual-complex-20261004/sdk20-offset-positive-native-01/report.md)已通过独立检查：[应用前 910](validation/manual-complex-20261004/states/sdk20-offset-positive-before-910/receipt.json)为 [75]；[应用 912](validation/manual-complex-20261004/states/sdk20-offset-positive-applied-912/receipt.json)选中 #77，L1/0、ownerCellId=0、selected=true，范围 (11800,7800)–(18200,12200)，独立鞋带面积 28160000 nm²；[撤销 914](validation/manual-complex-20261004/states/sdk20-offset-positive-undone-914/receipt.json)与[最终撤销 918](validation/manual-complex-20261004/states/sdk20-offset-positive-final-undone-918/receipt.json)恢复完整应用前文档及 [75]，[重做 916](validation/manual-complex-20261004/states/sdk20-offset-positive-redone-916/receipt.json)恢复完整应用后文档及 [77]，仅顶层 revision/updatedAt 另记。64 个旁系记录的全部字段及顺序保持，13 Cell、5 端口及完整 engineering 保留。905 首个冷启动 Ctrl+K 实际打开命令搜索；906 恢复草稿，908 最大化后除 revision/updatedAt 外与 SDK19 最终 903 完全相同。[本轮绑定与桌面恢复记录](validation/manual-complex-20261004/sdk20-ordinary-ui-prep-01/actual-target-bind-01/binding.json)确认两台原模拟器已在线，恢复可见桌面窗口到前台，未重启进程。本项不扩展为负偏移、空侵蚀、曲线、全部快捷键或完整 P07 通过。

[SDK17 原生报告](validation/manual-complex-20261004/sdk17-p07-boolean-native-01/actual-report.md)保留 841 四种预览、842 非法 Layer/Datatype 拒绝及 843–849 相减：几何通过，但 Undo 丢失选区，49/50；850–853 普通 Undo 与框选恢复草稿，没有覆盖原始 GDS。SDK18 已把结果选择纳入结构事务，普通曲线同步接入；空布尔结果且保留原图时保持完整状态，并明确未产生编辑。[修后宿主回归](validation/manual-complex-20261004/sdk18-boolean-selection-host-prep-01/runs/fixed-v2-01/report.json)35/35、[冻结 SDK17 负例](validation/manual-complex-20261004/sdk18-boolean-selection-host-prep-01/runs/sdk17-negative-v2-01/report.json)26 通过/9 失败；现有事务 45、几何 39、结构图层 15 项通过。[SDK18 构建与保留草稿安装恢复](validation/manual-complex-20261004/sdk18-install-recovery-01/report.md)实际通过。858 的冷启动 Ctrl+K 只有输入 ACK，没有打开搜索；当前源码为已有画布键盘节点增加初始默认焦点，[SDK19 构建](validation/manual-complex-20261004/sdk-19/result.json)及[保留草稿安装、普通启动](validation/manual-complex-20261004/install-sdk-19-v12/receipt.json)实际通过，安装备份与 881 字节相同。882 在任何输入前因原桌面 PID28276 退出而拒绝，未派发按键。[883 冷启动复验](validation/manual-complex-20261004/sdk19-cold-focus-native-01/report.md)确认首个 Ctrl+K 实际打开搜索；旧 885 顶层运行元数据错误保留。使用修正元数据适配的 [891–893 模态复验](validation/manual-complex-20261004/sdk19-cold-focus-native-01/actual-893-report.md)通过：搜索框输入和指定快捷键后关闭，完整文档字节、选区和全部图形 flags 保持。这里只确认这些具名入口，所有快捷键、手机和多窗口仍待验。

2026-10-05 11:18 的[桌面恢复](validation/manual-complex-20261004/desktop-window-resume-20261005-1118-01.json)核实两台模拟器仍运行并连接，将已有桌面窗口置于前台；904 普通截图显示鸿图及手绘版图，未重新启动进程。[SDK19 尺寸调整原生复验](validation/manual-complex-20261004/sdk19-offset-positive-native-01/report.md)实际以 #75 执行 +200 nm：输出 #77 为 L1/0 多边形，范围 (11800,7800)–(18200,12200)，面积 28160000 nm²；两次 Undo 恢复 #75 与 [75]。首次 Apply 选区为空，而 Redo 选中 [77]，这一差异未通过验收。当前源码把尺寸调整和结果选区纳入同一结构事务；[实际宿主回归](validation/manual-complex-20261004/sdk20-offset-selection-host-01/report.md)几何 50/50、编辑闭合 16/16 通过，正负偏移、多结果、空侵蚀、选区顺序/主选择、锁层和发布失败回滚均覆盖。[现有结构/图层回归](validation/manual-complex-20261004/sdk20-offset-structure-regression-01/structure-layer-history-results.json)15/15 通过。修复已本地提交 `8f3de216`；[SDK20 构建](validation/manual-complex-20261004/sdk-20/result.json)实际终态通过，Hvigor 21.620 秒、worker 已停止，源码/运行/HEAD/ZIP 校验保持。[保留草稿安装与普通启动](validation/manual-complex-20261004/sdk20-install-recovery-01/report.md)已通过，两份安装前备份与 903 字节相同；两模拟器在线。其他偏移原生复验与完整 P07 仍开放。

[826 基线](validation/manual-complex-20261004/states/sdk16-p07-before-826/receipt.json)为 63 记录；[827 普通画布拖绘及独立回读](validation/manual-complex-20261004/states/sdk16-p07-two-boxes-827/receipt.json)新增 TOP 的两条 L1/0 矩形 #75、#76，分别为 (12000,8000)–(18000,12000) 与 (16000,10000)–(22000,14000) nm。SDK18 的 879 草稿为 65 记录、13 Cell、5 端口及 [75,76]，revision=9。原桌面于 2026-10-05 00:00:21 按用户授权保留数据重启为可见窗口，[运行身份](validation/manual-complex-20261004/runtime-desktop-window-01.json)已记录。2026-10-05 10:24 核对两台仍在线的模拟器，[恢复最小化桌面窗口至前台](validation/manual-complex-20261004/desktop-window-resume-20261005-1024-01.json)；本轮没有重启进程。880 实际截图正常，[881 独立回读](validation/manual-complex-20261004/states/sdk18-desktop-resume-881/receipt.json)整份文档与 879 字节相同，包含未保存修改、工程与选区。当前已正常安装 SDK19；2026-10-05 10:45 按用户授权只重启退出的原桌面，[新运行身份](validation/manual-complex-20261004/runtime-desktop-window-02.json)为原桌面 PID90688、验收实例仍 PID2328，两者 HDC 连接通过。[桌面窗口](validation/manual-complex-20261004/desktop-window-restart-20261005-1043-window.json)已置于前台；未重置磁盘或访问原桌面的私有应用数据。

截至操作 821 的历史手绘补充证据运行 SDK16，草稿为 13 个 Cell、63 条物理记录、5 个端口，包含嵌套阵列、Fill 引用、Clip 派生 Cell、MOS 参数化器件及两级局部变体。系统于 2026-10-04 21:41:48 再次重启；22:04:12 已按用户授权分别启动两台保留磁盘的桌面模拟器，进程身份、配置哈希及 HDC 连接重新核实，未重置或复制磁盘。[SDK13 普通启动](validation/manual-complex-20261004/post-reboot-start-03/receipt.json)与[790 独立回读](validation/manual-complex-20261004/states/sdk13-reboot03-preserved-790/receipt.json)通过：63 记录、13 Cell、5 端口及 dirty=true 保留，与 789 仅 offsetX/offsetY/revision/updatedAt 不同；几何、Cell 元数据、端口及整份 engineering 原样保留。731 的 SDK12 正常界面及独立回读确认同一草稿与未保存修改保留；[732 SDK13 普通恢复复核](validation/manual-complex-20261004/sdk13-install-recovery-01/report.md)确认完整业务字段保留。[735–739 Fill 零结果复核](validation/manual-complex-20261004/sdk13-fill-zero-native-01/REPORT.md)与[741–750 MOS 全框 Clip 复核](validation/manual-complex-20261004/sdk13-mos-clip-native-01/REPORT.md)保留各自具名范围。

[752–789 P06 实际操作与独立回读](validation/manual-complex-20261004/sdk13-p06-native-01/REPORT.md)：共享修改影响全部 64 个 UNIT 摆放；提取单个成员保持全部世界几何；局部隔离得到 63 个共享 UNIT 和 1 个 UNIT_local，改宽仅影响该位置的一条矩形。三种 Cancel 均完整文档字节一致，结构和几何 Undo/Redo 分开验证。原 v1 检查器把保留的工程审阅来源当作实时 Cell 镜像，实际失败结果原样保留；依据工程 carry/ownership 契约修正的 v2 保留原几何检查并增加整份 engineering 严格保留条件，实际 64/64 通过。工程恢复的匹配与失效拒绝规则未改，不能将这项语义资格扩展为 UI 或工程恢复通过。

787 普通“创建版本”已保存当前 63 记录库，788 实际滚动看到新增版本，789 关闭面板回到 TOP；dirty 仍为 true，原 baseline GDS 未覆盖。`03_local_variant` 是计划阶段名，版本 UI 沿用文档标题，没有命名输入。SDK15 的提取／局部隔离回归已取得具名原生资格，SDK16 已实际完成 Tab 正向与 Shift+Tab 反向轮选；端口细节、P07–P19 及最终 GDS/OAS/鸿图工程仍待继续，不能由当前记录数推定计划完成。

SDK13 源码 `1d2d74ca1f5cc52592e2f0f466fa265b71a9cf1f`，[增量构建](validation/manual-complex-20261004/sdk-13/result.json)终态通过，23.797 秒，源码及运行绑定前后稳定；未签名 HAP 58,498,272 字节，SHA-256 `B7339217D09D203672DC2F29881ED7C3E94573BF5792599DB3351E9D1E9249C3`。[实际替换安装与普通启动](validation/manual-complex-20261004/install-sdk-13-v7/receipt.json)通过，安装前当前 SDK12 草稿三次索引与两次文档备份一致。Fill/Clip 共用严格矩形识别，兼容合法两点及四顶点 RECT；[独立 host 复核](validation/manual-complex-20261004/sdk13-rectangle-compatibility-host-01/REPORT.md)包含 Fill 51、Clip 34 与真实 49 记录库的 9 项检查；构建、安装和 host 结果不代替新的原生操作资格。

SDK14 仅补充 Fill 预览标题的含义，源码 `de508a110e51cd9d6ea27b2550dd54fcbe82cf3c`；[增量构建](validation/manual-complex-20261004/sdk-14/result.json)终态通过，27.922 秒，未签名 HAP 58,498,312 字节，SHA-256 `B14EF4377C5CC9E4D6B87215F58D6C887FA5B5B7320D6EC8C17541A9F836B24E`。此包尚未安装，不能将 SDK13 的旧文字截图称作 SDK14 新标题通过。

SDK15 包含 Fill 标题及本轮选择历史、候选清理、端口标签、工具栏描述修复，源码 `17c29ba946ff54db498c1f27b8571e6ae6c1f7a2`；[增量构建](validation/manual-complex-20261004/sdk-15/result.json)终态通过，源码、Git HEAD 与运行绑定前后稳定，构建 worker 已停止。Hvigor 报告 77.526 秒，ArkTS 编译 36.734 秒，C++ ABI 使用增量产物；未签名 HAP 58,503,126 字节，SHA-256 `0086B5A66CD4190677CCE9FEBAABF3BD47E85C896FB6C6CCFFB69F133D6931DC`。[同包替换安装与普通启动](validation/manual-complex-20261004/install-sdk-15-v8/receipt.json)已通过，安装前索引与两份独立草稿备份稳定。[793–812 完整专项回读](validation/manual-complex-20261004/sdk15-p06-native-01/report-02.json)实际 129/129：提取 Apply/Redo 只选中单个实例 #76；两级局部隔离 Apply/Redo 均为空选区；结构变化后旧候选消失，Cancel 完整文档字节一致；最终两次 Undo 恢复 63 记录、13 Cell，449 个世界图形、5 个端口及整份 engineering 始终保留。Local Undo 仍保留叶级相机，[813 普通 Fit](validation/manual-complex-20261004/states/sdk15-p06-restored-fit-813/receipt.json)已返回 TOP 全图视野，不能称相机字节还原。专项通过不等于整功能或 88 项验收完成。

SDK16 仅补物理 Tab 键码映射，源码 `435d659e68d8935defc9653db6903689a3cf54f0`；[增量构建](validation/manual-complex-20261004/sdk-16/result.json)终态通过，Hvigor 11.236 秒，源码／HEAD／运行绑定前后稳定且 worker 已停止；未签名 HAP 58,503,245 字节，SHA-256 `60F44BAC5977CE7BD739E103628541362F799F150BF89F1807F0473204D38381`。[同包替换安装与普通启动](validation/manual-complex-20261004/install-sdk-16-v9/receipt.json)通过，三次索引及两份独立草稿备份稳定。[817–819 Tab 专项](validation/manual-complex-20261004/sdk16-tab-native-01/report.md)实际 38/38：普通点选第一个候选 #16，实际 Tab2049 前进到第二候选及外层选区 #59，实际 Shift2047+Tab2049 回到 #16，候选与画布键盘叶焦点保持；除选区及 updatedAt 外的所有文档字段完整一致。原检查器将三个已 pin 的合法依赖误拒为越界，功能检查前的失败 report01 保留；v2 只精确授权这三个依赖文件，原功能条件及 UI／state 边界不变。820 Escape 仅取消选区，命中列表及预览仍在，作为 UI 行为待细查；[821 普通空白点选](validation/manual-complex-20261004/states/sdk16-workbench-clear-821/receipt.json)实际清空候选，保留 63 记录、13 Cell、5 端口、dirty=true 和完整 TOP 视野。没有扩大到所有快捷键或全 88 项验收。

SDK12 源码 `dc0b1eca40324b14131dee3babc9387094ea6df7`，[增量构建](validation/manual-complex-20261004/sdk-12/result.json)终态通过，未签名 HAP 58,497,075 字节，SHA-256 `0584995504465E040275AE29E253B3DF7866D3B95AE393F488E237C884F584AE`。[实际替换安装与普通启动](validation/manual-complex-20261004/install-sdk-12-v6/receipt.json)通过，安装前备份当前 SDK11 手绘文档；[717 普通恢复回读](validation/manual-complex-20261004/states/sdk12-normal-recovery-717/receipt.json)确认 11 Cell/49 记录、dirty=true。[Cell 行原生复核](validation/manual-complex-20261004/sdk12-cell-row-native-01/report.md)确认名称单击、箭头独立展开/折叠、双击及明确按钮进入、返回 TOP 和 Fit，32 个完整业务字段保留；[MOS 参数反馈原生复核](validation/manual-complex-20261004/sdk12-mos-feedback-native-01/REPORT.md)确认 Width50 错误完整可见、改为1000后旧提示消失、位置保留、实际 Cancel 后完整文档字节一致。四顶点矩形兼容修复不在 SDK12 中。

SDK11 源码 `d6826486ba1b0f5ba3412618e17594a4df098845`，334 生产/318 工具；[增量构建](validation/manual-complex-20261004/sdk-11/result.json)终态通过，源码与运行绑定前后稳定。实际未签名 HAP 58,494,037 字节，SHA-256 `51ACCEBE024700149CE0ED2367F3AE1380BB19D6C8B6E1232C73721F83690800`；[同包替换安装与普通启动](validation/manual-complex-20261004/install-sdk-11-v5/receipt.json)通过，安装前当前手绘草稿的三次索引/两次独立文档备份稳定。[679 实际恢复读取](validation/manual-complex-20261004/states/sdk11-restored-after-install-679/receipt.json)确认 11 Cell/49 记录、dirty=true，当前普通恢复界面见[679 原生截图](validation/manual-complex-20261004/captures/679-sdk11-restored-workbench-before.jpeg)。SDK10 已构建但未安装；v4 安装前标题保护误拒及 SDK09 普通恢复收据原样保留，不改写为成功安装。

| 当前手绘节点补证 | 已取得的实际范围 | 当前修复版待验范围 |
| --- | --- | --- |
| Fill | [SDK09 原生语义报告](validation/manual-complex-20261004/fill-native-semantic-01/report.md)：25 个摆放成员压缩为 5 个引用记录，Preview 不改文档，实际 Apply/Undo/Redo。SDK11 的 713–715 在加入 MOS 后实际失败为“Fill 源矩形无面积”；716 Cancel，前/失败后/取消后字节一致。SDK13 的 735–739 使用同一真实 49 记录库，DUMMY 默认排列步距401，ROI0–1000：25候选/24区域外/1避让/0新增，说明可见、应用禁用，实际 Cancel 三份文档字节完全一致。 | SDK11 失败及旧 586 未 Cancel 保留。SDK13 右图374是原有材料，标题易混淆；当前源码已改为“填充后材料（含原有）”，后续包原生文字复验待完成。SDK13 的正向 Apply/Undo/Redo、更广用途及组合病例仍待验。 |
| 层级 Clip | [637 进度及具名证据](validation/manual-complex-20261004/manual-progress-20261004-through-637.md)：锁层拒绝、正向 Preview/Cancel/Create/Undo/Redo，4 个新 Cell/16 条记录；真实 ROI 各层几何与原定义保留已独立检查。[SDK11 实际进入与 Fit](validation/manual-complex-20261004/sdk11-clip-fit-native-01/report.md)45/45，通过 70 个展开图形、19.8×10 µm 完整 ROI 的原生可见与状态回读，原单引用字段保留。SDK12 的 720–723 已实际确认名称/箭头/进入职责分离及完整 ROI 适配。[SDK13 MOS 全框原生复核](validation/manual-complex-20261004/sdk13-mos-clip-native-01/REPORT.md)通过实际 Preview/Cancel/Create/Undo/Redo；原定义与共享引用保留，新增六个 RECT、五个 clip-static 端口与 lineage，未新增可重生成 PCell 意图。最终撤销恢复原完整业务字段。 | SDK11 的 686 名称双击失败保留，不改写。SDK13 此次为 MOS 全包含 ROI；部分几何裁剪、孔径边界排除以及更广组合原生病例仍待验，不以 host 结果代替。 |
| MOS PCell | [SDK09 实际 MOS 报告](validation/manual-complex-20261004/native-mos-semantic-01/report.md)：非法 Width 拒绝、有效参数 Cancel、生成 6 个图形/5 个端口/TOP 引用及一次 Undo/Redo，原 42 记录/10 Cell 保留。SDK11 的 698–700 实际 Width50 拒绝，错误完整可见；702/703 改回1000仍残留旧提示，706 Cancel 文档字节保持。SDK12 的 725–730 已实测旧提示立即清除、X8000/Y4000保留和实际 Cancel，前/拒绝后/取消后三份完整文档字节一致。 | SDK12 仅此次参数反馈路径通过；未重新生成 MOS 或扩大到所有参数编辑。SDK09 Undo 的派生 engineering 字段单独检查，不称整文档字节完全还原。 |
| 共享编辑／提取成员／仅改此处 | SDK13 的 Shared、Extract、Local 及局部改宽 v2 实际 64/64 保留。[SDK15 具名复验](validation/manual-complex-20261004/sdk15-p06-native-01/report-02.json)实际 129/129，确认提取单成员、局部空选区、Undo/Redo 精确选择端点、旧候选清理及 Cancel 原样保留。[SDK16 Tab 双向专项](validation/manual-complex-20261004/sdk16-tab-native-01/report.md)实际 38/38。 | SDK13 旧选择／候选失败与 SDK15 796 Tab 负例不改写；[键码缺项窄修及 host 17/17](validation/manual-complex-20261004/tab-keycode-native-gap-host-01/report.md)属于 SDK16 的源码来源。Local Undo 保留叶 Cell 相机，813 通过普通 Fit 恢复；820 Escape 保留候选／预览的行为仍待细查。实例固定标记不是完整阵列外框；[标记审计](validation/manual-complex-20261004/sdk15-instance-marker-audit-01/report.md)保留后续 UI 改进范围，没有证明几何或框选丢失。 |

UI／历史细节已进入 SDK15：793 原生树确认 Undo/Redo/Zoom description 非空，802–812 使用有描述的按钮完成历史操作；概览截图中的 G0 名称可读，孔径和方向箭头保留。端口全部名称、密集布局、DPI 及点击仍待细查。真实方法 host 检查包含端口标签 6、工具栏 6、层级编辑 24、事务兼容 45；[候选清理专项](validation/manual-complex-20261004/stale-hit-candidates-host-01/result.json)保留新回归及静态 UI 审计。Tab 的独立键码窄修已在 SDK16 的实际双向按键与回读中生效，SDK15 负例与旧 SDK13 截图保持原样。

SDK09 历史源码 1d64c7071fc921f7ffc6854752fc51a67ddb935d，334 生产/318 工具；[增量构建](validation/manual-complex-20261004/sdk-09/result.json)终态通过，20.422 秒，源码/工具及运行绑定稳定。HAP SHA-256 为 9B4F0391FC2EB0C3190F440B5217F91A708078764F4F0569B0B407E6B02E1F75；[同包安装与普通启动](validation/manual-complex-20261004/install-sdk-09-v3/receipt.json)通过。[552 独立资格报告](validation/manual-complex-20261004/text-glyph-readonly-native-01/report.md)9/9 证据检查、104 输入绑定前后稳定，仅资格化 TEXT19 字形点击、锁定 RECT16 只读属性及正常恢复小病例，不声明整功能完成或 fresh native compile。[SDK08 的 ArkTS structural typing 编译失败](validation/manual-complex-20261004/sdk-08/result.json)保持原失败边界；显式 affine 适配后的 fresh 14/14 host 与 SDK09 源码快照相符。

472 检查点及截至541的补证运行 MC20 SDK06。源码 c16bd451d9d4523722fe6b6d91ceaf318d7330fd，333 生产/317 工具；[SDK06 增量构建](validation/manual-complex-20261004/sdk-06/result.json)终态通过，21.797 秒，源码/工具及运行绑定前后稳定。HAP SHA-256 为 57463AC561031CC4A27E851DCE57616315399C741AE5353B4DD9B361945CDFE8；[同包安装](validation/manual-complex-20261004/install-sdk-06-v3/receipt.json)与普通 EntryAbility 启动通过。构建/安装回执未声明完整原生功能验收或 fresh native compile，功能资格只归下列具名病例。

[当前可见桌面运行身份](validation/manual-complex-20261004/runtime-desktop-window-01.json)为验收实例 PID2328 / 127.0.0.1:15558、原桌面 PID28276 / 127.0.0.1:5555。原桌面已按用户授权从 PID18388 保留数据重启为可见窗口；839 核对两个进程与配置，并确认验收应用画面仍在。手机按最新桌面范围保持关闭。API24、2in1 emulator、配置型号 PCEMU-FD00 的既有配置哈希保持。此前 [runtime-reboot-03](validation/manual-complex-20261004/runtime-reboot-03.json) 的原桌面 PID18388、[runtime-reboot-02](validation/manual-complex-20261004/runtime-reboot-02.json) 的 PID30504/4004、[runtime-reboot-01](validation/manual-complex-20261004/runtime-reboot-01.json) 的 PID29244/21228，以及下面 R19 的 PID、包、“当前/本轮/本包”和手机运行状态均保留为历史证据，不代表当前运行。此次恢复没有重置模拟器、复制虚拟磁盘或注入版图，也未访问原桌面的私有文档。

[472 实际草稿](validation/manual-complex-20261004/states/sdk06-top-tile270-472/document.json)包含 TOP_MANUAL、UNIT、TILE、PAD、DUMMY、NAV_EMPTY 六个定义、18 条物理图元记录：11 条实体图元与 7 条引用（3 条压缩 AREF、4 条 SREF）；各 owner 数为 TOP5/UNIT6/TILE3/PAD3/DUMMY1/NAV_EMPTY0。工程仍 dirty=true，DBU1 nm、绘制步长/显示网格100 nm；NAV_EMPTY 是恢复专项的辅助空定义。屏幕展开数量和逻辑摆放数不能当作物理记录数，也不能把六定义/18记录当作全部计划完成。

[截至332的冻结 coverage](validation/manual-complex-20261004/coverage.json)与[进度记录](validation/manual-complex-20261004/native-progress-through-332.md)仍为 19 partial / 1 retest_pending / 68 pending，整功能/节点/专业组/phase/objective completion 全部 false。后续补充证据不回写这个历史快照。12 节点、31 专业组和全部历史合同继续保留；514 baseline GDS 的实际保存和独立回读已另列补证，普通 UI 重开及 OAS/鸿图工程仍 pending。后续 UI 正在继续，大文件架构改造和扩大性能压力按用户要求 deferred；未声称全功能补齐。

SDK16 取消交互的后续窄修见[Escape 只读审计](validation/manual-complex-20261004/sdk16-escape-hit-list-audit-01/report.md)。SDK17 源码已处理空闲 Select 的普通 Escape 清候选，保留手势、mnemonic 与 Index 的 Ctrl/Alt/Meta gate；[最终 host 复核](validation/manual-complex-20261004/sdk17-escape-dismiss-host-01/report-final.md)同测试新源 26/26、冻结 SDK16 旧源 25 通过／1 预期失败，旧 18 条均保留。首版未覆盖 modifier 的证据未改写。绘图工具另补三处描述，来源与实际 826 的 11 个空 description 节点见[标签审计](validation/manual-complex-20261004/sdk17-drawing-toolbar-labels-01/audit.md)。[SDK17 增量构建](validation/manual-complex-20261004/sdk-17/result.json)及[同包安装与普通启动](validation/manual-complex-20261004/install-sdk-17-v10/receipt.json)终态通过；[829–833 原生专项](validation/manual-complex-20261004/sdk17-escape-native-01/report-03.json)60/60 证据检查通过，实际确认 Tab/Shift+Tab 双向轮选、普通 Escape 同时清选区/候选栏/蓝色预览及 11 个已呈现按钮描述。完整文档按 fresh829 的键集合、类型和值及数组次序保持；仅选择字段和 updatedAt 属于本次操作允许变化，对象输出键序变化另记。首两次过严键序检查失败记录保留。此次通过仅覆盖具名专项，不能扩大到整套 UI、全部修饰键或完整工作流；底栏最后命中读数仍是独立状态，未判为缺陷。

### 七项修复与实际资格对照

| 修复 | 本轮行为与具名证据 | 仍开放的边界 |
|---|---|---|
| 定义导航 | Cell 定义入口规范栈，面包屑/当前编辑范围按实际定义；SDK03 的 TOP [0]、PAD [0,3] 及进入/返回局部复验见[through332](validation/manual-complex-20261004/native-progress-through-332.md)。 | 旧188/192循环失败保留；多父/具体实例路径全部组合未验。 |
| 画布焦点 | Sidebar 进入 UNIT 后画布取得键盘焦点，274 Ctrl+K 真正打开命令 Dialog。 | 只此普通入口与快捷键，不代表全 Profile/手机焦点通过。 |
| TEXT 选择框与正常 fallback | 278 唯一 UNIT 字形加选择轮廓/锚点，保留实际字号/变换边界；正常 TEXT fallback 不再用红色 renderError 遮住面包屑，真实错误报告保留。 | 279 是旧纯点选未监测的空 selection 草稿，不否定278实时UI；全字体/变换/拖动组合未验。 |
| cutoff bounds 与 Fit | depth1/2 的停止引用有框且参加非空 Fit；depth3 展开此嵌套3×2 AREF，L10隐藏后290有原生几何，恢复293有序 fallback。 | 仅具名1/2/3深度、此共享层次；全部深度/表达式/DRC/规模未验。 |
| native 可选属性 | properties/libProperties/cellProperties 的 missing 与 undefined 按缺省处理，非法非数组及预算仍拒绝；[42项已保存 host](validation/manual-complex-20261004/native-optional-properties-host-02/result.json)的生产 C++ hash 匹配 SDK06 snapshot。 | MSVC 精确生产 helper 配合模拟 NAPI 边界；不等于完整目标 NAPI/设备/格式验收。 |
| 纯选择与 Cell 路径 autosave | [独立原生补证](validation/manual-complex-20261004/selection-navigation-qualification.md)：SDK04 348 []→349 [9]→350 重开仍[9]；SDK04 空Cell361→362退回TILE失败，SDK05 366→367保持NAV_EMPTY [0,5]。 | 保存的7 nav+7 selection host使用抽取方法/虚拟时钟，未执行完整启动；SDK05单选重开未重跑，具体AREF路径原生恢复未闭环。 |
| viewport 世界中心 | [普通应用重开复核](validation/manual-complex-20261004/camera-cold-restore-qualification/qualification.md)349→350、354→355、366→367中心保持；[SDK06窗口复核](validation/manual-complex-20261004/viewport-resize-native-01/report.md)428→429→432普通/最大化/还原中心均(32000,34150)nm，zoom1.7294%。 | offsets/revision可变化，不称camera字节不变；比例/取整模型、分辨率和非原子采样限制明示，未扩大到其它窗口/设备。 |

### SDK06 四个独立原生小叶

| 操作 | 实际 UI 与草稿核对 | 本页限定资格 |
|---|---|---|
| 448 | [UI](validation/manual-complex-20261004/captures/448-sdk06-die-fit-after.jpeg)与[document](validation/manual-complex-20261004/states/sdk06-die80000x60000-448/document.json)：RECT16 L99/0 ownerTOP，(0,0)..(80000,60000)nm；属性与Fit均80000×60000，Fit1图形/2未展开框、zoom1.0867%。 | 精确边界与此深度Fit；当时16物理记录，不代表全部绘图节点完成。 |
| 454 | [UI](validation/manual-complex-20261004/captures/454-sdk06-boundary-lock-after.jpeg)与[document](validation/manual-complex-20261004/states/sdk06-boundary-outline-locked-454/document.json)：同RECT16；L99/0 fillStyle=outline、locked=true，实体填充退为轮廓，状态栏锁定。 | 此图层样式/锁定状态；未由锁定状态推定全部锁层编辑拒绝分支。 |
| 463 | [UI](validation/manual-complex-20261004/captures/463-sdk06-top-tile90-confirm-after.jpeg)与[document](validation/manual-complex-20261004/states/sdk06-top-tile90-463/document.json)：TOP中TILE SREF17@(62000,18000)，rotation90/mirror0/MAG1，17物理记录。 | 此普通放置、变换字段、选中及可见停止框。 |
| 472 | [UI](validation/manual-complex-20261004/captures/472-sdk06-tile270-confirm-after.jpeg)与[document](validation/manual-complex-20261004/states/sdk06-top-tile270-472/document.json)：TOP中TILE SREF18@(62000,38000)，rotation270/mirror1（X）/MAG1，18物理记录；L99轮廓/锁保持。 | 此第二右侧引用；完整展开像素、其它变换、共享编辑/历史与保存往返仍待验。 |

四项实际 document 长度/hash、before/after index稳定、readback/UI receipt终态及 installedCohort 均匹配 SDK06 build/install。ACK 不单独作为功能通过依据。图层99、TILE两引用和现有三条压缩AREF仍按真实物理记录保存。

### SDK06 baseline 保存、回读与锁层拒绝补证

[505 草稿](validation/manual-complex-20261004/states/sdk06-top-two-routes-505/document.json)已有 21 条业务物理记录：8 BOUNDARY、3 PATH、3 TEXT、3 压缩 AREF、4 SREF；六个 Cell 定义保留，depth3 展开 418 个叶摆放。[实际另存为](validation/manual-complex-20261004/states/sdk06-baseline-saved-514/receipt.json)后 title=manual-complex-baseline.gds、dirty=false；保存前后的全部 shapes/layers/Cell/precision 保持，DBU 量化只作用于写出快照。

此实际 GDS 是 2782 bytes，SHA-256 D938C05184D30D0534898F9595EA5D2190512AD6EAF858DB68C21ECEEF3F1726。[双次独立接收](validation/manual-complex-20261004/exports/baseline-01/receipt.json)与[KLayout 0.30.12 / raw record 回读](validation/manual-complex-20261004/baseline-gds-oracle-01/report.md)117 项通过：层次、紧凑阵列、变换、PATH 线宽/端型、TEXT 倍率及量化几何一致，TOP 边界仍为 80000×60000nm。格式中的上下文标记及六条上下文 SREF 单列，不计入21条业务记录。这里只资格化此 baseline 写出与独立回读；普通 UI 重开、OAS 和鸿图工程仍 pending。

532/533 尝试把锁定 L99/0 的 RECT16 宽改为81000，被原生服务明确拒绝；[533 document](validation/manual-complex-20261004/states/sdk06-locked-width-rejected-533/document.json)与531完整文档相同。SDK06 属性字段仍可输入的提示缺口和516可见标题字形只命中外框的失败现象保留；SDK09已在549/550和551/552分别具名复验通过，不再列为这两个病例的 pending。锁层允许点选本身符合既有选择合同。

523/527/537 的自动输入 JSON 出现尾部重复引号/右括号，保留失败证据并调查输入传输；不凭命令 ACK 认定输入成功，也未将原因归为产品。541 已通过普通输入恢复 TITLE 为 MANUAL_LAB，草稿 dirty=true；已保存 baseline 没有被覆盖。

SDK09 的549点击旧516坐标(1070,646)，实际草稿选中 TEXT19；550完整稳定 tree 的 MANUAL_LAB 字形范围包含该点，四个属性字段 enabled=true。551重选锁定 RECT16，552实际草稿与完整 tree 对应选区[16]、五字段 enabled=false及“矩形 · 属性 · 只读”。548/549即时 after-tree缺少app子树且截图右栏延迟，不授予属性UI资格。545→SDK09的546/548/549/552保留21条图元及全部业务字段（仅shape.selected另核）、Cell/layers/precision/dirty；revision26→1按正常恢复记录，不称字节identity。548/549/552相机offsetX仅差4ULP（3.638e-12nm），zoom/offsetY保持，普通→最大窗口世界中心差亦在1e-6nm容差内。复杂一般输入、实际文字提交、混合锁层及变换实例原生组合、普通格式重开与OAS/鸿图工程仍pending，完整功能/节点/专业组/phase/objective completion全部false。

## 历史 R19 与此前轮次（保留原文与原资格）

以下历史记录的版本、设备身份、通过/失败和未完成边界均按原轮次保留，不升级为 MC20 当前包验收。树中原有★亦维持其具名 source/HAP/target；新增 MC20 叶另写明时点。


R19已集成并复测四个实际修复：Cell选择器刷新、叠加context更新、工程恢复generation更新、数值初始化误报草稿。最终产品96ba99d，333生产/304工具，SDK03增量编译及E18 HAP实际安装通过。A独立mask95/95、全选/foreign命中与编辑隔离125/125；B真实保存/新ID重开/显式恢复/pending另存248/248；C捕获/完整预览/取消确认/安全撤销/实际XML及JSON导出回读、cold与导入通过；D本包0/1/2/32深度/KEEP/取消及跨文档重开通过，R18 apply/UndoRedo/双格式导出保持旧包范围。详见[R19验收](validation/parallel19-ordinary-abc/report.md)。原桌面已按最新用户要求启动PID25112，手机保持关闭；原桌面私有文档未访问。大文件架构/扩大压力继续延期，12节点/31专业组及专业whole A/B/C/D仍未标齐。

R18验收源码 b592db8，333生产/302工具共635文件。活动页签小manifest修补已合入，定向25/25与增量SDK通过；96CE HAP已实际安装于API24/2in1独立验收实例。常规小工作区冷开activeId与完整业务字段保持，revision2→1及完整字节身份差异保留。递归层表达式实际应用/撤销/重做通过，真实GDS/OAS导出经KLayout分别19/19通过。完整A/B/C/D流程仍待验；大文件模型重构及扩大模拟器压力测试延期。详见[常规功能验收](validation/parallel18-ordinary-ui/report.md)和[当前ledger](validation/parallel18-active-manifest/root-01/requirements-ledger.json)。

仍未全部补齐。继承12节点、31个完整功能组及全部历史叶子，wholeNodeComplete=false、wholeGroupComplete=false、objectiveComplete=false。第二批内存复测源码 cohort 为 `84b9f06bee650b57b3fba810f8bcaa6d80dba6c7`，333生产/301工具共634文件；增量SDK与运行器绑定前后稳定，HAP `0968DE16BA69F78C67268CA8C6C9E3B6DC0AD37CB0B160E46F99BA42265293A2` 已安装到本次15558独立实例。新增按需只读索引、共享checkpoint geometry、复用草稿编码/延迟回滚wire/一次图层计数。原PC5555仍保留EEF6及八份文档，不把新包资格移给原PC。

完整10万图形、20万点的活动pressure文档，图层、工具、dirty、选区、精确camera及相同Canvas bounds均保持。五份稳定态样本的HiDumper Total中位821880→773624KiB，即802.617→755.492MiB，减少47.125MiB（5.871%）；Total已经包含SwapPss。nonSwap中位268156→296247KiB上升，宿主VM private bytes也未下降，不能称物理RAM或模拟器整体内存已降低。两侧额外冷启动/切换历史不完全相同；严格20项保存状态比较19通过，非活动Main的workspace offsetX/Y变化一项失败保留；新包实际仍有THREAD_BLOCK_6S，不能称ANR已修。新旧raw、精确范围及开放项见[第二批记录](validation/parallel17-memory/second-batch/report.md)与[本批ledger](validation/parallel17-memory/second-batch/requirements-ledger.json)。

EEF6实际递归表达式预览/apply及GDS导出已有局部证据，但Redo选区失败、OAS紧凑阵列保真17/19失败均原样保留。本次源码已修KEEP事务选区回放和可表示OAS regular AREF，定向host及新SDK通过；旧0968包不扩大原生资格；96CE具名小fixture UndoRedo和实际双格式导出已通过，A/B/C/D完整流程仍待验。手机本轮已同UUID/配置/userdata恢复为API24 phone、PID70400并保持运行，最终回执见本批ledger。焦点跟随、手机/多窗口、绝对STRANS、动态派生依赖、跨工艺迁移、协作/附件及其它组缺口仍开放。

第一批历史资格：`cfe9eb089d3f9de4e84774a2981a7225a476504f`、333生产/294工具、EEF6 HAP与9入口392次host检查保持原范围；第一批实际100k Total中位677681→678520KiB未下降、strict camera失败不改写。原PC八文档EEF6首次及再次冷恢复通过，但fallback画面不授予GPU资格。旧Gate4/SDK4仍绑定7e6d445及021EB336…ED1D7，旧SDK3/restored generation3、180秒startup失败、各gate/preflight/编译/审计失败均保留。本次新增证据不重标历史原件；上次root-publication的七份文档已逐字节归档并由[历史解析映射](validation/parallel17-memory/second-batch/historical-current-01/resolution-map.json)保存原hash。

R16历史资格保留：最终SDK4与gate-run2均终态通过，313生产/263工具前后一致，同包D277E64D0FA57988D1843E6A40E2AA6B64835CC4B6FCB45C405A8960D9D3BB85；15个必选RDB阶段保留，review104、workspace105、transfer146、merge109、实际Index/文件121、Panel89具名host通过。API24/2in1模拟器实际导出两种策略的275/145条报告，经完整XML/KLayout回读与独立冷恢复核对；原报告和来源保持，原8版图全字段语义通过。该轮SDK3/gate1的编译通过与原生失败分别保留，所有R16证据均不替代R17当前包验收。

R15历史资格保留：SDK1与gate-run1同包02082871…45EDB，311生产/262工具稳定；指定135条继承、3条跳过、外部导出及独立冷恢复通过。1–3px边缘裁剪、5份早期缺App树捕获及未遍历的字段/拒写/迟到分支保留原记录。

## 当前结构与继承的历史叶

MC20 新叶按顶部证据边界另列；原有历史实现、资格和全部未完成合同保留，具名局部通过不升级为整功能/节点/专业组完成。

更新日期：2026-10-04。当前按用户要求优先完善功能和常规可用性，大文件模型大改及扩大模拟器性能压测延期；已核查的鸿蒙分块IO、随机访问和并发方案见[官方能力与取舍](validation/parallel17-memory/second-batch/harmony-large-file-options.md)。`●`已有实际源码；`★`仅具名回执绑定源码/包的局部范围；`◇`接线/回执/设备资格待完成；`△`功能缺口。继承的旧★仍绑定历史source/HAP/target；R17分支专项、根host、SDK与待验原生分别标明，不混用来源。历史通过不自动变成本轮原生验收，局部★不表示整个节点或功能组完成。

```text
鸿图 HongTu
├─ N01 工作台与导航
│  ├─ ● 顶栏、命令搜索、版图/验证/数据模块
│  ├─ ● 图层/Cell 侧栏、属性面板、主题和窗口适配
│  ├─ ★ MC20 SDK09具名属性UI：549旧516字形点实际选TEXT19，550四字段可编辑；551/552锁定RECT16仍可选、五字段disabled并显示只读；9/9独立证据检查仅此两叶及恢复，一般输入/混合锁层/全部变换原生组合仍pending
│  ├─ ★ MC20画布焦点：Sidebar进入UNIT后274 Ctrl+K实际打开Dialog；顶栏/定义条/面包屑对应当前编辑Cell，工程Top另保留；仅此普通入口，更多快捷键/手机焦点待验
│  ├─ ★ SDK16物理Tab：817→818→819实际键码2049与2047+2049完成候选0→1→0，选区16→59→16；画布键盘叶焦点、同版本7项候选及所有非选区文档字段保留，仅此具名双向病例
│  ├─ ★ R16四模式报告工作区：计数随新增/关闭刷新、11来源分两页选择/清空、已选第11项可达；窄短窗口四模式两行布局、合并预览/确认按钮完整可达，Back取消保持原数据；映射翻页与图片切换具名复验见N08
│  ├─ ★ 快捷键：组合键、单键、Space 助记码、Profile
│  │  └─ ★ Enter 提交、800ms 短码计时、弹窗/换文档保护
│  │     └─ ★ 无效尾字母取消已成立短码，避免误执行删除
│  ├─ ★ 快捷键修改/Profile/重置写后回读；拒写回滚、现有面板显示失败
│  ├─ ★ 视图预设原生选择/保存/应用/删除；写后回读、失败保留输入与原预设
│  ├─ ★ 撤销/重做按钮响应当前历史状态，创建与合并后原生按钮可用
│  ├─ ★ 同库多视图/克隆/书签及只读来源叠加纯核心：36 host；来源绑定、完整语义与CAS存储
│  │  ├─ ★ R13真实Index→服务→原生面板接线：同库视图克隆/切换/重命名/关闭，独立camera/Cell/深度/图层显隐；Index45/core43/Panel15限定回归
│  │  ├─ ★ R13书签保存/定位/重命名/覆盖/删除、同文档ID的JSON合并/替换导入及导出；私有文件CAS持久化与失败回滚
│  │  ├─ ★ SDK2原生改名即时显示R13-final/R13-book-final；确认框使用新名，连续覆盖显隐8→7→8通过；旧行/旧闭包失败保留
│  │  ├─ ★ SDK2实际系统Documents导出书签JSON→删除自建书签→合并导回；新书签及临时克隆最终清理，暖冷均为1主视图/0书签
│  │  └─ ◇ R13上述原生资格仅限同库视图/书签；R17另接实际多source renderer及工程显式迁移，不能由R13回执推定本轮通过；256旧文档清理仍缺
│  ├─ ● R17真实只读多来源叠加：现有视图面板从实际打开文档/稳定Cell选择来源，增删/重排/显隐/opacity/六系数仿射/独立layer-datatype掩码；持久视图与clone保持设置
│  │  ├─ ● Index被动读取活动数据库及非活动checkpoint，绑定真实root/选中Cell/已解码nm和完整来源样式；来源revision/数组/稳定键/关闭失效诊断，不临时切换活动editService
│  │  ├─ ● 同一ViewSceneSource[]驱动单surface原子GL发布；来源顺序及镜像/旋转/MAG/外部仿射保持，失败或全隐藏清旧场景；可见可达TEXT整场景进入有界ArkUI fallback
│  │  ├─ ● foreign绘制节点不命中，选择/属性/删除/snap/dirty/Undo仍只归活动数据库；碰撞Shape ID不授予外来编辑权，来源缺失不换名猜绑定
│  │  ├─ ★ A修复专项：core51/Index59/Panel53/scene43、独立负例6、native清理16及既有native29；2GDS+1OAS的15个来源/层XOR=0，只绑定三项修复交接中的源码与适配范围
│  │  ├─ ★ R19最终E18普通链：来源/Cell选择与连续添加、显隐/重排/opacity/六系数仿射/clone；70/20独立mask只改Main/S2一项95/95，全选仅当前TOP四对象、实际foreign BOX命中不选中且复制/删除/属性入口隔离125/125。关闭来源显示真实诊断；完整GL/TEXT像素、所有源更新/清场组合和工业规模仍开放
│  │  ├─ ★ R17-M01内存局部：document/scene同步边界与draw失败释放旧ArkUI派生primitives；保留camera cache-hit、TEXT limit探测及atomic拒绝，未改迟到GL callback协议。cfe9新scene43/Index59与原分支生命周期12分别具名；同scene fallback→GL释放、双draw和inactive checkpoint大副本仍开放
│  │  ├─ ★ R17-M02内存局部：native全局单调publication token在既有mutex内复用完整CPU帧，异producer/clear/失败/renderer替换失效，context重建只补一次上传；cfe9 publication30、NAPI33/KLayout15、review16及actual plugin clear通过；50万矩形三项计数为同cfe9强制重准备baseline vs publication复用，不是old/new-source实测对比，只限host分配/调用与几何，不是设备PSS/GPU验收
│  │  ├─ ★ R17-M04内存局部：两个只读renderer builder延迟RTree完整构造，Point/Range/Nearest首次查询才建立，五个编辑/导入/比较入口保留Immediate；1583 host断言、72场景、actual NAPI33/KLayout15及独立源码复核绑定A交接，100k三次host RSS中位79144→66144KiB，不是设备PSS或整个软件下降
│  │  └─ ◇ Gate4的7e历史A五个必选阶段已具名通过，仍不替代本轮HAP的GL像素、ArkUI TEXT完整变换、源更新/关闭/全隐藏、交互及暖冷原生验收；超预算整体拒绝，hatch/dash/动画等实际限制明确提示
│  ├─ ● R17工程按稳定Cell键显式旧→新documentId映射恢复视图/书签/只读来源；外来数据库必须实际载入，不嵌入其几何、不按文件名/Cell名猜测，具体绑定和事务见N03
│  ├─ ● 既有比较差异 Path overlay、图层筛选、定位及版本失效保留；不等于多数据库叠加
│  └─ △ C01整体仍未闭合；显式点击定位不等于焦点跟随，旧视图库治理、共享模型未暴露的绝对STRANS MAG/角度标志、手机/多窗口/物理设备及全部组合/更广规模仍开放
├─ N02 文档与格式
│  ├─ ● 新建、打开向导、最近文件、查看/编辑模式
│  ├─ ● GDSII/OASIS 读写、重开；CIF/DXF 子集读取
│  ├─ ★ MC20 baseline GDS514普通另存、双次接收及KLayout/raw回读117项通过：2782bytes、21业务记录与3压缩AREF保持；资格绑定SDK06具名baseline，SDK09正常恢复不当作GDS文件重开
│  │  └─ ◇ MC20普通UI baseline重开、final GDS/OAS/鸿图工程保存→独立回读→重开仍pending；472的18记录历史及其它格式★保持原cohort，不由SDK09两个属性小叶扩展格式资格
│  ├─ ★ CIF/DXF 最近标签和沙箱格式共享检测；旧错误标签按路径修正（第十轮原范围）
│  ├─ ● CIF/DXF完整独立native parse job、阶段进度/取消；文本格式不再请求不支持的quickScan
│  │  └─ ★ 主打开/最近页代次+文档+版本保护77正式actual-method/controlled-worker回归；旧失败保留；第十一轮gate4的host/编译范围通过，主导入原生异步交互仍待验
│  ├─ ★ OASIS PROPERTY 规范名称/modal、GDS 属性编号桥接、有类型属性往返
│  │  └─ ★ R17 regular AREF保真修补：可表示的2D带符号/skew regular repetition及合法一维单条PLACEMENT往返保持次数/向量/原SREF；不可表示的1D/1×1/零向量等明确拒写，保留GDS。writer47/reader201/独立44及实际GDS→host OAS oracle18通过；旧0968包资格不变；96CE普通PATH/SREF/2×2AREF实际GDS/OAS导出分别19/19通过，更广格式拒绝仍待验，旧EEF6 OAS17/19失败保留
│  ├─ ● SVG/PNG 导出、DBU 量化检查、安全发布
│  ├─ ★ LYP/工程文本有界循环读取、完整性与 BOM 处理
│  ├─ ★ 宏/Python 文件有界短读拼接、长度变化拒绝；比较 B URI 格式及失败缓存清理
│  ├─ ★ structured GDS/native 保存契约以权威 Cell ID 名表生成 SNAME；缺名/旧名引用不产生 ghost Cell
│  ├─ ★ typed Port/CrossSection 与有序原始 context：本批原生 GDS/OASIS、ArkTS GDS 回退及固定版本 KF/gf 夹具互通
│  │  └─ ★ 稳定 Cell/Port 身份、完整方向/镜像/MAG、未知载体保真；冲突拒绝、截面及预算实际回读通过，未知schema保真不等于第三方可消费
│  │     └─ ★ R12：重复写入在原位置替换已知适配器，保留未知context字节及相对顺序；原生GDS/OASIS各三次保存后由KLayout读取，70项局部oracle通过
│  ├─ ★ 导入合并服务：nm 保真、层/用途 map/drop、Cell rename/严格 reuse、引用与属性、一批撤销
│  │  ├─ ★ 合并导入原生文件选择与映射界面：独立完整解析，不覆盖当前 native 缓存
│  │  └─ ★ 根依赖闭包、双预览、参数/文档失效保护；真实原生回包/保存夹具核验
│  └─ △ 其它导入映射选项及保存/规模验收（C04）、LEF/DEF（C14）、目标制造格式（C30）
├─ N03 工作区与工程
│  ├─ ● 多文档标签、独立编辑会话、关闭和恢复
│  │  ├─ ★ R17-M05内存局部：document/session两个冻结checkpoint共享一次校验后的geometry；活动编辑及恢复仍独立克隆，history/clipboard不共享可变几何。checkpoint host11与相关六套250检查有具名分支来源，不能推定cold-init heap下降
│  │  ├─ ★ R17-M06内存局部：私有WeakMap发行prepared draft并复用完整编码，各次显式保存保持独立FIFO；正常激活不再提前转换旧wire，失败才重建完整旧文档；图层计数O(N+L)保留顺序/样式/raw undefined-D旧语义。最终root 100k完整保存/切换/历史/拒绝回滚12及兼容10通过，新SDK634文件稳定；pending队列和冷恢复其它分配、last-active持久化及ANR仍待定位
│  │  └─ ★ 活动页签恢复修补：成功切换立即按FIFO发布小manifest，使用执行时最新diskTabs/history；开放状态在开始与rename前复查，generation/ticket防迟到提示；root最终635源码定向25/25及SDK通过。不复制geometry、不截断或合并完整草稿；96CE小工作区cold activeId/完整业务字段有限通过，revision2→1及完整字节身份差异保留；更广拒绝/迟到/豁免库待验，旧0968 ANR仍开放
│  ├─ ★ 工程保存/另存、取消保护、保留原文件
│  ├─ ★ R12：无变化捕获保留旧文档engineering/precision/navigationPath/layerDefinitions缺失状态；显式空值原样保留
│  │  ├─ ★ 按激活时工具基线判断真实变化；全局模板/其它文档宏/既有PCell标记不凭空创建工程包
│  │  ├─ ★ 工程保存取消、拒写或等待后失效不提前发布工具包/所有权；导入工具仍需显式恢复
│  │  └─ ★ 46项actual-method/真实host磁盘回归通过；第十二轮包指定原生无操作面板/旧标签往返及四阶段原8暖冷复验通过
│  ├─ ★ 标签切换恢复工艺/规则/脚本草稿；存储失败先回滚
│  ├─ ★ 保存器等待后核对几何/工具/视图内容，过期快照不写目标
│  ├─ ★ 显式恢复跨 Python/宏/工艺/规则回滚；重复恢复不复制文档宏
│  ├─ ★ 切文档宏保存失败回滚原生/工具；原生拒绝保留原文档待录制内容
│  ├─ ★ 工程宏先按来源文档过滤，再检查该文档容量；其他文档宏不阻断保存
│  ├─ ★ 导入/Clip 与工作区结构一次事务；外部结构回调失败恢复几何/历史/ID/dirty
│  │  └─ ★ 结构历史恢复图层集合与计数；保留用户已有空层及随后修改的显隐/颜色
│  ├─ ● 版本副本、自动草稿、安全写入、dirty 状态
│  ├─ ★ MC20纯选择autosave：SDK04 348[]→349 PAD#9[9]→350普通应用重开仍[9]、Cell[0,3]；12物理记录/5定义/precision/dirty保持，revision重置且offsets变化，不声明全字节相同
│  │  ├─ ★ MC20定义路径autosave重测：SDK04 361 NAV_EMPTY[0,5]→362 TILE[0,2]失败保留；SDK05 366→367保持[0,5]及12记录/6定义，空定义恢复此病例通过
│  │  └─ ◇ 已保存7nav+7selection host仅抽取Index/Sidebar/monitor、虚拟时钟与真实独立viewstore/codec读回；不是完整EntryAbility启动，具体SREF/AREF导航路径及SDK05单选重开未全验
│  ├─ ★ R15报告工作区v2：每报告source/URI/current/saved/dirty及filter/page/selected/frame/待定frameTarget独立；v1迁移、聚合预算、CAS后发布
│  │  └─ ★ SDK1三报告冷启动字节一致；source第137条/TOP待选路径与target第100条/独立页码恢复，关闭自建两报告后旧报告暖冷保持；预算/拒写等限定host
│  ├─ ● R16生成报告pendingExport独立恢复：首次真实另存前保持dirty，导航/审阅/clone/冷恢复不误清除；合并追加与来源快照/CAS绑定
│  │  └─ ★ review104/workspace105/Index121限定host；合并/继承/脏报告关闭/重载消费一次性确认；原生返回取消创建、取消脏关闭/保存保持、新生成dirty冷恢复、两策略实际保存后clean冷恢复通过；迟到/拒写更广原生分支仍待验
│  ├─ ★ R16最终原生关闭本轮测试报告后仅保留旧报告；暖冷会话字节一致、serial13不重置，原8版图全字段语义保持，仅允许记录的时间/文件bookkeeping变化
│  ├─ ★ R12：文档本地Python草稿/待保存标志独立持久化；GDS保存保留脚本dirty，关闭时保存鸿图工程
│  │  ├─ ★ 工程导出在副本合并草稿并重建校验；保留未授权外来工程包，重新导入不继承本地所有权
│  │  ├─ ★ 恢复确认同时核对脚本/模板/宏/规则/工艺上下文；纯检查不创建默认存储
│  │  └─ ★ 返回退出确认绑定脚本/工具/页面版本，拒绝旧保存回包；41保存/关闭/返回、33恢复、22页面生命周期、10存储局部host通过
│  ├─ ★ Workspace v2 五项语义字段、v1/器件库持久迁移与失败回滚：38项实际host通过
│  │  └─ ★ DE7原8标签全内容/顺序/active/选区/camera/稳定五字段warm+cold精确恢复；实际Undo/deselect清理，无沙箱回写
│  ├─ ★ 本地工艺独立所有权及完整DRC配置持久化/激活/历史；保留旧工程Python/宏/PCell/资源，外部导入清除本地恢复所有权
│  │  ├─ ★ 强制恢复15项/59类损坏快照及11个相关脚本通过；全关闭规则真实保存/UndoRedo/独立磁盘重载/工程往返保留
│  │  └─ ★ C07B原8文档内容/顺序/active/选区/camera/五字段暖冷恢复精确通过；绑定临时工艺后的原生冷启动另待验
│  ├─ ★ R13视图切换按真实图层集合协调：保留新层当前显隐、删除层不复活；纯视图同步保留dirty及编辑历史，限定Index/core回归
│  │  ├─ ★ 关闭/重开/页面退出撤销旧picker ticket，持久化失败阻止切文档或关闭；实际系统迟到/拒写专项仍待验
│  │  └─ ★ SDK2临时视图/书签清理后原8文档暖冷全字段精确一致；视图库暖冷字节一致；不等于工程内携带或跨新ID迁移
│  │     └─ ◇ 上句保持R13 SDK2历史资格；R17工程携带/跨新ID迁移另列实现和新来源，不用该旧回执替代
│  ├─ ● R17工程v2携带完整有序视图/书签/只读叠加与来源引用、多报告current/saved XML/筛选/页码/选中/frameTarget/frame/pendingExport、持久布局绑定；图片/值/标签原XML字节保留
│  │  ├─ ● 现有工程保存/另存与工具恢复入口接真实B载体和原生恢复面板：主来源固定、外部来源显式映射、替换目标视图需显式选择；旧v1及缺失/null/空资格保留，未恢复外来包不取得本地所有权
│  │  ├─ ● View/C/report/layoutMappings及B历史receipt共用IntegratedWorkspaceCoordinator一个完整outer CAS；已有outer优先，损坏阻断不回退旧文件，冷启动读当前slots不重播旧receipt覆盖后续普通编辑
│  │  ├─ ● prepare/cancel无持久发布；confirm前复查页/工具/实际来源/完整视图报告及定位，单次B forward CAS后同步采用；Python/宏/工艺/规则/视图/报告/旧core/marker overlay逐域checkpoint回滚，失败blocked直到显式重读
│  │  ├─ ● confirm返回true后才授予本地ownership、markDirty/revision/分析失效及普通映射rebase；历史receipt仍保持原字节，不将普通slot CAS误计为第二次B forward事务
│  │  ├─ ★ R19最终E18真实.hongtu保存→新ID重开→显式映射/replaceViews→确认恢复：两视图/书签/overlay、四报告完整XML和pending保真，旧四份保留并生成新四份；取消另存不发布，仅新report8实际保存清pending并赋URI；248/248，shared cold不重播历史receipt。旧Builder阻断及未确认恢复失败仍保留
│  │  ├─ ★ Gate4的7e历史来源carry47/完整XML-KLayout68、重复布局绑定26/bridge46、B恢复面板24及类型检查0 errors；根物理文件18/coordinator21/映射面板25（含原24）/实际Index31均通过，只资格具名源码/磁盘/适配范围；旧专项回执另保留
│  │  └─ ◇ Gate4+独立SDK4只资格7e历史来源，不继承到cfe9；同包实际工程另存/导入/映射/替换/确认取消/失败四业务流程仍pending完整业务UI，原PC 8文档暖冷及回滚后暖冷已有单列资格；全局豁免库与应用所有权不随工程携带
│  └─ △ 工程缓存治理、依赖版本核验及更多设计数据
├─ N04 画布、绘图与测量
│  ├─ ● OpenGL 主渲染/ArkUI 回退、层级裁剪和 LOD
│  ├─ ★ MC20 TEXT选择：278唯一UNIT字形加蓝轮廓/锚点，scene-provider正文只绘一次；正常TEXT fallback清空常规renderError，保留真实错误；279旧空selection草稿不否定278实时选中
│  ├─ ★ MC20 cutoff/Fit：SDK03 depth1/2停止引用保留非空bounds/框，depth3此两层3×2 AREF展开；290隐藏L10仍有原生可见几何、293恢复有序TEXT fallback；全部深度/变换/像素/规模仍开放
│  ├─ ● 平移/缩放/适配、预设、网格、测量和标尺
│  ├─ ★ MC20世界中心：SDK04/05三组普通应用重开349→350、354→355、366→367按真实XComponent/1.9取整中心保持；最大轴差9.095e-13 DBU，数值容差与取整分辨率另列
│  ├─ ★ SDK06窗口428→429→432：普通470×477vp→最大1012×772vp→还原470×477vp，中心(32000,34150)nm/zoom1.7294%/选区[15]/几何/Cell/precision/dirty保持；offsets随尺寸补偿，原生parser113项仅资格这三态
│  ├─ ★ SDK06原生小叶448：TOP RECT16 L99/0 (0,0)..(80000,60000)nm，属性及Fit80000×60000、1图形/2停止框、zoom1.0867%；精确边界此病例，不授予N04整体完成
│  ├─ ● 矩形/多边形/PATH/文本、圆/椭圆/环/弧
│  ├─ ★ 顶点拖动遵守吸附开关、允许类型和绘制步长
│  ├─ ★ 两点 RECT 规范角映射；保留合法分数 nm 坐标
│  ├─ ★ RECT 跨角保持初始对角锚点；顶点手势核对版本/Cell/选区
│  ├─ ★ 普通拖动、长按微调与连续绘制草稿核对版本/Cell/选区/目标层
│  ├─ ★ 大坐标下分数 nm 轮廓面积使用局部原点，顶点/圆角不再误拒合法图形
│  ├─ ★ DE7定义端口方向/孔径覆盖点选对应管理对象；具体实例Copy/Connect所选原生链通过，非全深路径/规模验收
│  │  └─ ★ port-only Fit/重置/导入居中、完整孔径与符号AREF范围：19项服务/实际Index方法通过；失败保留camera，最小缩放明确提示，非19项原生运行
│  ├─ ★ 电气折线端口布线：明确配对/途经点、连续材料避障、异宽束线、真实蛇形长度、多层材料/明确渐变/单工艺过孔
│  │  └─ ★ 当前规划44/障碍37/事务93/保存21/界面72、束线oracle66；旧91D9原窗口单线preview/参数失效/apply/UndoRedo通过；C07B原生重跑及其它束线/渐变/via/深路径另待验
│  ├─ ★ 真实光学曲线路由：line/circle/euler primitives；圆弯6 Dubins、Euler4 CSC、平行切向S弯
│  │  ├─ ★ 实测曲率半径、连续弧长/采样误差、明确DBU/端面容差、四弯meander目标长度、光学异宽等长和电气/光学混合束线
│  │  ├─ ★ core73/KLayout120/新编原生GDS-OAS往返112/Session93/独立Session185；旧91D9指定原窗口三模式预览、半径必填/失效、Euler应用及一次UndoRedo/增量清理通过；C07B原生重跑另待验
│  │  └─ △ Euler CCC、分段光学via/任意PDK过渡、全局搜索完整性及更广原生/设计/规模
│  ├─ ★ 物理层栈实际triangles按每像素深度显示；真实截面；完整模型超预算明确拒绝、不抽样截断
│  └─ △ 图像配准（C17）、自由曲线编辑（C19）、完整光学/动态截面体系（C21/23）
├─ N05 选择、编辑与历史
│  ├─ ● 点选/多选/框选、重叠候选、搜索与定位
│  ├─ ★ 仅改选区保留验证结果；实际编辑使结果失效
│  ├─ ★ 查看模式微移保护、微移/改层混锁整批拒绝、空事务保留 redo
│  ├─ ★ 混锁删除明确跳过、同步选区计数、只录制已删除对象
│  ├─ ● 属性、移动/复制/阵列、旋转/镜像/缩放、对齐/分布
│  ├─ ★ 数值属性完整解析；偏移保留 layer/datatype/属性
│  ├─ ★ MC20 PAD精确BOX/接触/标签：332 PAD9 2000×2000nm、PAD10 600×600nm、TEXT11 PAD@(-600,600)；320负宽-1原子拒绝，318/321完整document字节不变；仅这些具名小叶，更多字段/历史待验
│  ├─ ★ 长按微调失败保留弹窗与输入，禁止过期选区提交
│  ├─ ● 对象布尔、输出层、保留原图、尺寸偏移
│  │  └─ ★ MC20尺寸调整选区修补：结果选择纳入完整结构事务，宿主几何50/编辑闭合16项通过；修前原生Apply空选区/Redo选中77负例保留，修后原生仍待验
│  ├─ ★ 当前 Cell 全层表达式：精确用途/显式通配、括号/运算优先级、独立区域合并、DBU 量化与无洞输出
│  │  ├─ ★ 搜索命令原生入口、来源/结果预览、一次撤销、过期/锁层/预算保护
│  │  ├─ ★ 派生来源属性经真实 ArkTS GDS 写出/KLayout 空间与属性回读
│  │  ├─ ★ PATH 真实区域：折线合并、负 WIDTH/MAG、端帽与 TYPE4 扩展、分数 DBU
│  │  └─ ◇ 上述当前Cell/ArkTS GDS历史资格保留；R17已另接递归与真实native GDS/OAS回读，圆端离散误差仍显式提示，不据旧叶子推出新包验收
│  ├─ ● R17递归全层表达式：任意整数0–32子层，whole-layer精确用途/显式通配、四种Boolean、SREF/AREF及嵌套旋转/镜像/MAG；按展开路径拒绝循环/缺Cell/非法变换，深度外明确不展开
│  │  ├─ ● RECT/POLYGON/PATH实际世界坐标源预览；PATH 0/1/2/4端型、负WIDTH与TYPE4延伸/DBU量化；递归强制keepSources，输出当前Cell并保留共享定义/端口/来源语义
│  │  ├─ ● Index实际prepare传完整cellStructureState、cancel撤销准确generation；应用一次结构事务，源/参数/版本失效与外部回调失败回滚。KEEP事务记录before/after选区，UndoRedo保持primary/raw IDs/flags-only差异及有效ID裁剪；普通创建Redo仍按既有规则选新输出。root真实region/PATH host47与transaction oracle45通过；旧0968未授予新资格，旧EEF6 Redo选区失败保留
│  │  ├─ ★ 96CE普通小版图：PATH/SREF/2×2AREF，深度1、KEEP=true，1/0|2/3→126/6；5源+5输出，面积14725000nm²。canonical [5]/[5]的apply10/Undo5/Redo10，raw145/145及四画面primary32/32通过；实际GDS/OAS导出各19/19。R19 E18另验depth0/1/2/32、非零KEEP强制选中/禁用、取消及跨文档重开清空预览，七文档业务和dirty保持；未把旧包apply/export资格迁给E18。更多迟到闭包/规模及完整D仍开放
│  │  ├─ ★ Gate4的7e历史D六个必选阶段实际完成：fresh region/PATH/native构建、真实层次fixture、当前服务host92（含31真实GDS/OAS导入/提交/UndoRedo）及独立保存oracle39；旧全层48/PATH28保留。30精确场景XOR=0，圆端非零误差按6DBU双向包络核验，生成来源属性真实四向roundtrip
│  │  └─ ◇ 原始负WIDTH/圆端PATH保存OAS及部分typed属性保存GDS仍有明确格式拒绝；有界同步计算的取消丢弃预览，不能中断正在执行的UI原生调用；15558旧SDK4已具名通过深度1预览/apply，更多深度切换/窄窗/UndoRedo/export及新内存包完整业务仍待验
│  ├─ △ C06动态派生依赖、跨重新导入动态身份、32子层外/绝对STRANS标志、全部运算组合与工业规模未闭合；静态来源属性不是动态依赖图
│  ├─ ★ 原生检查发现预览更新绑定遗漏；布尔/全层预览改用响应式组件传参
│  ├─ ★ 倒圆角：真实圆弧、半径/误差/顶点数确认、过期保护、撤销
│  ├─ ● 顶点插删、几何有效性、事务撤销/重做
│  ├─ ★ 端口增改删/密封预览/结构历史：DE7实际CRUD/UndoRedo/非法输入与过期预览拒绝通过
│  │  ├─ ★ Copy/Delete响应启用：列表选择Delete及实例Copy实际通过；旧高亮但禁用反例原样归档
│  │  └─ ★ 实例Copy完整frame/独立ID及UndoRedo；Connect所选直接SREF only/共享另一实例不变、37度offgrid拒绝与参数/query失效通过
│  ├─ ★ 删除及结构事务撤销恢复真实图元顺序、命中与保存基线；纯重排也标记 dirty
│  ├─ ★ 带洞区域分裂保持微小三角材料；大坐标 0.25nm frame 真实 KLayout XOR=0
│  ├─ ★ 固定起点区域 Fill：矩形/直接选中面积、完整 Cell footprint、行列 lattice、margin/spacing 与材料避让
│  │  ├─ ★ 实际 region/PATH 引擎、连续包含/避让、共享 SREF/AREF；全库预检、DBU/属性/锁层与预算
│  │  ├─ ★ 参数/双预览/一次结构历史接线；43host/5fallback GDS-KLayout；新BD1F包指定1/0原生70实例/11引用/240候选/108外/62避让，history exact
│  │  └─ △ 增强/多起点/第二阶 Fill、glue-box/密度/最优 packing、更多递归区域、字体/不确定 PATH 与异步规模验收（C05）
│  └─ △ Clip 跨后端/规模验收（C03）、递归全层运算剩余合同/完整递归查询（C06/08）、倒角/制造分裂（C18）、mesh/stretch（C20/31）
├─ N06 Cell、层级与器件
│  ├─ ● Cell 树、进入/返回、面包屑、新建/重命名/删除保护
│  ├─ ★ MC20定义导航修复：Sidebar进入共享定义使用规范Cell栈，TOP[0]/PAD[0,3]具名原生通过，当前编辑范围/面包屑不混工程Top；旧188/192循环失败保留，具体多父/实例路径全部组合未闭合
│  ├─ ● SREF/AREF、实例变换、阵列成员、独立变体、打平预览
│  ├─ ★ 2026-10-06普通UI具名HIER core：TILE3×2 / TOP2×3斜向压缩AREF与R90 / X镜像 / MAG1.5单UNIT，3定义/5记录/37UNIT/74叶；两用途whole Region XOR0、原UNIT/manual保持；depth3/Fit整体可见。PATH/TEXT/PAD、共享修改/局部隔离及三图88项仍待验
│  ├─ ★ MC20普通UI物理层次截至472：6定义/18记录；AREF7 UNIT3×2、AREF8 TILE3×2、AREF15 PAD5×2压缩为3条；UNIT变换SREF13/14与TOP右侧TILE SREF17/18共4条SREF，非屏幕展开数
│  ├─ ★ SDK06原生小叶463：TOP TILE17@(62000,18000)、rotation90/mirror0/MAG1，属性/状态/停止框与实际草稿一致，物理记录16→17
│  ├─ ★ SDK06原生小叶472：TOP TILE18@(62000,38000)、rotation270/mirror1(X)/MAG1，属性/状态/停止框与草稿一致，物理记录17→18；完整展开像素/共享影响/其它变换及格式回读仍pending
│  ├─ ★ 选区组成 Cell：保留坐标/属性/引用、预算检查、结构撤销
│  ├─ ● 内置 PCell、参数生成、重编辑、个人器件库
│  ├─ ★ PCell 重生成先核对替换后整库图元/顶点预算，拒绝不改变历史或 ID
│  ├─ ★ 层级 Clip 规划服务：保留全内引用，部分生成独立变体；旋转/镜像/MAG/斜向 AREF、全库预检与预算
│  │  ├─ ★ 层级 Clip 原生参数/双预览/提交入口、实际区域 adapter 与部分 PATH 裁剪
│  │  └─ ★ 保留源库、完整共享引用与独立输出；4 组真实 GDS/KLayout 保存回读、一次撤销/重做
│  │     └─ ★ 新Clip定义改保存静态几何与完整PCell来源；原共享定义保持可重生，30规划/22会话/48组合host/50KLayout通过
│  ├─ ★ 工艺器件选择、默认参数/模型；工程/GDS/OASIS 标记/个人库保持身份
│  ├─ ★ 手动 Cell 原点调整：全部父 placement 补偿、累计 Cell frame 属性与 PCell 坐标系重生
│  ├─ ★ selected/global 实例重链接、roots/preserve 不可达库清理；owner/ref/Cell 属性/导航共同重编号
│  │  ├─ ★ 密封预览、完整元数据与一次Undo/Redo；当前48项host/50项KLayout，旧40/42证据保留
│  │  └─ ★ prune名单改State、Dialog20；BD1F原点100/-200、relink实例44 2→1、prune真实CELL_2名单/33→32shape3→2Cell，全history exact
│  ├─ ★ 通用Cell端口、SREF/AREF/深路径及隔离：旧批core53/KLayout17/原完整gate通过；深路径原生资格不扩大
│  │  ├─ ★ 管理/连接dialog与响应启用：第八轮DE7实际CRUD/实例复制/所选SREF连接及完整历史通过
│  │  ├─ ★ 完整定义先检索再限显示、definition/instance scope、双端查询、preferred端点及真实修改对象预览：4002端口夹具与31项方法host通过
│  │  ├─ ★ 无匹配子树剪枝/即时DFS；巨大AREF用代表成员及明确边的行列选择，任意深路径/全成员和100000端口延迟未获验收
│  │  ├─ ★ Clip/Fill/导入/打平/原点/重生成同步语义；内置MOSFET生成真实G/SD独立接口，非完整组件工厂
│  │  └─ ★ PCell有界整页Scroll/固定footer：原矮窗口未放大，实际到达X/Y并放置MOSFET_1五端口；实际Undo清除自建变体/端口/标记并恢复原UUID
│  └─ △ 自动bbox原点/向上移动/更多库与代理/规模（C07）、完整组件工厂（C15）、通用端口更多版本/深路径/规模（C22）、完整光学/PDK布线（C21）、设计端口网络（C24）、层栈拓扑重网格/工艺物理（C25）、测试芯片（C29）
├─ N07 图层与工艺
│  ├─ ● layer/datatype、计数、显示/选择/锁定、颜色/线型/填充
│  ├─ ★ SDK06原生小叶454：L99/0 fillStyle=outline、locked=true，边界退为可见轮廓并提示已锁定，454/472实际草稿保持；不将样式/锁定状态当作全部锁层拒绝/LYP往返通过
│  ├─ ★ LYP 有界导入/导出，短读不接收前缀配置
│  ├─ ★ 视图预设按精确用途保存；存储拒写/异常/回读不一致回滚，删除不改当前显隐
│  ├─ ● 工艺包绑定/移除、via、用途、规则、PDK/deck 关联
│  │  └─ ★ 工艺绑定/移除后层栈入口使用响应式状态；实际原生绑定后可进入
│  ├─ ★ 器件参数优先级：内置默认 → 工艺默认 → 用户输入
│  │  └─ ★ 未知参数、类型、范围与不可信模型标记校验
│  ├─ ★ 工艺器件身份入口拒绝 NUL，避免接受后无法进入工程保存
│  ├─ ★ 明确截面材料执行：多层固定 width/offset、完整 mirror/MAG、已支持外部截面、明确 taper/主层单via
│  │  └─ ★ 材料模块定向 43 / KLayout 54 / 当前 native 保存 52；不代替完整路由与工艺资格验收
│  ├─ ★ 曲线CrossSection：真实法向width/offset、mirror/MAG、实际半径、连续弧长taper、primary真bbox及全部辅助材料
│  │  └─ △ 动态width/offset函数、insets、section端口、沿线组件、完整工厂/多级过渡（C23）
│  ├─ ★ 限定可执行物理LayerStack：材料/layer/datatype、nm/um、z/厚度/meshOrder、派生/背景、侧壁/bias/zToBias
│  │  ├─ ★ 真实grow/etch掩模与z范围、完整层级/阵列、ROI裁切、分段闭合triangles、实测体积和有限截线
│  │  ├─ ★ OBJ/截面JSON/完整几何导出及空间provenance；未知schema惰性保留、pending字段保存、上下文失效与异步picker保护
│  │  ├─ ★ core33/KLayout18/Panel32/工艺历史9/实际LYP历史14/Geometry16/本地恢复15；工艺一次历史保留随后独立规则与名称/颜色
│  │  ├─ ★ C07B实际完整JSON输入、真实截面/3D旋转、无效厚度拒绝/预览失效、保存及UndoRedo；仅撤销核实的两次自建工艺事务
│  │  ├─ ★ OBJ/截面JSON/完整几何实际系统picker保存及应用成功反馈；◇共享Documents权限拒绝，独立文件字节/几何回读仍pending
│  │  └─ △ 拓扑变化remesh、外表面融合/内部cap消除、工艺物理/求解器/foundry资格；slab面积不是全栈外表面积
│  └─ △ 层视图表达式（C02）、可执行PDK组件/资源映射（C13）、完整工艺与物理层栈分支（C25）
├─ N08 检查与验证
│  ├─ ● 内置规则、编辑快照、范围、后台进度/取消和预算
│  ├─ ★ DRC 展示截断仍统计命中，明确 OUTPUT/EXEC 不完整
│  ├─ ★ 同步分块 spacing halo/去重，density 保持全设计窗口
│  ├─ ★ 同步 density 修复重叠面积重复计数；RECT 精确合并，复杂几何按真实 DBU 原生区域
│  │  └─ ★ 原生失败/预算/量化精度未证明标记 EXEC 不完整，禁止误判绿色通过
│  ├─ ★ 规则/范围配置立即失效；旧作业停止后按新配置重新检查
│  ├─ ★ DRC 清单 0–32767 层/用途；工程/工艺恢复保留 canonical 目标层用途
│  ├─ ● 结果过滤、位置标记、网络提取/追踪、SPICE 导出
│  ├─ ★ SUBCKT 参数/注释解析；同名网按 ID 定位
│  ├─ ★ 用户 N$ 标签保持命名身份、首标签与副标签；fallback 区分精确 datatype
│  ├─ ★ 实例网络使用根坐标范围定位，反馈真实可选成员
│  ├─ ★ 几何/参考网表变化使旧结论失效；报告导出检查版本
│  ├─ ★ 层级深度变化清除旧 LVS/网络；保存器等待后拒绝过期报告
│  │  └─ ★ R13同Cell不同depth视图/书签事务成功后清旧分析，失败回滚保留原分析；Index45限定host，原生depth/网络专项仍待验
│  ├─ ● 电脑注册工艺 DRC/LVS（有外部依赖与资格边界）
│  ├─ ★ LVS 同名断网归为 open；畸形/未支持网表拒绝伪 pass；SPICE/CDL 导出拒绝注入标签/不完整提取
│  ├─ ★ DRC 定位按真实 ruleId；旧无 ID 同名歧义拒绝；电脑回包核对工艺/deck/Cell/完整性与报告一致性
│  ├─ ★ 标准.lyrdb纯核心：category/cell/item、八类typed值、XML/单位、引用frame/query与完整预算拒绝
│  │  ├─ ★ 154 actual host / 13真实KLayout文件 / 69独立对抗；仅当前纯核心source一致范围
│  │  ├─ ● 当前published DRC原文档/Cell/frame导RDB；picker前后核结果来源/页代次/版本
│  │  │  └─ ◇ 第十一轮gate4的Index RDB41方法/IO检查通过；24C75原包不完整DRC的RDB系统导出/失效禁用通过，独立外部字节仍待验
│  │  ├─ ★ R14单报告：二级菜单/命令→Index→实际文件选择器；Open/Reload/Save As，当前有效DRC入口另有host资格
│  │  ├─ ★ 分类/精确Cell并集、标签/文本/查看/豁免/重要状态组合及排序；完整分页、任意原编号、全部values分页
│  │  ├─ ★ comment/visited/system waived/important单条编辑、保存/取消和草稿保护；精确次数统计；豁免不改变DRC通过状态
│  │  ├─ ★ 明确报告目标Cell/具体引用frame/布局稳定Cell绑定；镜像旋转MAG定位与真实marker覆盖，失败恢复原视图且不重载几何
│  │  ├─ ★ box/edge/edge-pair/孔洞polygon/PATH轮廓/label锚点规划；190项几何及30项实际Canvas检查，label未测原字体字形范围
│  │  ├─ ● 有界嵌入图片显示与失败保护；SDK3/4白色1px夹具的Image节点不作为全格式解码或全尺寸图片管理验收
│  │  ├─ ★ 独立报告current/saved恢复与CAS后发布，目录/锁校验、旧picker/页面隔离；已保存审阅冷恢复，未提交输入仅内存草稿
│  │  ├─ ★ SDK3真实137项报告导出；独立读取外部文件并经KLayout/完整XML核对，只允许指定单项审阅变更；SDK4重载另有回执
│  │  ├─ ● R15多报告：追加打开/当前DRC、stable ID与完整列表；独立报告导航、指定保存/重载/关闭；非活动操作及dirty/最后关闭等有具名host
│  │  ├─ ★ 完整Cell/分类/有序typed values/value-tags/reference匹配；全目标预览，重复共识/覆盖/跳过显式策略；真实KLayout对照146项且记录行为差异
│  │  ├─ ★ 六字段审阅继承及附件长度摘要；系统waived与用户#waived并存，只改目标允许字段；保存基线/声明保护、配置改变撤销旧确认
│  │  ├─ ★ SDK1原生：追加后3报告，预览7/7页及末条138，默认歧义禁用应用，显式跳过后135更新/3保持，实际系统另存并经KLayout/完整XML回读
│  │  ├─ ★ SDK1独立页码/选中项/待定TOP路径冷恢复；仅关闭本轮2报告，legacy与原8版图暖冷保持；具名dirty7/clean8/cold8独立核验
│  │  ├─ ◇ 六字段全部组合、非活动保存/重载、dirty/最后关闭、迟到确认、拒写和规模的更广原生专项未完成；1–3px边缘裁剪和旧5份坏配对记录保留
│  │  ├─ ★ R16有序完整合并：相同定义复用且冲突阻断、按来源隔离Cell/分类/标签/引用；全部标记与元信息溯源保留，新身份/未导出报告追加
│  │  │  ├─ ★ merge109实际引擎与KLayout0.30.12全读回、18负对照；visited及严格定义检查与KLayout.merge行为差异明确记录，不称完全等同
│  │  │  ├─ ★ SDK4：红A→蓝B，预览1→2/16及末条319、重复生成后的确认/返回取消；11处冲突阻止，策略改变取消旧预览，50/页末页4/4具名原生通过
│  │  │  ├─ ★ 两策略系统Documents实际导出：275条/560值、145条/300值，完整XML及KLayout回读；两份clean冷恢复全会话字节一致，旧报告/来源完整条目保持
│  │  │  └─ ◇ SDK3失败、缺App树及转场捕获保持历史资格；其它图片格式、全部来源组合、最大预算、迟到/拒写与物理设备专项仍待验
│  │  ├─ ● R17可复用本机豁免库第五模式：捕获精确标记/来源/依据、规则分页选择、portable JSON导入导出、完整精确匹配预览、显式一次确认与安全移除库应用
│  │  │  ├─ ● 实际Index七回调/系统picker/确认闭包接C与统一outer；仅稳定来源/布局Cell/工艺规则显式资格有效，同名/近似/未知/重复目标整批阻断，持久精确reportCell+sourceIdentity+document绑定并可明确解除
│  │  │  ├─ ● C一次CAS同时保存报告/库/应用所有权，返回后采用不追加第二次CAS；只移除本库新增system waived，保留既有system/user #waived及全部其它审阅/XML字段；删规则不删除已应用标记
│  │  │  ├─ ● 规则JSON不导入应用receipt；库外XML变化、工程重建报告身份保守放弃旧移除权，既有标签不追认为库所有；未确认/读回不确定需显式reload，不声称物理文件必定未写
│  │  │  ├─ ★ Gate4的7e历史来源core114/KLayout、聚合存储25/Panel28/文件23通过；根Index31执行七真实lambda、单CAS、迟到picker/闭包和解绑范围，只限具名host绑定。既有review104/workspace105/Panel89及分支专项保留原范围
│  │  │  ├─ ★ R17-M03内存局部：previewProjection只深拷贝返回页、draft FIFO闭包只捕获预抽标量、UTF-8全backing才复用buffer；完整pending/immutable encoded队列、精确span、CAS/回滚仍保留。cfe9新9入口392检查执行另列；分支C72为12检查×6进程，队列字节仍无上限，未测app PSS下降
│  │  │  ├─ ★ R19 E18两条规则精确捕获、三项完整匹配预览、取消不发布/确认仅新增一项system waived、cold保所有权、移除仅撤销新增；原system/user标签与其余XML保持。实际applied/removed XML和rules-only JSON双回读/KLayout通过，同JSON导入新增0且不重放applications；标签字符串格式与持久revision identity差异单列
│  │  │  └─ ◇ Gate4/SDK4继续绑定7e；R19只资格上述普通流程。更多拒写/迟到/删除重导入、系统内核锁/更多窗口/规模及完整专业C仍开放
│  │  ├─ ● R17工程整合入口携带本工作区报告、视图与显式布局映射，统一当前slot authority和重复恢复绑定去重见N03；全局库/移除所有权不嵌入工程
│  │  └─ △ 跨工艺/跨documentId豁免资格迁移、全局库工程携带、批量/协作审批、完整附件管理、比较审阅库及更广格式仍缺；C09整组未闭合
│  └─ △ C09完整审阅闭环、规则 DSL/deep（C10）、一般器件 LVS/跨探测（C11/12）、增量 DRC/寄生（C26/28）
├─ N09 版图比较
│  ├─ ● A/B、层/Cell匹配、区域XOR、限定结构Diff：Cell/形状/TEXT/NODE/属性/单位/库名
│  ├─ ● 差异覆盖、定位、JSON 报告
│  ├─ ★ 参数/文档变化失效；保存器等待后再次核对，拒绝过期报告导出
│  ├─ ★ 原生比较拒绝负数/NaN/Inf 网格；B 文件句柄关闭失败清理本次缓存
│  ├─ ★ 作业阶段进度、scope/identity取消；保持busy/stopping直到terminal&&workerStopped再释放B文件
│  │  └─ ★ Clipper真实深层13取消点/99 KLayout几何oracle、局部线程停止和ASAN；非完整设备/规模验收
│  ├─ ★ 大坐标面积局部原点+long-double；1.6e19、远原点面积70及面积内取消反例
│  ├─ ★ R12严格比较：stableCellKeys、typedPorts全部17字段、CrossSections全部6字段、有序layout/cell context
│  │  ├─ ★ Cell归属/存储顺序/原始JSON与字符串字节逐项比较；预算及分块取消拒绝不完整结果
│  │  ├─ ★ 已提交权威快照的binary64含负零；NAPI直接读取原5浮点字段，拒绝二次读数值变化；历史JSON可能已规范化负零
│  │  └─ ◇ 170 native/21实际源码NAPI mock/8 transport host及70 KLayout局部验证；第十二轮包主菜单入口/选择文件/实际比较结果复验保留原资格
│  ├─ ★ R13来源/参数/结果共用正文Scroll，固定运行/导出/取消操作区；SDK1原生top/layers/bottom三阶段2341px实际滚动，完整scope与图层行可见
│  │  └─ ◇ LayoutComparePanel在SDK2未改变，但2341px原生回执仍只绑定SDK1；SDK2比较流程、独立报告文件字节及Locate专项未重验
│  └─ △ 审阅库、用户设计批量回归与更广比较/目标规模（C09/27）
├─ N10 Python 与宏
│  ├─ ● 电脑连接、编辑器、输入快照、参数/扫参、历史
│  ├─ ● 执行/取消、SVG 预览、独立载入/合并和过期保护
│  ├─ ● 宏录制、查看/管理、导入导出、来源约束、批次撤销
│  ├─ ★ 旋转/镜像/缩放本地宏录制与回放
│  ├─ ★ 宏持久化写后回读；拒写回滚内存，工程恢复按文档内容去重
│  ├─ ★ 宏完整数值/ID/文字、失败整批回滚；实例核对完整 Cell 清单和名称
│  ├─ ★ 录制保存/容量错误反馈；成功编辑不因宏记录失败被报失败
│  ├─ ★ Python 草稿/模板/历史写后回读与回滚；32 项容量/参数预算拒绝静默丢弃
│  ├─ ★ Python 文件等待核对文档/版本/面板代次；换文档后的旧面板不覆盖新草稿
│  ├─ ★ R12：编辑/模板/导入/历史/AI草稿变化立即回传文档；仅打开面板不写默认草稿
│  │  ├─ ★ 回调/存储失败保留输入并按文档和原值回滚；防止重入覆盖另一文档的新草稿
│  │  └─ ◇ 21项面板host覆盖并接入最终门禁；原活动/旧文档原生无操作开关及暖冷恢复通过，实际编辑/工程保存原生专项另待验
│  ├─ ★ Python GDS library/Cell/Shape/instance 普通属性保真；四类 owner 写前预算、key/type/string 检查与明确失败
│  │  ├─ ★ 真实 worker/job → native/KLayout 回读：256 个边界标记、最大合法字符串/Unicode，9 项新测试与 116 项完整 Python 测试
│  │  └─ △ 普通属性保真与端口MetaInfo分别验证，不代表工艺routing（C21）或通用端口所有版本兼容（C22）
│  ├─ ★ ports-v1 CRUD/真实worker/文件/sidecar：新批4job均terminal且workerStopped、8GDS/OAS/11oracle通过；8192value/JSON类型/未知context/port-only层表严格核验
│  ├─ ★ 宏删除拒写反馈并保留原宏；脚本导出 picker 前后核对来源，过期不写目标
│  ├─ ● Python结果load改独立parseImportJob；解析/sidecar/验证/激活前后核页代次、文档、版本、canApply
│  │  └─ ◇ 旧dead-page迟到发布实际失败保留；第十一轮四正式host141同source及gate4编译/门禁范围通过，主导入原生异步交互仍待验
│  └─ △ 自定义组件工厂/IDE（C15/16）、设计回归/求解器（C27/28）
├─ N11 AI 助手
│  ├─ ★ d3afc45b专项完善：原目标/策略/固定验证跨继续重试及压缩保存；前后端只读门禁、当前Cell/Top与局部脱敏释放；ROOT80后台/302宿主通过
│  │  ├─ ★ 新包59995DA0…F79B6D6/337生产323工具构建稳定、15558保留草稿安装、当前Cell/Top详情及供应商模型/GET反馈/模型区域/关闭原生通过
│  │  └─ ◇ 新Python策略未部署用户服务；真实供应商完整任务、新包原生任务恢复/Apply/Undo/版本拒绝、全部OS凭据与后台取消终态待验
│  ├─ ● 模型配置/测试、多会话、搜索/迁移/导出
│  │  ├─ ● 多供应商 profile 与每供应商多个模型：独立参数、系统凭据、旧单配置迁移与失败清理重试
│  │  ├─ ● AI 助手→供应商/模型→新增供应商/新增模型/一键获取接口模型列表/保存配置；OpenAI 兼容/Ollama/自定义地址，取消/超时/认证/空列表/手动 ID
│  │  ├─ ● 2026-10-06入口/发现草稿：明确供应商模型按钮、固定GET/反馈/取消；地址→密钥→列表字段；同名选择保留未保存连接与参数，GET只校验连接与超时，保存仍严格校验
│  │  ├─ ● 2026-10-06凭据资格：未知原key拒绝空草稿覆盖，可重读或显式替换；新无key供应商独立，成功读入后主动清空合法；本次宿主与原生范围分列
│  │  ├─ ★ 本次7组179宿主检查通过；015611d8实际构建/保留草稿安装与15558普通供应商模型入口、空白兼容草稿、固定GET/空地址反馈、滚动显示原生复核通过
│  │  ├─ ◇ 真实供应商GET、当前包CRUD持久化/原生凭据失败、完整Agent及物理设备仍待验；未重跑全软件门禁
│  │  ├─ ★ e8e6f7b新安装修复：完整Agent依赖/实际版本与导入探测；缺SDK不宣称能力，鉴权后503可恢复，普通几何仍执行；ROOT主树64/64与实际隔离预检通过
│  │  ├─ ★ 历史 SDK23/24 受控原生两供应商/多模型保存与切换、GET 4 模型/401 负例通过；当前测试配置冷恢复鉴权支持 OS Asset 读回推断，不扩展到所有配置
│  │  └─ ◇ 分支 278 主机/Python 检查及连接修复 147 项检查通过；真实供应商与物理设备另待验，受控本地模型不证明外部模型能力
│  ├─ ● 上下文预算、压缩/恢复、流式 Markdown/工具步骤
│  ├─ ● 编辑方案确认/执行/取消/撤销、Python 版图生成
│  │  ├─ ● “打开助手连接设置”接入 Python 伴随服务；协议能力检查、完成/失败/取消状态；继续/重试携带历史发起新 run，不是 SDK 持久 checkpoint 恢复
│  │  ├─ ● 2026-10-06当前供应商/模型及Agent连接状态固定在聊天滚动外，可直接打开电脑伴随服务设置；真实规划/工具/确认与历史保持，历史fixture不授予本轮外部provider资格
│  │  ├─ ★ 本次摘要/普通Agent连接入口/显式关闭回工作台通过；两份草稿独立回读稳定，原复杂版图字节一致，新草稿仅冷恢复revision/time变化
│  │  ├─ ◇ Escape未关闭Python连接面板的原有行为保留观察，不标成功；当前包端到端任务/写入确认/撤销/后台取消终态仍待验
│  │  ├─ ★ 历史受控原生实际 PythonBridge/Pydantic SDK 5 轮/4 工具：规划、读取实际版图、读取计划、更新步骤；仅模型响应为 fixture，实际工具返回与草稿一致
│  │  ├─ ★ 伴随服务“断开并清除连接”及普通重开通过：默认地址与空令牌恢复，失败回滚/连接使用锁已有 host 覆盖
│  │  └─ ◇ 真实供应商/推理质量/物理设备、原生写入 Apply/Undo/版本拒绝、运行取消与 worker 终态、失败后继续/重试、全部配置冷恢复及清连接后冷启动仍待验
│  ├─ ★ AI DRC 返回检查覆盖警告，零违规但不完整不能声称完成/通过
│  ├─ ★ AI 按精确层用途选择当前 Cell 的全部对象；空层/半个点坐标拒绝，禁止后续误删除
│  ├─ ★ AI 切层后的创建继承本批新用途；失败不发布视图，原始请求上下文保留
│  ├─ ★ AI 显式变换中心与镜像轴实际执行；提示符合坐标方向，全部受影响 ID 返回
│  ├─ ★ AI 最后一个定位/适配/缩放决定视口；非正缩放拒绝
│  ├─ ● 文档/选区/版本保护；继续复用已校验工具
│  ├─ ● 74c54ebd AI/Python 最终关闭后一次空闲帧恢复焦点；跨面板/新弹窗/文档激活/页面退出撤销旧请求，host 40/40、主树构建及保留草稿安装通过
│  │  ├─ ★ 本轮 AI 输入框→普通关闭→直接 Ctrl+K 原生链通过；整份草稿除 offsetX/offsetY/updatedAt 外保持，Python 输入框→普通关闭→画布焦点恢复有原生证据
│  │  └─ ◇ Python Ctrl+K 为补充观察，查看顺序限制保留；标题 toggle、输入焦点下跨面板切换、迟到弹窗/退出的原生资格待验
│  └─ ◇ AI页代次保护callback/catch/finally、owner ticket settling及请求级阶段历史；第十一轮四正式host141及gate4的host/编译范围通过，主导入原生异步交互仍待验
└─ N12 系统与运行边界
   ├─ ● 生命周期、窗口变化、NAPI 同步/异步作业、scope/取消
   ├─ ★ MC20 native可选属性修复：properties/libProperties/cellProperties的missing/undefined按缺省，非法非数组/坏记录/65记录及共享字节预算仍拒绝；42 MSVC精确生产helper检查绑定SDK06 C++ hash，模拟NAPI边界不替代完整设备验收
   ├─ ★ MC20 SDK06 c16bd45/57463AC…DFE8、333生产/317工具、增量SDK21.797s及owned29244/15558安装启动通过；native资格分列448/454/463/472，SDK02编译失败及SDK04空Cell重开失败保留
   │  └─ ◇ 原桌面21228/5555仅连接且私文档未访问、手机关闭；MC20当前保存回读/全流程/物理设备仍pending，大文件性能deferred；历史运行状态只归各自原轮次
   ├─ ★ window/recovery/library已列页面代次链与监听/provider/timer释放（原范围）
   ├─ ● import parse completion/main/recent/Python load/AI context新增页代次保护、独立detached解析与canContinue tick取消
   │  └─ ◇ 第十一轮主/最近77与Python/AI四测试141正式host通过，绑定该轮gate4/HAP；页面迟到场景设备专项仍待验
   ├─ ★ 第八轮DE7冻结246生产/209工具及所列原生4链、8文档恢复属于历史验收
   ├─ ★ 第十轮279生产/237工具/gate4/C07B及指定原5555恢复仅历史checkpoint；不作第十一轮当前包通过
   ├─ ★ 第十轮层栈真实界面/截面/3D旋转/错误拦截/历史/原8文档恢复保留原source/HAP/target范围
   ├─ ★ R12新增presence/Panel/严格compare transport及native metadata/NAPI实际源码检查接入完整门禁；首轮PCell测试接线失败保留
   ├─ ● R17根集成统一持久authority及25个必选专项：A场景/独立负例/native清理、B携带/映射、C库/文件、D递归/格式、root物理存储/coordinator/bridge/面板/实际Index
   │  ├─ ★ 7e历史Gate4完整非HAP分区exit0、25/25/125 Python/665 native PASS/fresh NDK 11/11 构建步骤完成并生成libhongtu.so；独立qualification-03与SDK4增量资格通过，同cohort333生产/292工具。SDK4另行exit0，15 executed/18 up-to-date、同SDK3 HAP021EB336…ED1D7；SDK1/2、gate1/2/3及preflight2失败原样保留；不自动继承新内存cohort cfe9资格
   │  ├─ ◇ 原PC 8文档暖冷及隔离失败回滚后暖冷已有同包具名资格；15558旧SDK4的表达式预览/apply已有局部UI记录，UndoRedo/export及四业务完整交互仍pending；新包原PC8恢复已通过、100k PSS未下降而strict camera比较失败，phone同UUID已真实恢复，host/surface记录和KLayout几何不等于目标GPU/ArkUI像素。build原工件经exact originalPath+SHA转存，复制本身不授予资格
   │  └─ ★ R16历史6411原工件/577实时绑定精确转存已独立核验；所有旧source/HAP/target及失败保持原资格，R17继承引用currentAcceptance=false，不把历史通过升级到本轮
   ├─ ★ R16 SDK4与完整gate-run2同包D277E64D…BB85；313生产/263工具稳定，15个必选RDB阶段及具名合并/导出/恢复通过
   │  └─ ★ R15原3308工件与574条精确冻结映射验证；旧失败、旧包和原生捕获资格保留，未将局部用例数当作功能覆盖率
   ├─ ★ R15 SDK1与完整gate-run1同包02082871…45EDB；311生产/262工具稳定，新增workspace/transfer必选门禁实际终态通过
   │  └─ ★ 指定三报告继承/另存/冷恢复/清理及原8版图暖冷通过；全叶原生分支未遍历、1–3px边缘裁剪和5份早期坏配对保留
   ├─ ★ R14 gate-run1全门禁通过，307生产/260工具稳定；SDK3报告交互及SDK4限定冷恢复/重载分别绑定各自HAP
   │  └─ ◇ SDK4仅图片说明一行变化、编译及Panel26通过；未重跑SDK4完整门禁；手机/物理设备及最大预算响应性待验
   ├─ ★ R13 SDK1完整gate-run1通过，298生产/255工具稳定；SDK2仅两行ForEach键变化、实际SDK编译/Panel15/static与指定视图/书签原生通过
   │  ├─ ◇ SDK2未重跑全门禁；SDK1比较三阶段回执不升级为SDK2，旧行复用失败R13-F04保留
   │  └─ ★ SDK2最终清理后原8文档暖冷精确一致，视图库暖冷字节一致且仅主视图；六处Select补8vp圆角，UI静态0违例；菜单保留Index历史基线差异
   ├─ ◇ 三文件独立回读、未列链的原生重跑、绑定工艺冷启动及物理设备资格待验；R11严格失败保留，R12无操作面板/旧文档切换的缺失字段保真与原8暖冷复验通过
   ├─ ★ 卡片接入文件/切文档/编辑/DRC；持久快照、已安装 ID、重试/移除、检查不完整提示
   ├─ △ 卡片系统宿主/双尺寸实际刷新、设备焦点/兼容性专项
   └─ △ 真实设备/规模/目标工艺验收；完整工业签核仍未完成
```

检查链统一为：**入口 → 回调 → 服务/引擎 → 状态与结果 → 回归及设备证据**。

新内存包实际有限验收见[原PC安装回执](D:/HongTu/hongtu/docs/validation/parallel17-memory/device/original/receipt.json)、[安装后首次启动比较](D:/HongTu/hongtu/docs/validation/parallel17-memory/device/original/memory-original-warm-comparison.json)、[再次冷启动比较](D:/HongTu/hongtu/docs/validation/parallel17-memory/device/original/memory-original-cold-comparison.json)及[fallback可见几何](D:/HongTu/hongtu/docs/validation/parallel17-integration/ui/memory-original-final.jpeg)。回执文件名warm不表示不中断进程的暖启动；实际helper先force-stop→install→start。100k[严格camera诊断](D:/HongTu/hongtu/docs/validation/parallel17-memory/readback/camera-offset-diagnosis-01.json)保留offset比较failed：warm推得1293×772vp、cold751×513vp，after磁盘snapshot早于真正最大化截图；未改comparator/allowlist，不晋级全部camera通过。旧晚ready100k与新memory100kmax真实像素均已由root查看，不再将它们误写成旧画面未确认。PSS两组各3样本、同guest/no forcedGC、不同time/window，没有整体下降；host瞬态分配/调用收益仍限方法，phone同UUID已真实恢复，四完整业务仍由root补。

手机[真实恢复终态](D:/HongTu/hongtu/docs/validation/parallel17-integration/ui/phone-restoration-20261003/phone-restored.json)为restored=true，20:19:02+08，原UUID93ab233d-2818-42f9-b59e-b40ebf7fd707、API24/phone，PID199480/newcreation20:11:48。[fresh-stop-terminal](D:/HongTu/hongtu/docs/validation/parallel17-integration/ui/phone-restoration-20261003/fresh-stop-terminal.json)先核177512及15558 terminal&&workerStopped；[启动前磁盘校验](D:/HongTu/hongtu/docs/validation/parallel17-integration/ui/phone-restoration-20261003/before-phone-boot-integrity.json)六盘与paused baseline精确相等，[最终host身份](D:/HongTu/hongtu/docs/validation/parallel17-integration/ui/phone-restoration-20261003/phone-restored-host-snapshot-final.json)保留原PC162968/creation/config。/data仅验证rw挂载，未执行write test，启动后正常写入，不声称postboot byteequal。[SDK选集](D:/HongTu/hongtu/docs/validation/parallel17-integration/ui/phone-restoration-20261003/source9-after-phone-restore.json)仅9个官方PC静态文件，不覆盖phoneB1或allSDK。旧pause/plan保留历史，此项只资格模拟器运行身份/可用性，四条完整应用业务仍pending。

R17当前实现与待验差异见[结构更新草稿](D:/HongTu/hongtu/docs/validation/parallel17-integration/structure-update-draft.md)。具名来源分别为[A真实叠加与三项修复](D:/HongTu/hongtu/docs/validation/parallel17-readonly-overlay/review-fixes-20261003/handoff.md)、[B工程携带](D:/HongTu/hongtu/docs/validation/parallel17-project-review-carry/handoff.md)、[重复布局绑定修复](D:/HongTu/hongtu/docs/validation/parallel17-project-review-mapping-fix/handoff.md)、[统一bridge](D:/HongTu/hongtu/docs/validation/parallel17-integrated-review-bridge/handoff.md)、[C本机豁免库](D:/HongTu/hongtu/docs/validation/parallel17-waiver/handoff.md)、[D递归表达式](D:/HongTu/hongtu/docs/validation/parallel17-recursive-layer-expression/handoff.md)、[根实际Index专项](D:/HongTu/hongtu/docs/validation/parallel17-integration/index-host/README.md)及[SDK3终态](D:/HongTu/hongtu/docs/validation/parallel17-integration/sdk3/result.json)。7e历史组合资格见[Gate4终态](D:/HongTu/hongtu/docs/validation/parallel17-integration/gate4/result.json)、[独立Gate4资格03](D:/HongTu/hongtu/docs/validation/parallel17-integration/gate4-qualification/qualification-03.json)、[SDK4终态](D:/HongTu/hongtu/docs/validation/parallel17-integration/sdk4/result.json)和[SDK4增量资格](D:/HongTu/hongtu/docs/validation/parallel17-integration/gate4-qualification/sdk4-qualification-01.json)。新cfe9另见[SDK-memory-01](D:/HongTu/hongtu/docs/validation/parallel17-memory/sdk-memory-01/result.json)、[SDK独立回读](D:/HongTu/hongtu/docs/validation/parallel17-memory/sdk-memory-01/readback/SDKqual.json)、[9入口host392](D:/HongTu/hongtu/docs/validation/parallel17-memory/integration-host/fresh-01/result.json)及[native专项交接](D:/HongTu/hongtu/docs/validation/parallel17-memory/integration-native/handoff.md)。新15558旧SDK4包的[表达式apply界面](D:/HongTu/hongtu/docs/validation/parallel17-integration/ui/dedicated/expression-apply-complete-01.tree.json)与[apply后真实状态](D:/HongTu/hongtu/docs/validation/parallel17-integration/ui/dedicated/expression-applied-state/index.json)仅资格真实GDS main、深度1的1/0|2/3→126/6、KEEP禁用且选中、预览14725000nm²/11放置/5结果及实际shapes5→10；UndoRedo/export和四业务完整流程仍待验。来源/包不混用，根最终ledger、原生与内存比较结果由根补记。

[第十六轮报告](D:/HongTu/hongtu/docs/validation/closure16-20261003/report.md)、[需求台账](D:/HongTu/hongtu/docs/validation/closure16-20261003/requirements-ledger.json)与[具名原生记录](D:/HongTu/hongtu/docs/validation/closure16-20261003/native-review.json)列出R16的10个叶子的局部实现和验证边界；所有整叶/整组/整节点合同仍开放。12节点、31组和全部历史子叶按固定历史哈希与JSON指针继承，用例数量不能累计为功能数。[R15历史报告](D:/HongTu/hongtu/docs/validation/closure15-20261003/report.md)保留原资格。R14的568份实时源码/工具/树已另存frozen-sources，2,839份历史工件保全；[R14报告](D:/HongTu/hongtu/docs/validation/closure14-20261003/report.md)与其SDK3/4资格原样保留。

第十二轮[12节点复核](D:/HongTu/hongtu/docs/validation/closure12-20261003/node-audit.md)与[台账](D:/HongTu/hongtu/docs/validation/closure12-20261003/requirements-ledger.json)记录96处原节点、27处功能叶子和3处验证辅助锚点，共126处引用、35文件；这些旧证据维持原版本范围，[第十一轮树](D:/HongTu/hongtu/docs/validation/closure11-20261002/software-structure-tree-final.md)亦保持冻结。

以下KLayout链接继承既有核对。第十二轮读取的KLayout Diff、LayoutEditor官方目录、gdsfactory与Magic端口来源见[官方对照来源](D:/HongTu/hongtu/docs/validation/closure12-20261003/comparison-sources.md)。核心代码存在不能直接等同官方完整界面。

- N01：[Managing The Panels And Loaded Layouts](https://www.klayout.de/doc/manual/panels.html) — 同库Clone视图及Pull In Other Layout界面。
- N01：[Bookmarking Views](https://www.klayout.de/doc/manual/bookmarks.html) — 书签保存/载入、停靠列表和管理/跳转。
- N08：[RDB Format](https://www.klayout.de/rdb_format.html) — XML/category/cell/item/reference与micron单位合同。
- N08：[The Marker Browser](https://www.klayout.de/doc/manual/marker_browser.html) — Open/Reload/Save As、category/cell目录、marker/info、定位与审阅状态界面。
- N08：[ReportDatabase.apply](https://www.klayout.de/doc/code/class_ReportDatabase.html) — 相同标记的审阅属性转移；R15实际KLayout对照保留visited/引用/重复策略差异，不称完全等同。
- N09：[The Diff Tool](https://www.klayout.de/doc/manual/diff.html) — Cell/object结构比较、Exact compare及marker数据库输出。
- N09：[The XOR Tool](https://www.klayout.de/doc/manual/xor.html) — 逐层几何差异、区域、容差及marker或layout输出。

按R17当前源码与具名来源核对：N01真实多source GL/ArkUI只读渲染、来源参数与显式跨新documentId工程映射已接入，旧视图库治理、焦点跟随、绝对STRANS与手机/多窗口/规模仍开放。N03工程携带完整视图/报告和布局绑定，普通编辑与冷恢复共用outer slots；N05的0–32递归Boolean/PATH及真实GDS/OAS/UndoRedo已实现，动态派生依赖与全部组合/规模未闭合。N08已有可复用本机豁免库和B整合入口，C09仍缺跨工艺/跨documentId资格迁移、全局库工程携带、批量协作和完整附件能力。R16资格继续绑定原包；R17旧Gate4/SDK4只资格7e，新cfe9的SDK/9host/native专项独立具名。15558旧SDK4表达式预览/apply为局部UI证据，四业务完整UndoRedo/export/冷恢复仍pending；新包原PC8恢复局部已通过，100k整体PSS没有下降且严格camera仍未取得资格。规则DSL/deep DRC、一般器件LVS/跨探测、N09完整比较审阅库及用户设计批量/规模、C16插件宿主/IDE仍未闭合。官方文档不替代鸿图自身证据。

R15全门禁用时1276.45秒，SDK1/门禁/实际安装HAP同为02082871…45EDB，311生产/262工具前后及最终无漂移。实际继承报告经系统选择器写出，再独立回读全部138条目标及137条来源；三报告冷恢复和仅保留legacy后的暖冷会话各自字节一致。原8版图全字段语义一致，active updatedAt记账单列。未提交输入仍是内存草稿，图片此次不继承；短窗口、更多设备和规模专项未完成。未签名模拟器证据不是物理设备或制造签核。

## 历史验收范围（按原轮次保留）

R14完整gate-run1通过，307生产/260工具前后一致，包与SDK3同为D014D6B3；审阅48、几何190、实际Index/文件45、Panel26、Overlay30具名检查通过。SDK3原生137条报告的审阅、系统导出、引用路径映射及覆盖显示通过，KLayout/完整XML回读保持几何/引用/图片/次数。SDK4包18DF4D39只改一行图片说明，重新编译、Panel26及限定原生复验通过。完整门禁1237.52秒及主要交互属于SDK3，不能改称SDK4全量重测。1px白色图片的Image节点不证明全部图像格式和像素验收；短窗口原生专项仍待验。定位失败半成品视图、私有存储目录替换和文字重复缩放的修复与旧失败保留在R14报告。

第十三轮[gate-run1](D:/HongTu/hongtu/docs/validation/closure13-20261003/gate-run1/result.json)终态exit 0，耗时1200.5552415秒，绑定SDK1 HAP `AA3DDC94C2B4A5880D878F74B8468313CE47AAAE0399BF4752B8A28AA94821E0`。随后为原生旧行/旧确认闭包缺陷修复了ViewWorkspacePanel第217/219行ForEach键，[差异回执](D:/HongTu/hongtu/docs/validation/closure13-20261003/sdk2-panel-source-delta.json)证明仅此两行变化，255工具及其他297生产文件一致。[SDK2实际构建](D:/HongTu/hongtu/docs/validation/closure13-20261003/sdk-final2/result.json)通过，最终HAP为 `1DBFFB3B95003092891A61A106041C781FCBF545565469AEC2B3FE90BD3D0E2F`。Index45/core43源码未变；SDK2重新运行Panel15及UI静态检查。最终两行变化后的完整门禁未重跑。

第十三轮目标为127.0.0.1:5555、API24/x86_64/2in1模拟器，未签名。SDK2已实际安装：原生视图名称即时刷新为R13-final，书签名称与后续覆盖确认刷新为R13-book-final，显隐连续8→7→8覆盖成功；实际系统Documents中的书签JSON导出、删除本轮自建书签、合并导回成功。导回后仅书签ID重新分配、serial由3变4，其余字段精确一致；外部JSON文件没有另做独立字节读取。替换导入、其它documentId及更多失败/迟到场景仍按各自host范围标注，不能从一次合并导入推出全部文件流程验收。`views-after-import.json`保存导回后的记录；本轮临时书签/克隆清理后，`views-after-cleanup.json`与`views-after-cleanup-cold.json`字节一致，均为1主视图、0书签。

SDK2安装前、安装后冷启动、[清理后warm](D:/HongTu/hongtu/docs/validation/closure13-20261003/ui/final2-after-cleanup-warm-comparison.json)与[cold](D:/HongTu/hongtu/docs/validation/closure13-20261003/ui/final2-after-cleanup-cold-comparison.json)四次原8严格比较均通过：8文档全部内容、字段存在性/类型、标签顺序、active、dirty、选区、camera及语义载体一致，清理后仅原活动文档updatedAt变化。冷启动截图已由主线程人工核对为正常版图，并恢复原8文档及未保存草稿。此模拟器结果不代表物理设备或工艺签核。

比较面板[三阶段视口回执](D:/HongTu/hongtu/docs/validation/closure13-20261003/ui/compare-viewport.json)绑定SDK1，记录top/layers/bottom三张原生树、2341px实际滚动及底部完整范围说明；主线程另已人工查看截图。SDK2的LayoutComparePanel源码未变，但未将这条SDK1原生证据改写为SDK2流程验收。独立比较报告字节、Locate及批量审批等仍未闭合。

历史第十二轮gate5包括94个既有host套件、3个新增专项、125项Python及路由/层栈/RDB/View/native/NDK/ArkTS/HAP，终态exit 0；297生产/252工具前后稳定，同哈希hap-preflight1记录实际编译打包。该轮另封存29项Python测试/夹具输入并运行125项，不回填gate5起始清单。第十二轮C9FBD9包的指定面板/切文档/比较交互与四阶段原8暖冷复验、第十一轮gate4及比较取消/面积证据继续保持原source/HAP/target范围。

第十一轮原8严格失败原样保留：UNTITLED_LIB.gds曾新增空engineering及三项默认字段，已有字段保持不等于全字段相同。第十二轮和本轮分别使用各轮修改前设备实际8文档作为基线，其中包含更早已发生的字段变化；各轮通过只证明其具名检查范围，没有撤销历史失败。本轮严格检查区分缺失/null、布尔/数值，除revision/updatedAt等已声明记账字段外比较全部文档字段及索引顺序/active；无沙箱回写。用户脚本编辑/工程保存/Back、迟到任务和此前两报告外部字节等专项未因视图/书签交互而完成。
