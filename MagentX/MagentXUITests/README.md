# ScrollTableView 与节点页回归测试

所有 UI 用例都属于 `MagentX.xcodeproj` 的 `MagentXUITests` target，统一通过
`MagentX` scheme 运行，不再维护独立测试工程或独立 UI 测试 target。

测试目录镜像正式代码目录：`MagentX/View/Common/ScrollTableView.swift` 的用例位于
`MagentXUITests/View/Common/ScrollTableViewUITests.swift`，专用辅助代码也放在同一目录，
不另外划分 `Features`、`Fixtures` 等功能分类目录。
节点页对应 `View/ProxyNodesViewUITests.swift`，内存场景放在同级
`View/ProxyNodesFixture.swift`，不混入通用表格的用例文件。

`View/Common/` 中的内存数据和故障注入夹具由同一工程的 `ScrollTableHost` 测试宿主构建，
它是测试专用的 application target，由 `MagentXUITests` 的构建依赖自动构建；
XCTest 用例仍只属于 `MagentXUITests`，正式应用的构建和归档不依赖这个宿主。
宿主直接编译产品的 `ScrollTableView.swift`、`ProxyNodesView.swift` 及节点页所需的
模型、ViewModel 和统一错误定义，不复制表格、页面或 CRUD 实现，不启动代理服务、
不打开用户数据库。节点场景只用一个最小工具栏契约替身承接页面按钮，
不加载 `ContentView` 的导航和其他页面；因此它不替代完整应用导航壳的运行验证。
正常用例使用 SwiftData 的系统内存存储；错误恢复用例使用可注入错误的内存
`DataStore`，仍通过真正的 `ModelContext`、`@Query` 和原生 Table 执行。

## 运行

在 MagentX 目录执行，需有已登录的 macOS 图形会话和 Xcode UI 测试权限：

```sh
xcodebuild -project MagentX.xcodeproj \
  -scheme MagentX -destination 'platform=macOS' \
  -only-testing:MagentXUITests/ScrollTableViewUITests test
```

节点页迁移回归使用同一工程和 target：

```sh
xcodebuild -project MagentX.xcodeproj \
  -scheme MagentX -destination 'platform=macOS' \
  -only-testing:MagentXUITests/ProxyNodesViewUITests test
```

最低部署目标为 macOS 15，Swift 语言模式为 6。测试时会操作隔离宿主的窗口；
请避免同时手动操作该窗口。启动参数禁用宿主的窗口恢复，避免用例之间互相影响。
不要删除或改动 MagentX 的真实数据库来制造测试故障。

## 工程集成验证（2026-09-19）

- 共享 `MagentX` scheme 纳入原有单元测试与 UI 测试 target，UI 用例不并行操作窗口。
- Xcode 的编译清单确认 35 个 ScrollTableView 用例归属 `MagentXUITests`，
  新增的 8 个节点页用例也归属该 target；三个测试辅助文件只在 `ScrollTableHost`
  中编译，不进入正式应用或 XCTest bundle。
- 目录调整及组件单文件合并后的宿主构建、组件与 UI 测试源码类型检查、工程文件检查、
  格式和 diff 检查通过；35 个场景仅重新分组，方法名与断言保持不变。
- 尚未完成迁移后的整套 UI 运行验证，不能沿用下面的历史通过结果代替。

## 节点页迁移验证（2026-09-19）

- 左侧改用 ScrollTableView，保留 id 排序、三列内容与列宽、HSplitView 尺寸和右侧表单。
  首批100条、当前查询最多300条；不再把300误用为可浏览结果总上限。
- 删除重复的节点 `@Query` 和其初始化方法，父页按单选 UUID 限量读取一条详情。
  页面仍只有原有 `add`、`update`、`delete` 三个业务方法，字段编辑桥接方法未变。
- 8 个新增 UI 用例覆盖：首批与分栏、超过容量后的双向分页、修饰键单选、空表和取消、
  新增/选中/删除、切换节点提交草稿、非法输入回滚、策略引用删除保护。
