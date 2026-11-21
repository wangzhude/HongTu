# 工程功能接线 — 2026-09-30

本轮代理负责服务/native/独立组件，不修改 Index.ets、GdsiiData 或 EditService。已有改动全部保留，无提交。

## 当前文档同步和保存

`layoutExportService.buildNativeDocument(input: ExportLayoutInput): Object` 已公开，并保留图形 id、属性、PATH/AREF/TEXT 完整载荷。

`nativeHongTuService.syncDocument(document: Object): NativeSyncResult` 返回 `{success,errorMessage}`。
这是有预算检查的内存事务：先构建新解析快照/场景，成功后才替换 native；不写文件、不 markClean、不改变 undo 历史；失败保留旧 native。

Index 在 DRC、LVS、NetTrace、SVG/PNG/OASIS 导出之前从**当前**编辑态生成完整 `ExportLayoutInput`，同步成功后立即运行操作。删除旧的 dirty 拒绝/降级条件，不以 `currentFilePath.length` 限制新文档。

```ts
const sync = nativeHongTuService.syncDocument(layoutExportService.buildNativeDocument(this.currentExportInput()));
if (!sync.success) { this.statusText = `当前版图同步失败：${sync.errorMessage}`; return; }
// 执行本次 DRC/native LVS/导出。文档的 dirty 状态仍保持。
```

不要把 `syncDocument` 成功当成磁盘保存成功；`originalSourceCurrent` 不能因此变 true。
LVS/trace 用 `technologyService.getViaLayers()`，替换固定 `DEFAULT_VIA_LAYERS`。没有绑定工艺时仍为空数组并保留仅同层提示。

新保存入口：

- `saveGdsToUri(context, input, uri): Promise<LayoutExportResult>`：复用已有完整 native/字节回退保存，跳过 picker，适用于普通保存。
- `writeGdsToPath(input, path): Promise<LayoutExportResult>`：当前编辑态写 app 私有快照，不使用旧磁盘源。先写同目录 staging，完整长度检查后 rename；失败不会截断旧快照，finally 清理 staging。供恢复/Python输入。
- 两者只有 Promise 成功后才可由 Index 更新“已保存”；autosave/Python快照不应 markClean。

## A/B 比较

`LayoutComparePanel`（components/workbench）：

```ts
LayoutComparePanel({
  panelWidth: 580, panelHeight: 700,
  snapshotProvider: () => this.currentExportInput(),
  revisionProvider: () => /* 文档ID + 几何/Cell/属性版本，不能只用dirty布尔 */ '',
  locateAction: (layer: NativeLayoutCompareLayer, cellName: string) => { /* 切换到结果Cell，再fit bbox */ },
  resultAction: (result: NativeLayoutCompareResult) => { /* 存储差异/清空旧高亮 */ },
  closeAction: () => { /* 关闭面板 */ }
})
```

面板包含独立 picker B、可选 A/B Cell、B 的 nm 偏移、比较网格、异步计算、逐 layer/datatype 结果、定位动作、结构差异和 JSON 报告导出。计算期间文档 revision 改变会拒绝应用旧结果。B 从复制到读取都不走全局 parse/commit，不替换 A。

主画布非交互覆盖层 `LayoutCompareOverlay` props：`differences:NativeLayoutCompareLayer[]`、`scalePxPerNm:number`（实际屏幕px/nm，不是缩放百分比）、`viewOffsetX/viewOffsetY`（世界nm）、`selectedPair:string`（空显示全部，或 `68/20`）。坐标为 `screenX=(worldX+offsetX)*scale`, `screenY=(offsetY-worldY)*scale`。Path整组保留洞，超预览预算只画bbox。编辑/换文档后清空differences，避免旧差异覆盖新文档。

下层接口：

```ts
nativeHongTuService.compareLayout(documentA, sandboxPathB,
  {cellA:'',cellB:'',offsetX:0,offsetY:0,gridNm:0}): Promise<NativeLayoutCompareResult>
```

原生 worker 独立解析 B；使用完整所选层级、有效 PATH 轮廓、每个 `(layer,datatype)` 先独立填充并集，再真实 Clipper2 XOR/差集。`gridNm=0` 取两文档较细 DBU，显式网格区间 `1e-6..1e6 nm`；阈值/格式资源触顶返回 `success=false,complete=false`，不宣称一致。

结果 `layers[]` 只含有几何差异的 pair，各有 `areaOnlyA/areaOnlyB/xorArea` (nm²)、`minX/minY/maxX/maxY` 和 `contours: NativePoint[][]`。signed contours 保留洞；覆盖层应按相反绕向/非零规则画整组。预览累计上限 50k 顶点，单层被截时该层 contours 清空，只显示完整 bbox，避免只画外环误填洞。`previewTruncated` 只描述预览；真实面积计算完整。

