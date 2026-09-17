# MagentX Agent Guide

## Product Scope

- MagentX is a native macOS network proxy utility, not a Mac Catalyst or cross-platform app.
- The app manages local proxy and PAC services, applies system proxy settings, and reacts to
  system network changes.
- The app supports both a main window and an optional `MenuBarExtra` entry.
- The process can remain active after the last window closes so proxy services continue running in
  the background. Closing a window must not be treated as an explicit app quit.
- Explicit app termination must stop process-level listeners and proxy services and remove the
  system proxy state owned by MagentX.
- Preserve the single-instance app model and the transition between regular window activation and
  menu bar accessory operation.

## Platform Requirements

- Use Swift 6.0 language mode for every MagentX app and test target and for every build
  configuration.
- Support macOS 14.0 and later. Treat macOS 14.0 as the minimum deployment target.
- Use APIs available on macOS 14.0, or add an availability check and a valid macOS 14 fallback.
- Dependencies must support Swift 6.0 and macOS 14.0.
- Do not change the Swift language version or minimum deployment target without an explicit user
  request.

## Required Project Documents

Read the relevant document before changing code. These documents are the source of truth for their
respective areas:

- [Code Style](docs/CODE_STYLE.md): formatting, naming, documentation, access control,
  concurrency, logging, errors, and general SwiftUI code structure.
- [Architecture](docs/ARCHITECTURE.md): dependency injection, instance lifecycles, library
  selection, pagination, and unit-testing boundaries.
- [Design](docs/DESIGN.md): native macOS components, View method review, dedicated list and table
  Views, and native table model limits.

Read every applicable document when a change crosses multiple areas. Do not copy detailed rules
back into this file. If an implementation conflicts with a referenced document, report the conflict
before performing an unrelated migration or broad refactor.

## Change Boundaries

- Keep changes within the user-requested scope and preserve unrelated worktree modifications.
- Inspect the owning code path and its lifecycle before editing it.
- Preserve background proxy behavior when changing app, window, menu bar, settings, or termination
  code.
- Preserve native macOS behavior and use the system components required by the design guide.
- Do not treat a successful build as proof that window, menu bar, background, network, persistence,
  or system proxy lifecycles work at runtime.

## Validation

Run validation proportional to the change and report exactly what was verified.

Check formatting without modifying files:

```bash
./script/swift_format.sh --check
```

Build the macOS app:

```bash
xcodebuild -project MagentX.xcodeproj -scheme MagentX \
  -destination 'platform=macOS' build
```

Run the macOS test targets when the change affects testable behavior:

```bash
xcodebuild -project MagentX.xcodeproj -scheme MagentX \
  -destination 'platform=macOS' test
```

For lifecycle changes, also verify the affected runtime paths, including launch, closing the last
window, reopening the main window, menu bar operation, and explicit termination cleanup.
