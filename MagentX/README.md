# MagentX

MagentX 是 Magent 的 macOS SwiftUI 客户端，用于管理 Shadowsocks 节点、本地代理服务、代理规则和应用配置。

## Developer

- Author: MarlinL
- Project: MagentX macOS client
- Core package: `../Magent`

## Project Scope

MagentX is treated as a small-to-medium macOS SwiftUI app. The app favors direct SwiftData `@Model` types and straightforward service/controller boundaries over layered persistence abstractions.

## Directory Structure

```text
MagentX/MagentX/
├── MagentXApp.swift
├── MagentXError.swift
├── Model/
│   ├── CurrentSelection.swift
│   ├── GeneralSettings.swift
│   ├── MagentNode.swift
│   └── MagentProxyRule.swift
├── Service/
│   ├── MagentProxyRuleService.swift
│   ├── MagentService.swift
│   └── SystemNetworkProxyService.swift
├── Controller/
│   ├── NodeController.swift
│   └── SettingsController.swift
├── View/
│   ├── ContentView.swift
│   ├── DashboardView.swift
│   ├── ProxyNodesView.swift
│   ├── ProxyPolicyView.swift
│   ├── ProxyRulesView.swift
│   └── AppSettingsView.swift
└── Assets.xcassets/
```

## Architecture

```text
SwiftUI Views
    ↓ direct model actions or controller coordination
Controllers
    ↓ CRUD and refresh orchestration
SwiftData Models
    ↓ local persistence by default
Services
    ↓ subscription download and parsing
Magent Swift Package
    ↓ proxy protocol, routing, crypto, and connection state
Network
```

## Models

- `ProxyNode`: persisted proxy node configuration. The first supported node type is Shadowsocks.
- `GeneralSettings`: persisted global app configuration, including launch-at-login, menu bar behavior, local proxy listening, optional iCloud sync preference, and the rules subscription URL.
- `CurrentSelection`: persisted selection state for the active proxy node.
- `MagentProxyRule`: persisted proxy rule used directly by `ProxyRulesView`, including typed direct/proxy decisions.

## Services

`MagentProxyRuleService` downloads and parses the configured rule subscription, then merges imported rules tagged with `source = "rulesUrl"` into SwiftData on its model actor.

`MagentProxyRuleService` rewrites the complete persisted proxy rule set to the app-local `pac.json` after a subscription refresh. `MagentService` serves the latest file through the local PAC HTTP endpoint.

## Controllers

- `NodeController`: manages `ProxyNode` CRUD through SwiftData.
- `SettingsController`: manages default settings records and menu bar background behavior.

## Core Package Dependencies

MagentX depends on the local Swift package at `../Magent`:

- `Magent`: app-facing local proxy client, network address types, proxy node values, protocol handling, and connection state.

## Persistence

Default persistence is local SwiftData storage. iCloud/CloudKit sync is an app setting and should remain opt-in. Do not split a model into separate storage/domain representations unless the product needs that complexity.

## Build

```bash
xcodebuild -project MagentX/MagentX.xcodeproj -scheme MagentX \
  -destination 'platform=macOS' build
```

## Test

```bash
xcodebuild -project MagentX/MagentX.xcodeproj -scheme MagentX \
  -destination 'platform=macOS' test
```
