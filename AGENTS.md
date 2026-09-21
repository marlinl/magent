# Codex working rules

For non-trivial coding, debugging, algorithmic, logical, or migration tasks:

1. Do not jump directly to the final answer.
2. First identify the task type, constraints, edge cases, and success criteria.
3. If the task contains words like "minimum", "maximum", "guarantee", "worst case", "always", "at least", "sort", "distinguish", "observe", "touch", "mark", or "control", treat it as a worst-case reasoning problem, not as a simple average-case guess.
4. Before editing files, inspect the relevant code paths and summarize the intended change briefly.
5. Before finalizing, verify the result using at least one of:
   - existing tests,
   - a targeted new test,
   - a type check,
   - a lint check,
   - a small manual invariant check.
6. If the first solution seems obvious, pause and look for a counterexample or hidden constraint.
7. In the final response, include:
   - what changed,
   - how it was verified,
   - remaining risks.
8. Do not expose hidden chain-of-thought. Provide only concise rationale, assumptions, and verification notes.


# Repository Guidelines

## Project Structure & Module Organization

This repository contains a shared Swift package and two app targets. `Magent/` is the core SwiftPM package; its
source and test trees are organized by `Connection`, `Core`, `Model`, and `Wire`. Shadowsocks transport and crypto
code lives under `Wire/Shadowsocks`. `MagentX/` is the macOS SwiftUI client; its app code is split into `Model/`,
`View/`, `Controller/`, and `Assets.xcassets`. `iMagent/` is the iOS SwiftUI app scaffold with its own unit and UI
tests.

## Build, Test, and Development Commands

Run package commands from `Magent/`:

```bash
swift build
swift test
swift test --filter AeadCipherTests
swift test --filter ConnectionTests
```

Use Xcode for app iteration, or build from the repository root:

```bash
xcodebuild -project MagentX/MagentX.xcodeproj -scheme MagentX -destination 'platform=macOS' build
xcodebuild -project iMagent/iMagent.xcodeproj -scheme iMagent -destination 'platform=iOS Simulator,name=iPhone 15' test
```

## Swift Formatting

The `Magent/` package uses the official `swift-format` bundled with the selected Xcode toolchain.
Run formatting and lint explicitly from `Magent/`; `Package.swift` does not install a SwiftLint build-tool plugin:

```bash
xcrun swift-format format --in-place --parallel --recursive Package.swift Sources Tests
xcrun swift-format lint --strict --parallel --recursive Package.swift Sources Tests
```

## Error Handling

Do not catch errors inside detail or helper methods to wrap, rename, or route them. Let the original error propagate to the highest owning boundary, and select the response, logging, and close action in one unified error route. If local cleanup requires `catch`, rethrow the original error unchanged after cleanup.

## Magent Proxy/Core Boundary Notes

The reusable package is configured through `MagentConfig` and controlled through `Magent.start`,
`restart`, and `close`. Magent owns its EventLoopGroup and listener. The application owns permissions,
persistence, UI, and system proxy integration. See [Magent architecture](Magent/docs/ARCHITECTURE.md)
and the more specific rules in [Magent/AGENTS.md](Magent/AGENTS.md).

`MagentTCPConnection` owns accepted-channel protocol detection and lifecycle. It selects one concrete
connection: `Socks4Connection`, `Socks5Connection`, `HttpConnectConnection`, or `HttpForwardConnection`.
The concrete Connection parses the local protocol, generates local success/failure replies, and owns its
downstream Channel. Its `closeConnection(error:)` closes downstream resources only; the accepted Channel
remains owned by `MagentTCPConnection`.

`MagentCore` is created for one start/restart runtime. It matches rules, caches `Decision` values, resolves
nodes by UUID, selects Wire implementations, and creates downstream Channels. It does not parse local
HTTP/SOCKS payloads. Configuration and Core initialization happen before restart closes the old runtime.

`Wire` owns remote protocol encoding state and exposes the selected proxy endpoint and timeout. It does
not own Channels or generate local HTTP/SOCKS replies. Each proxied TCP connection gets its own
`ShadowsocksTCPWire`; a startup handshake carries the target, and subsequent writes carry tunnel payload.
`ShadowsocksUDPWire` uses independent packet encryption state.