结构 Diff 覆盖全库 Cell、实例压缩记录/变换、图形记录、TEXT/NODE/属性、单位/库名，并保留重复记录数量；这是严格存储结构对照，不受 B 对齐偏移影响。几何等价不要求相同拆分/顶点顺序，结构可能仍不同。所有报告都不宣称工艺签核。

## 工艺包

`common/technologyPackage.ets` 定义 `hongtu-technology/v1` JSON，纯解析器 `parseTechnologyPackage(text)` 全量校验失败不应用。

字段：`id,name,version,source,license,qualification,layers,viaLayers,drcRules,devices,drcDeckId,lvsDeckId`。
`qualification` 只接受 `unverified/public-subset/user-validated`，不是签核标记。

- `layers`: `{name,layerNumber,datatype,purpose,color}`；只给真实 pair 命名/颜色，不改版图层号。
- `viaLayers`: `{viaLayer,viaDatatype,lowerLayer,lowerDatatype,upperLayer,upperDatatype}`；包内必须指定精确 datatype（含0），引用 pair 必须存在。
- `drcRules`: 复用现有 DRC JSON 清单解析、单位和预检查能力。
- `devices`: `{name,pcell,model,parameters:Record<string,number|string|boolean>}`；由PCell界面选器件时合并默认参数。不能据默认参数宣称PDK合规。
- `drcDeckId/lvsDeckId`: 电脑伴随服务已注册的 deck ID；不接受代码或路径。

服务：`technologyService.activate(package,layers):UiLayer[]` 一次性验证、更新图层名/颜色及 DRC 规则，然后设置 active；保留原可见/锁定等显示状态。`getActive()` 返回副本，`getViaLayers()` 返回副本，`serialize()` 可存到文档工作区。`clear()` 清空工艺/规则。

原生通孔连通现在支持精确 datatype；旧 API 不传三个datatype仍保留历史任意用途行为。同层不同 datatype 不再自动视为导体连通。

`TechnologyPanel` props 精确为 `panelWidth/panelHeight`、`applyAction:(technology:TechnologyPackage)=>void`、`clearAction:()=>void`、`closeAction:()=>void`。applyAction内由Index调用 `this.layers=technologyService.activate(technology,this.layers)`，更新显示缓存/DRC面板并把serialize存入当前工作区；clearAction调用service.clear并持久化。面板有JSON编辑/校验、导入导出、空白模板、SKY130 M1子集、KLayout MOS4演示三个入口，不自行接管页面layers。

`VerificationPanel` props：

```ts
VerificationPanel({
  panelWidth:620, panelHeight:720,
  documentProvider: async () => /* 与Python相同当前dirty全库快照 */ input,
  revisionProvider: () => /* 与Compare同一文档版本键 */ '',
  locateAction: (item:PythonViolation, cellName:string) => { /* 切换到请求Cell，再nm bbox定位、高亮 */ },
  resultAction: (result:PythonVerificationResult) => { /* 可存入当前工作区报告 */ },
  technologyAction: () => { /* 关闭本面板并打开TechnologyPanel */ },
  settingsAction: () => { /* 打开现有Python连接设置 */ },
  closeAction: () => {}
})
```

面板包含DRC/LVS切换、选用绑定工艺deck、可选Cell、参考SPICE文件/粘贴、运行/取消等待、报告/标记定位和器件列表。空Cell明确解析成snapshot.currentCellName后发送（缺失则拒绝），报告包含实际请求Cell。两个panel在结果定位时再次校验文档ID+revision；第二参数Cell来自完成的请求，不读取后来修改的输入框。关闭时取消当前网络等待；运行后比对revision，已过期不应用。当前实现只申请已配置的本机deck，不自动下载/执行未知PDK。

## 电脑侧规则/器件验证

`python/hongtu/verification.py` 提供 `validate_verification_request(request)` 与 `run_verification(request)`，automation代理接 POST `/v1/verify` 及 ArkTS `pythonBridgeService.verify`。

请求：`{kind:'drc'|'lvs',technologyId,deckId,documentGds:base64,referenceSpice?:string,cellName?:string}`。
从当前编辑态 snapshot 编码，不能把打开时旧源当输入。32 MiB版图、2 MiB参考网表、90秒、1GiB worker限制；客户端不能提交可执行脚本/路径。

内置精确组合：

- `technologyId=sky130, deckId=sky130-met1-public, kind=drc`：官方 KLayout merged Region 的 met1 三条检查。无 met1 或空范围不冒充通过。
- `technologyId=klayout-demo, deckId=klayout-demo-mos4, kind=lvs`：官方演示工艺真实 MOS4 提取+SPICE拓扑比较；不适用于 SKY130。

