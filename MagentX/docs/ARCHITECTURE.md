# Architecture

## Default SwiftUI and SwiftData Stack

- Use SwiftUI as the default framework for the MagentX interface, navigation, windows, menus,
  forms, lists, and tables.
- Use SwiftData as the default persistence framework for application models and local data.
- Define persisted application entities directly with SwiftData's `@Model` unless the business
  requires a separate storage representation.
- Create the production `ModelContainer` at the app composition root and provide it to the SwiftUI
  hierarchy with `.modelContainer`.
- Use `@Environment(\.modelContext)` and `@Query` for View-owned SwiftData access. Keep reusable
  business operations and long-lived state in the responsible Service or Coordinator.
- Keep the default SwiftData store local. Treat iCloud or CloudKit synchronization as an explicit,
  opt-in architecture decision.

### Allowed Exception

- Consider AppKit, Core Data, or a third-party framework only when SwiftUI or SwiftData cannot
  express the required business semantics or platform behavior.
- Before adopting an exception, identify the unsupported capability, compare the available
  alternatives, explain the migration and operational tradeoffs, and obtain explicit approval.

## Application Source Structure

- `Model`: Application models, persisted entities, configuration values, and View-facing model
  state.
- `Service`: Business services and operations that own application capabilities or external side
  effects.
- `View`: SwiftUI interfaces and platform interactions presented to the user.
- `Util`: Reusable general-purpose utilities that contain no business responsibility or lifecycle.
- `Listener`: Listeners registered with macOS system APIs that own their registration resources
  and listener lifecycle.
- `Coordinator`: Stateful modules that coordinate a View with persistence or own a long-running
  background workflow.
- Keep new application code within these existing responsibilities. Do not create a parallel layer
  for the same role without an explicit architecture decision.

## Dependency Injection and Instance Lifecycles

- Register application-layer instances with behavior or lifecycles in the FactoryKit `Container`
  extension in `MagentX/MagentXContainer.swift`. This includes Services, Coordinators, Managers,
  and Executors.
- Do not use `static let shared`, global variables, private caches, or hand-written singletons.
- Use `.cached` when an instance must be unique and retain process-wide state. Otherwise, let its
  Factory provide the lifecycle required by the caller.
- Resolve production dependencies through FactoryKit property wrappers; do not initialize them
  directly or bypass their Factory:
  - Use `@Injected` for ordinary dependencies.
  - Use `@InjectedObject` for SwiftUI `ObservableObject` instances.
  - Use `@InjectedObservable` for Observation `@Observable` instances.
- Keep observable state in the same instance supplied by the Factory.
- When adding or migrating an instance, ensure its application-layer dependencies are also
  Factory-provided. Do not create a second dependency or lifecycle inside the type.
- Keep changes within the requested scope. Report unrelated violations and wait for explicit
  approval before migrating or refactoring them.
- Name injected properties using the `lowerCamelCase` form of their type name. For example, use
  `systemNetworkChangeListsner` for `SystemNetworkChangeListsner`, not `service` or
  `networkService`.

## Libraries and Custom Implementations

### Do

- Check Apple frameworks, existing project dependencies, and established community libraries
  before implementing common capabilities such as encoding, file formats, protocol parsing,
  rule syntax, cryptography, network transport, or database access.
- Prefer an existing API or library when it correctly covers the required semantics. For example,
  use Foundation's `Data` Base64 APIs instead of writing a Base64 codec.
- When proposing a third-party library, evaluate its adoption, maintenance, documentation, tests,
  license, supported Apple platforms, and supported Swift version.
- Before adding a dependency, explain the considered options, selection rationale, license, and
  maintenance status.
- Before writing a custom implementation, explain why available APIs and libraries are unsuitable,
  define the supported syntax or protocol boundary, identify critical edge cases, and add focused
  tests.

### Do Not

- Do not write a custom implementation when an Apple API, existing dependency, or suitable mature
  library already satisfies the requirement.
- Do not add a large library or substantial transitive dependency for a small capability without a
  demonstrated benefit.
- Do not duplicate the same custom parsing or protocol logic across multiple Services.

## Pagination

Every pagination method must treat `pageAt` as a one-based page number. The first page defaults to
`1`, and callers must not pass a zero-based page number.

The pagination method must convert the page number to the underlying offset. SwiftData and database
queries must use the following calculation:

```swift
(pageAt - 1) * pageSize
```

Callers must not subtract `1` before invoking the method, and implementations must not calculate the
offset as `pageAt * pageSize`.

## Unit Testing and Access Control

### Do

- Test methods that callers can access and assert their observable behavior.
- Choose the number of tests from the business behaviors, input boundaries, and branches that need
  coverage.
- Use multiple tests for the same accessible method when success, failure, and boundary scenarios
  require separate coverage.
- Exercise important branches in a `private` method through its nearest accessible entry point.
- Construct inputs or state that reach each relevant private branch, then assert the entry point's
  return value, error, or side effect.
- Keep `private` methods as implementation details.

### Do Not

- Do not require one new test for every added or modified implementation method.
- Do not test a `private` method by calling it directly.
- Do not change a `private` method to `internal` or `public` solely to make it accessible to tests.
- Do not add another access-control workaround that exposes implementation details only for unit
  testing.