- 本次已实际运行隔离宿主并检查：100条初始窗口、滚至第425条再回到首行、300条容量、
  选择淘汰后的详情清理、后续页详情、跨节点草稿提交、空表保留表头、新建保存与取消、
  删除最后一条、非法端口恢复8388、策略引用阻止删除。
- 宿主构建与 UI 测试源码类型检查通过。
  **这8个自动化用例尚未执行通过**；上述运行验证来自实际页面的交互检查，非 XCTest 结果。
- 未改变原有节点数据、应用生命周期或代理服务配置；未完成 macOS 15 实机和完整导航壳验证。

## 连续回弹修复（2026-09-19）

- 公共表格改为 `.scrollBounceBehavior(.always, axes: .vertical)`，保留系统动画，
  不改动横向策略或查询窗口算法。该配置的语义见 Apple 的
  [ScrollBounceBehavior.always](https://developer.apple.com/documentation/swiftui/scrollbouncebehavior/always)。
- 滚动观察器只比较原生合法范围内的坐标，防止把回弹归位误判为反向翻页；
  只归一化方向判断所用的坐标，不移动内容或修改原生动画。
- 修复前，长列表和短列表的原生 `verticalScrollElasticity` 都被观测为 `.none`；
  两个基线用例失败。修复后，两者连续三次触顶和触底均检测到实际越界位移。
- 新增5个用例仍位于 `ScrollTableViewUITests`，该类现在共40个场景；覆盖长列表、
  短列表、空表、分页淘汰及搜索重置、一行缓存在两端回弹不能误触反向翻页。
- 仅测试宿主添加只读测量探针：每一轮手势前重置峰值，再记录 clip view 的最大越界距离。
  合法范围由原生 `constrainBoundsRect` 计算，排除表头 inset 的影响。
  探针不设置弹性、不移动内容、不拦截输入，不进入正式应用。
- 使用 XCTest 的 `swipeUp` / `swipeDown` 手势验证实际回弹；普通离散滚轮输入
  不足以验证触控板式弹性动画。用例不约束系统动画的具体幅度和逐帧时序。
- 最终代码在主工程中分两组执行14个不重复的定向 UI 用例：6项和8项均通过，
  0失败、0跳过。包含新增5项，以及键盘翻屏、单次 End、一行缓存按键与滚轮、
  滚动条拖动、淘汰补页像素锚点、空表插入、连续换向、小于视口的缓存。
  正式应用及测试宿主构建、全项目格式检查和 `git diff --check` 均通过。
- 第二组记录1条没有组件源码定位的 `[Internal]` QoS 运行时告警；第一组无运行时告警。
  运行环境为 macOS 27.0（26A428）、Xcode 27、Apple Silicon；未重跑全量40项，
  也未完成 macOS 15 实机验证，不能据此宣称所有平台或全流程零告警。

## 覆盖范围

所有场景统一在 `ScrollTableViewUITests` 这一个 `XCTestCase` 中，按初始化与查询范围、
双向分页与缓冲上限、预加载配置与查询重置、原生滚动输入与位置保持、单选与选择失效、
生命周期与多表隔离、查询失败与恢复分组。每个场景保留独立的 `test…` 方法，
可在 Xcode 中单独运行，也可使用 `-only-testing:MagentXUITests/ScrollTableViewUITests/方法名`
筛选；不为私有滚动观察器另设测试类。

| 范围 | UI 验证 |
| --- | --- |
| 首批与空表 | 初始仅 100 条、静止不连翻、空表插入、短结果、空搜索恢复 |
| 双向窗口 | 向下追加、超过 2,000 条后返回、175 条非整页容量、连续换向 |
| 滚动锚点 | 首次淘汰与向上补页的同一记录像素位置、小于一屏的缓存 |
| 数据边界 | 整页结束、部分尾页、触底后新增、顶部越界、描述符 offset/limit |
| 连续回弹 | 长/短/空表连续三次触顶触底、翻页及搜索后回弹、一行缓存不误翻页 |
| 配置 | 自定义页大小、缓存大小、预加载比例、1% 阈值不淘汰可见行、运行时缩小缓存 |
| 单选 | 普通/Command/Shift 点击、追加保留选择、淘汰或删除清除选择 |
| 生命周期 | 搜索/排序重置、批量删除导致偏移失效、卸载重挂、同窗口多表隔离 |
| 输入 | 真实滚轮、单次 End 自动加载、键盘翻屏与焦点隔离、一行缓存按键去重、系统滚动条拖动 |
| 错误 | 首批失败显式重新加载、计数失败保持旧窗口、分页查询失败回退和重试 |

辅助功能在不同系统版本可能将 SwiftUI Table 暴露成 Table 或 Outline；
测试使用公开元素类型兼容两者。输入法组合文本通过回车提交后验证筛选结果。
键盘用例通过系统 Tab 导航进入表格，先确认方向键选择，再验证翻屏加载；
不会把仅选中单元格误当成已经取得键盘焦点。
长距离用例用 End/Home 驱动原生滚动，验证第 2,405 行与返回后的第一行实际可见，
并分批检查 1,000 条容量；不依赖系统尚未生成的离屏单元格。
原生回弹仍由系统执行：用例逐次检查实际越界位移和查询边界，不断言系统动画的逐帧形态。

## 迁移前验证记录（2026-09-19）

以下结果来自目录迁移前的独立工程，不能作为迁移后主工程测试已通过的证明。

- 环境：macOS 27.0（26A428）、Xcode 27、Apple Silicon。
- 完整 UI 回归：35 项通过，0 失败、0 跳过；包含第 2,405 行至首行的往返，
  以及默认 1,000 条缓存上限检查。
- 像素锚点用例额外连续运行 5 次，全部通过，无运行时警告。
- Swift 6 / macOS 15 部署目标类型检查、代码格式检查、`git diff --check` 均通过。
- 完整回归记录了预期的查询故障注入警告，以及文本输入期间的系统 Security/QoS
  运行时告警；后者没有组件源码定位，尚不能宣称全流程零告警。
- 尚未进行 macOS 15 实机运行验证。

重复验证像素锚点：

```sh
xcodebuild -project MagentX.xcodeproj \
  -scheme MagentX -destination 'platform=macOS' \
  -only-testing:MagentXUITests/ScrollTableViewUITests/testPixelAnchorAcrossEvictionAndPrepend \
  -test-iterations 5 test
```

## 组件约定与审查说明

- 调用方必须提供带稳定排序的 `FetchDescriptor`；排序末项应为唯一字段。
- `queryID` 必须随筛选/排序语义变化。描述符的 `fetchOffset` 是起点，
  `fetchLimit` 是可浏览结果总上限，不是单页容量。
- `pageSize` 默认 100，`maximumCachedModelCount` 默认 1,000，均须大于零。
  当缓存小于页大小时自动收紧页大小，最小支持一行缓存，不会跳过记录。
  `preloadProgress` 在 0 与 1 之间，默认 0.8，按靠近边界的一页对称预加载。
- 组件只持有一个受 `fetchLimit` 限制的 `@Query` 模型集合；原生滚动观察器仅保存
  标识和像素锚点，不接管数据源、选择、列或绘制。
- 正常表格没有翻页按钮；只有查询出错的系统提示框提供“重新加载”，
  让首批失败后的空表也能主动恢复。
- 分页状态方法仅负责相邻页请求、查询完成/回退、查询重置；桥接方法只负责
  原生挂载/卸载、输入观察、所属表格定位及锚点恢复，没有显示片段包装方法。
- SwiftUI Table 的滚动几何/位置回调在本机实测未触发，因此保留最小 AppKit
  观察桥接。需在最低支持的 macOS 15 真机或虚拟机补跑同一套测试；
  macOS 27 上的通过结果不能代替 macOS 15 的运行验证。

测试故障存储参考 Apple 的
[自定义 DataStore 协议说明](https://developer.apple.com/videos/play/wwdc2024/10138/)，
只支持错误用例使用的测试模型和 id 正序查询，不应被产品代码引用。