完整自有工艺通过本机环境变量 `HONGTU_TECHNOLOGY_REGISTRY` 指向受用户管理的 JSON 注册：

```json
{"decks":{"my-drc":{"technologyId":"my-process","kind":"drc","path":"decks/my-drc.py","sha256":"实际sha256","scope":"具体工艺版本与规则覆盖"}}}
```

相对path相对注册表目录。只运行已注册哈希固定的本机 `.py`，启动前和worker内再次校验；文件变化必须由管理员重新确认注册。注册脚本须实现 `verify_layout(layout_path, reference_path_or_none, cell_name, output_dir)` 返回 `{complete:bool,passed:bool,...}`。不完整结果不能pass；输出仍强制 `foundrySignoff=false`。

验证结果包括 `violations`（nm bbox、rule、pair、message）、`devices`（name/model/parameters）、`netCount`、可导出的 `reportText`，以及输入 SHA256/deck hash/engine/scope。标记预览最多5000项，`violationCount`保留总数。

## 当前验证

- `tools/layout_compare_smoke.cpp`：15项通过，包括真实集合几何、孔、dtype、结构属性、失败拒绝、精确用途连通。
- `tools/technology_package_host_check.mjs`：21项通过，包括严格导入、作用域隔离、应用失败不污染旧包、图层显示保持、深拷贝、规则非法类型拒绝。
- `tools/export_fallback_host_check.mjs`：33项通过；新增当前编辑几何与ID、直接URI保存、快照短写/rename失败保留旧稿并清理临时文件、图像/OASIS选择目标后的文档变化守卫。
- `tools/index_save_snapshot_host_check.mjs`：6项通过，直接抽取执行 Index 保存方法：保存中编辑或切换不清 dirty/不改另一页URI，完整输入深拷贝，失败/不完整保护，重复保存拒绝。
- `tools/engineering_panel_context_host_check.mjs`：5项通过，直接运行两个panel控制方法，验证Cell上下文、请求report与定位一致、文档切换/编辑拒绝旧定位、缺失Cell拒绝隐式顶层。
- `tools/engineering_file_host_check.mjs`：3项通过，独立B导入、字符串型复制异常包装Error并清理、部分复制拒绝；首轮ArkTS有限throw编译问题已修。
- `python/tests/test_verification.py`：7项通过，真实 KLayout DRC pass/fail、MOS4参考pass/错误连线fail、输入拒绝、注册deck真实执行和hash变动拒绝、坏坐标/带违例的假pass拒绝，以及真实基础CPython `-I bridge_entry.py` 的隔离HTTP启动回归。
- 新增的 `layout_compare_smoke` 已列入 Windows/POSIX 标准 native smoke runner。
- ArkTS/HAP与真实UI入口/截图由root在统一构建后验收，不在此冒充已完成。

## 已完成的 Index 局部接线

经 root 授权仅局部修改 `exportImage/exportOasis/saveCurrentLayout/traceNets/nativeSnapshotUsable/openLvsPanel/loadExtractedNetlist/runLvsCheck`。dirty/new 文档可同步后检查和导出；通孔用当前 technologyService。图像/OASIS服务新增可选末参 `prepareNative?:()=>void`，在 picker 返回后、native 写出前同步校验当前文档，编辑/切换则取消。GDS保存使用拥有完整点/属性数组的不可变输入，按workspaceId/revision决定是否markClean；异步结束重新同步激活文档。Root需声明 `saveInProgress:boolean=false`、`netSnapshotRevision:number=-1` 并导入NativeViaLayer；对后续编辑/切换清空trace/LVS过期结果。

## 真实启动方式回归

设备调用发现：服务由 `start_python_bridge.ps1` 使用基础CPython `-I bridge_entry.py` 启动，health能加载仓库venv的KLayout，但verification再起的 `-I` 子进程不继承bridge的sys.path，原先报缺失klayout。现verification CLI worker与生成worker一样，仅显式加入从已安装脚本位置推导的可信repo/python和repo/python/.venv/Lib/site-packages；保持-I、资源限制和请求不含脚本路径的边界。

回归测试用项目venv查出的精确 `sys._base_executable` 执行真实bridge_entry（不是当前测试进程内Handler），临时LOCALAPPDATA与随机token、临时loopback端口，health后真实验证1000nm宽通过/100nm宽违例+markers，并检查请求Cell进入报告。恶意cwd klayout.py/PYTHONPATH未被导入。bridge CLI新增可选 `--port` 以允许独立本机测试，生产默认7865和loopback绑定不变，测试未读取或重启生产服务。