Each SOCKS5 control connection owns an ephemeral IPv4 UDP relay, an IPv6 outbound Channel, and an optional
DNS client. Control close releases these resources. The association fixes the first UDP client source and
records actual outbound endpoints with their selected Wire for response decoding.

## MagentX UI Layout Notes

Treat `MagentX/View/ContentView.swift` as the app-level navigation shell. It should define native macOS navigation and the selected content area only; it should not impose extra frames, nested split layouts, fixed window sizes, or custom chrome on the page views it hosts.

Do not start UI work by drawing the interface from scratch with generic `VStack`/`HStack` layouts. First look for the Apple-provided SwiftUI/AppKit component that already matches the interaction, such as `NavigationSplitView`, `List`, `Form`, `Table`, `OutlineGroup`, `Settings`, `MenuBarExtra`, `ToolbarItem`, `Inspector`, `TabView`, `Picker`, `Toggle`, or native sheets and panels. Assume roughly 90% of MagentX screens should be achievable with system components. If a view becomes complex enough that native components cannot express the required behavior cleanly, ask before designing a custom-drawn replacement.

Keep `ContentView`-owned navigation types, including section enums and closely related constants/helpers, in `MagentX/View/ContentView.swift`. Do not scatter these shell-specific definitions into generic state, model, or component files just to make compilation convenient.

Use native macOS SwiftUI components for the sidebar and window behavior. Prefer `NavigationSplitView` with a `.sidebar` `List` over hand-rolled sidebar rows, custom liquid-glass surfaces, custom traffic-light buttons, or custom resize handles. The sidebar should contain only navigation items unless a design explicitly requires more.

For the current MagentX shell, `ContentView` owns sidebar visibility, toolbar chrome, page title/subtitle, and page-level toolbar buttons. Prefer the native `NavigationSplitView` sidebar toggle in the window toolbar; do not add custom duplicate sidebar toggle buttons or AppKit split-view limiters.

Do not add AppKit introspection, `NSSplitView` delegates, or split-view controller bridges just to force `NavigationSplitView` sidebar drag limits. Treat `.navigationSplitViewColumnWidth(min:ideal:max:)` as the supported SwiftUI expression, and remember that the actual minimum is also constrained by the native sidebar/List intrinsic content, system padding, and window chrome. If a narrower rail is required, design an explicit compact sidebar mode instead of fighting the native split view.

After editing a single UI file, inspect that file before moving on and remove dead helper types, unused imports, or speculative bridges that did not directly solve the issue.

Do not reintroduce `PanelView` as a shared middle container for MagentX pages. `ContentView` should route directly to concrete page views and pass a toolbar button binding down so each page can publish its own toolbar actions while owning its internal content layout.

## MagentX Model & Persistence Notes

Treat MagentX as a small-to-medium macOS SwiftUI app. Prefer straightforward SwiftData models over layered enterprise-style persistence abstractions.

When defining persisted app models, use SwiftData's `@Model` annotation directly on the app model type unless there is a clear reason to separate domain and storage representations. For example, `ProxyNode` should be the persisted `@Model` type itself, not split into `ProxyNode` plus `StoredProxyNode` by default.

Keep the model focused on the entity's fields, defaults, validation, and lightweight computed properties. Storage destination choices, such as local-only versus optional iCloud/CloudKit sync, belong in the model container/store configuration rather than in duplicate model types. Default persistence should be local; iCloud/CloudKit support should be opt-in.

## Testing Guidelines

The project uses XCTest. Mirror the package source areas under `Magent/Tests/Connection`, `Core`, `Model`, and
`Wire`; keep Shadowsocks tests under `Magent/Tests/Wire/Shadowsocks`. App tests belong to the relevant Xcode test
target. Cover crypto, packet parsing, connection errors, and protocol state machines with deterministic unit tests.
Keep integration tests that require a Shadowsocks server clearly named and filterable.

## Commit & Pull Request Guidelines

Recent history uses short commits such as `feat: add mac application`; prefer concise imperative messages and use a conventional prefix when helpful (`feat:`, `fix:`, `test:`). Pull requests should describe behavior changes, list validation commands, link related issues, and include screenshots or screen recordings for MagentX or iMagent UI changes.

## Security & Configuration Tips

Never commit real Shadowsocks passwords, node addresses, or user proxy settings. Use sample values in docs and tests, and keep local app state in UserDefaults or ignored development files.
