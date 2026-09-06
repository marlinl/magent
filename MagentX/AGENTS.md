# Repository Guidelines

## Documentation & Visibility

Swift 类型声明必须写 `///` 文档注释，说明该类型承担的业务职责。这里的类型包括 `class`、`struct`、`enum`、`actor` 和 `protocol`，无论是否是 `private`。

所有非 `private` 的 `func` 必须写 `///` 文档注释，说明调用目的、主要副作用或返回语义。只在当前类型内部调用的 helper 函数必须声明为 `private`；如果函数需要被 View、Controller、测试或协议回调调用，保留合适可见性并补充注释。

MagentX app 层异常错误统一定义在 `MagentX/MagentXError.swift` 的 `MagentXError` 中。不要在 Controller、Service、Model 或 View 中新增局部 `Error`/`LocalizedError` enum；需要新错误时给 `MagentXError` 增加 case。

## IoC 注入命名

使用 `@Injected` 注入的实例变量必须采用其类型名的 lowerCamelCase 形式，不得使用泛化或职责缩写名称。例如 `MagentProxyRuleService` 必须命名为 `magentProxyRuleService`，不能命名为 `service` 或 `ruleService`。

## Unit Testing & Access Control

UT 应测试调用方能够访问的方法及其可观察行为，不要求每个新增或修改的实现方法都一一对应新增测试方法。测试数量应由业务行为、输入边界和分支数量决定；同一个可访问方法可以使用多个测试方法分别覆盖成功、失败和边界场景。

`private` 方法必须保持实现细节。测试应通过调用其最近的可访问入口，构造不同输入或状态，让执行路径到达 `private` 方法的各个重要分支，并断言入口的返回值、错误或副作用。不得仅为了让 UT 直接调用而将 `private` 方法改为 `internal`、`public`，或以其他方式放宽权限。

## Pagination

所有分页方法的 `pageAt` 都使用从 `1` 开始的页码，第一页默认是 `1`；调用方不得传入从 `0` 开始的页码。

分页查询必须在方法内部将页码转换为底层 offset。SwiftData 或数据库查询统一使用 `(pageAt - 1) * pageSize`，不得要求调用方预先减 `1`，也不得直接使用 `pageAt * pageSize`。

## Libraries & Custom Implementations

实现编解码、文件格式、协议、规则语法、加密、网络传输或数据库等通用能力前，必须先检查 Apple 系统框架、已有项目依赖和社区主流成熟库。只要它们能正确覆盖业务语义，优先使用现成 API 或库，不要重新手写解析器、编解码器或协议实现。例如 Base64 应直接使用 Foundation 的 `Data` Base64 API。

选择第三方库时，优先考虑使用广泛、持续维护、文档和测试完整、许可证与本项目兼容、支持当前 Apple 平台和 Swift 版本的库，并避免为小功能引入体量或传递依赖明显过大的库。新增依赖前应说明候选方案、选择理由、许可证和维护状态。

只有在系统 API、已有依赖和合适的主流库都无法满足需求，或引入依赖的成本明显高于有限的自定义实现时，才允许手写。手写前必须向用户说明未采用现成库的原因、支持的语法边界和关键边界情况，并为这些行为添加针对性测试。不得在多个 Service 中复制同一套自定义解析逻辑。

## MagentX UI Native Components

MagentX View 默认使用 macOS 原生 SwiftUI 组件表达界面和交互，例如 `NavigationSplitView`、`List`、`Table`、`Form`、`ToolbarItem`、`Picker`、`Toggle`、`Button`、`Menu`、`ContentUnavailableView` 和 `.searchable`。不要先用 `HStack`、`VStack`、`ZStack` 或自定义 row/container 去手动画系统已有的表单、工具栏、表格、列表和状态按钮。

只有在原生组件无法表达必要交互或平台行为时，才允许在 View 中使用 stack 组合自定义布局；动手前必须先告知用户系统组件具体不支持什么、可选替代方案及其取舍，并等待用户确认后再改。不要在不说明原因的情况下，静默把已有原生 view 改成自绘布局。

## MagentX View Method Strong Review

新增、删除、改名或拆分任何 View 方法都属于强制 review 项。修改前必须列出该 View 当前的 `init`/`func`，并把每个方法映射到用户明确要求的页面生命周期或业务操作；只为缩短 `body`、转发一次调用或包装一段原生组件而存在的方法不得保留。

View 中不要定义 `make*`、`build*`、`create*`、`render*`、`handle*`、`prepare*`、`publish*` 这类展示片段或事件转发 helper。一次性使用的 `Table`、`Form`、`Picker`、`Button`、空状态和 SwiftUI modifier 应直接写在 `body`；可复用的非界面业务逻辑应按职责移动到 Model 或 Service，而不是继续拆成 View 方法。用户明确禁止 Controller 时，不得为承接这些 helper 新建 Controller。

如果用户给出了 View 方法白名单，该 View 除 SwiftUI 必需的 `body` 属性外只能定义白名单中的方法。当前 `ProxyRulesView` 的方法白名单固定为：

- `init`：只注入依赖。`@Environment` 在 View 挂载前不可用，因此初始化读取通过 `.task` 调用 `search`，不得为此新增 `prepare`/`load` 方法。
- `add`：负责新增规则。
- `delete`：负责删除规则。
- `search`：统一负责首次读取、关键字搜索、分页和操作后的列表刷新。
- `update`：按 `id` 更新单条规则的 `matchType` 和 `decision`，界面更新来源标记为 `user`。
- `sync`：负责规则订阅下载、数据库合并和 PAC 刷新。

确实无法归入白名单的方法，只有在协议要求、平台回调签名或并发隔离无法通过 `body` 闭包和已有 Service 表达时才可以提出。编码前必须先向用户说明：为什么必须新增、归属哪个生命周期、内联或下沉方案为什么不可行，并取得用户明确确认；未经确认不得新增。

完成 View 修改后必须用源码搜索重新列出该 View 的全部 `init`/`func`，逐项核对白名单，并在最终说明中报告核对结果。这个检查不能只依赖编译或测试通过。
