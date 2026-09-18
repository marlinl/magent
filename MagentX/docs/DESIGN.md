# Design

## Main Window Layout Framework

### Required Structure

- `ContentView` is the single owner of the main-window layout and must use one native
  `NavigationSplitView`.
- The leading column is the application navigation sidebar. It must use a sidebar-styled `List`
  and contain navigation items only unless a product design explicitly requires another native
  sidebar control.
- The detail column has one consistent vertical hierarchy for every routed page:
  1. The native window title and toolbar area, containing the sidebar toggle, page search, or
     page-level common actions.
  2. The selected detail View, containing the page's actual display and editing interface.
- The toolbar area is part of the shared window shell even when a page has no search field or
  page-level action. A detail View must not hide it, replace it, or draw a placeholder toolbar.
- `ContentView` owns page routing, the selected section, page title and subtitle presentation,
  toolbar placement, and toolbar background. A detail View must not repeat those shell elements.

The intended hierarchy is:

```text
ContentView
└── NavigationSplitView
    ├── Sidebar List
    └── Detail column
        ├── Native window title and toolbar
        └── Routed detail View
```

### Toolbar Ownership and Page Contributions

- There is exactly one main-window toolbar. `ContentView` defines it with SwiftUI's native
  `.toolbar` and `.toolbarBackground` APIs and renders page-level common action items in that
  shared location.
- A detail View owns the state and behavior specific to its page. It may contribute:
  - Search through `.searchable(..., placement: .toolbar, ...)`, with the search text and filtering
    behavior kept in that detail View.
  - Page-level common actions through the toolbar contribution interface supplied by
    `ContentView`, with the action implementation kept in the detail View or its responsible Model,
    Service, or Coordinator.
- A modifier such as `.searchable` may be declared by a detail View while the resulting search
  field is displayed in the shared window toolbar. This is native SwiftUI toolbar composition; it
  does not make the detail View the owner of a second toolbar.
- Every View routed by `ContentView` must use this contribution model. Do not let some pages build
  an in-content toolbar while other pages use the window toolbar.
- The boundary between the shared toolbar and detail content must remain visible on every page.
  Prefer the separator supplied by the page's native root component. If a native `Table` or other
  root component does not expose that separator, add the standard page-boundary treatment directly
  to the routed detail View:

  ```swift
  .padding(.top, 1)
  .overlay(alignment: .top) {
    Divider()
  }
  ```

  Do not customize the separator's color, thickness, or material.
- Keep toolbar contents page-appropriate. Pages are not required to invent an action solely to
  fill the toolbar, but they must preserve the same shell and content hierarchy.

### Boundaries

- Do not move page search text, filters, selection, loading state, persistence operations, or
  business actions into `ContentView` merely because their controls appear in the shared toolbar.
- Do not place a `VStack`, `HStack`, `GroupBox`, custom background, or custom-styled separator at the
  top of a detail View to imitate the window toolbar. The documented native `Divider` boundary is
  the only exception and must not contain toolbar controls.
- Do not set page-specific navigation titles, window-toolbar backgrounds, sidebar geometry, or
  window chrome inside a routed detail View.
- A toolbar inside a sheet or another independently presented scene belongs to that presentation's
  lifecycle and may provide native cancellation and confirmation actions. It is not a second
  main-window toolbar.

## MagentX UI Native Components

### Use

- Use native macOS SwiftUI components for views and interactions.
- Prefer `NavigationSplitView`, `List`, `Table`, `Form`, `ToolbarItem`, `Picker`, `Toggle`,
  `Button`, `Menu`, `ContentUnavailableView`, and `.searchable` where they express the required
  behavior.
- Keep one-use native components and modifiers directly in `body`.
- Move reusable non-UI business logic to the responsible Model or Service.

### Do Not Use

- Do not begin with `HStack`, `VStack`, `ZStack`, or a custom row or container when a native
  component already provides the form, toolbar, table, list, or state control.
- Do not silently replace an existing native view with a custom-drawn layout.
- Do not add custom stacks merely to recreate an existing platform interaction or appearance.

