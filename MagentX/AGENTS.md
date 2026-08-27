# Repository Guidelines

## Documentation & Visibility

Swift 类型声明必须写 `///` 文档注释，说明该类型承担的业务职责。这里的类型包括 `class`、`struct`、`enum`、`actor` 和 `protocol`，无论是否是 `private`。

所有非 `private` 的 `func` 必须写 `///` 文档注释，说明调用目的、主要副作用或返回语义。只在当前类型内部调用的 helper 函数必须声明为 `private`；如果函数需要被 View、Controller、测试或协议回调调用，保留合适可见性并补充注释。

MagentX app 层异常错误统一定义在 `MagentX/MagentXError.swift` 的 `MagentXError` 中。不要在 Controller、Service、Model 或 View 中新增局部 `Error`/`LocalizedError` enum；需要新错误时给 `MagentXError` 增加 case。

## MagentX UI Native Components

MagentX View 默认使用 macOS 原生 SwiftUI 组件表达界面和交互，例如 `NavigationSplitView`、`List`、`Table`、`Form`、`ToolbarItem`、`Picker`、`Toggle`、`Button`、`Menu`、`ContentUnavailableView` 和 `.searchable`。不要先用 `HStack`、`VStack`、`ZStack` 或自定义 row/container 去手动画系统已有的表单、工具栏、表格、列表和状态按钮。

只有在原生组件无法表达必要交互或平台行为时，才允许在 View 中使用 stack 组合自定义布局；动手前必须先告知用户系统组件具体不支持什么、可选替代方案及其取舍，并等待用户确认后再改。不要在不说明原因的情况下，静默把已有原生 view 改成自绘布局。
