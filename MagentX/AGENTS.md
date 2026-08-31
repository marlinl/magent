# Repository Guidelines

## Documentation & Visibility

Swift 类型声明必须写 `///` 文档注释，说明该类型承担的业务职责。这里的类型包括 `class`、`struct`、`enum`、`actor` 和 `protocol`，无论是否是 `private`。

所有非 `private` 的 `func` 必须写 `///` 文档注释，说明调用目的、主要副作用或返回语义。只在当前类型内部调用的 helper 函数必须声明为 `private`；如果函数需要被 View、Controller、测试或协议回调调用，保留合适可见性并补充注释。

MagentX app 层异常错误统一定义在 `MagentX/MagentXError.swift` 的 `MagentXError` 中。不要在 Controller、Service、Model 或 View 中新增局部 `Error`/`LocalizedError` enum；需要新错误时给 `MagentXError` 增加 case。

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
- `update`：统一负责单条规则修改和订阅同步。

确实无法归入白名单的方法，只有在协议要求、平台回调签名或并发隔离无法通过 `body` 闭包和已有 Service 表达时才可以提出。编码前必须先向用户说明：为什么必须新增、归属哪个生命周期、内联或下沉方案为什么不可行，并取得用户明确确认；未经确认不得新增。

完成 View 修改后必须用源码搜索重新列出该 View 的全部 `init`/`func`，逐项核对白名单，并在最终说明中报告核对结果。这个检查不能只依赖编译或测试通过。