### Native Component Exceptions

- Use a stack-based custom layout only when native components cannot express a required
  interaction or platform behavior.
- Before implementing an exception, explain:
  - What the native component cannot support.
  - Which alternatives are available.
  - What tradeoffs each alternative introduces.
- Wait for explicit user approval before replacing the native approach.

## MagentX View Method Strong Review

### Required Review

- Treat adding, deleting, renaming, or splitting any View method as a mandatory review item.
- Before editing a View, list every existing `init` and `func` declaration.
- Map each method to a user-requested page lifecycle or business operation.
- Remove methods that exist only to shorten `body`, forward a single call, or wrap a native
  component.
- After editing, search the source again and list every `init` and `func` declaration.
- Compare the final method list with the applicable whitelist and report the result. A successful
  build or test run does not replace this check.

### Do Not Add

- Do not add display-fragment or event-forwarding helpers named with prefixes such as `make`,
  `build`, `create`, `render`, `handle`, `prepare`, or `publish`.
- Do not extract a one-use `Table`, `Form`, `Picker`, `Button`, empty state, or SwiftUI modifier
  into a View method.
- Do not move reusable non-UI business logic into another View method.
- Do not create a Controller to hold these helpers when the user has explicitly prohibited a
  Controller.

### Method Whitelists

- When a user provides a View method whitelist, the View may define only those methods and the
  SwiftUI-required `body` property.
- Propose an additional method only when a protocol requirement, platform callback signature, or
  concurrency isolation requirement cannot be expressed by a `body` closure or an existing
  Service.
- Before adding such a method, explain why it is required, which lifecycle owns it, and why
  inlining it or moving it to a Service is not viable. Obtain explicit user approval before coding.

### Dedicated List Views

- Define a list or table with its own interaction or query configuration as a dedicated
  `struct View`.
- Keep list-specific selection, filtering, and query configuration inside that View instead of
  adding forwarding methods to its parent View.
- When required by the business behavior, the dedicated list View may define methods for concrete
  list operations. Each method must correspond to a clear lifecycle or user operation rather than
  exist only to shorten `body`.
- Keep reusable data access, persistence, synchronization, and other non-UI business logic in the
  responsible Model or Service.
- Apply the same method review before and after changing methods in the dedicated list View.

### Native List and Table Model Limits

- Every page View that presents a SwiftUI `List` or `Table` backed by SwiftData must explicitly
  declare a finite, positive `maximumCachedModelCount` property. Use this exact property name so
  the model limit remains visible during View review.
- Apply the page View's `maximumCachedModelCount` directly to `FetchDescriptor.fetchLimit` when
  initializing `@Query`. If a nested dedicated View owns the query, pass the page View's property
  into that initializer; do not replace it with a second cache or another limit. Reapply the same
  value when a search or filter rebuilds the descriptor.
- Pass the `@Query` result directly to the native `List` or `Table`. SwiftUI owns the visible row
  range, row reuse, accessibility retention, prefetching, and the system-determined rendering
  buffer.
- `maximumCachedModelCount` limits how many SwiftData models the View queries and observes. It does
  not configure the native control's internal rendering buffer; SwiftUI exposes no public setting
  for that buffer.
- Do not create a second model cache in View state. In particular, do not add `loadedPages`, page
  dictionaries, flattened model arrays, retained-page ranges, visible-index tracking, scroll-anchor
  caches, `prefetchThreshold`, or manual eviction logic to control `List` or `Table` buffering.
- Do not introduce manual pagination, `onAppear` loading triggers, or scroll-geometry loading solely
  to implement model caching. If the product must expose records beyond `maximumCachedModelCount`,
  define that user-visible navigation or filtering behavior separately and obtain approval before
  replacing the native table flow.
- The current required limits are `ProxyRulesView.maximumCachedModelCount = 1_000` and
  `ProxyNodesView.maximumCachedModelCount = 300`. Changing either value requires memory validation
  with Instruments.
