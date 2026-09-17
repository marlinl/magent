# Code Style

## Formatting

- Treat `.swift-format` as the source of truth for automated Swift formatting.
- Use two spaces for each indentation level.
- Do not use tab characters.
- Keep one primary top-level type per file when practical. Closely related nested types may
  remain with their owner.
- Limit lines to 100 characters.

Run the repository formatting script before submitting Swift changes:

```shell
./script/swift_format.sh
```

Use its check mode when files must not be modified:

```shell
./script/swift_format.sh --check
```

## Naming

- Use `UpperCamelCase` for type names.
- Use `lowerCamelCase` for function, property, variable, and parameter names.
- Name protocols after the capability or responsibility they describe, not a specific
  implementation.

## Documentation

Every Swift type declaration must have a `///` documentation comment that describes the type's
business responsibility. This requirement applies to every `class`, `struct`, `enum`, `actor`, and
`protocol`, including `private` types.

Every non-`private` function must have a `///` documentation comment that explains its purpose,
primary side effects, or return semantics.

## Access Control

Prefer the narrowest access level that supports the required callers.

Helper functions used only within their declaring type must be `private`. Functions called by a
View, Controller, test, or protocol callback should retain the appropriate access level and include
a documentation comment.

Use restricted setters when external code may read a property but must not mutate it:

```swift
private(set) var state
```

## Concurrency

- Prefer structured concurrency.
- Do not use `Task.detached` unless explicit isolation requirements justify it.
- Give mutable shared state explicit isolation. Prefer an actor for service state and
  `@MainActor` for UI-bound state.

## Logging

- Use the appropriate `AppLog` category, backed by Apple's `OSLog.Logger`, for production
  logging.
- Do not use `print()` in production code.

## Errors

- Do not silently swallow errors.
- Avoid `try?` unless the failure is intentionally irrelevant.
- Define all MagentX app-layer errors as cases of `MagentXError` in
  `MagentX/MagentXError.swift`.
- Do not declare local `Error` or `LocalizedError` enums in Controllers, Services, Models, or Views.
  Add a new case to `MagentXError` when the app layer needs a new error.

## SwiftUI

- Keep `body` declarative.
- Start with native macOS SwiftUI components before introducing a custom layout.
- Keep one-use native components directly in `body`; do not create rendering helper functions
  solely to shorten it.
- Extract a complex section into a private `View` type or a dedicated component only when it has an
  independent or reusable responsibility.
- Do not own or start long-lived business processes directly in View state. Keep their lifecycle
  in the appropriate injected application service.
