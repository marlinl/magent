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
│   ├── MagentService.swift
│   └── SystemNetworkSettingService.swift
├── Coordinator/
│   └── SyncProxyRulesCoordinator.swift
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
Coordinators and Services
    ↓ subscription synchronization and runtime operations
Magent Swift Package
    ↓ proxy protocol, routing, crypto, and connection state
Network
```

## Models

- `ProxyNode`: persisted proxy node configuration. The first supported node type is Shadowsocks.
- `GeneralSettings`: persisted global app configuration, including launch-at-login, menu bar behavior, local proxy listening, optional iCloud sync preference, and the rules subscription URL.
- `CurrentSelection`: persisted selection state for the active proxy node.
- `MagentProxyRule`: persisted proxy rule used directly by `ProxyRulesView`, including typed direct/proxy decisions.

## Coordinators and Services

`SyncProxyRulesCoordinator` is a Factory-managed process singleton. It owns the observable synchronization state, downloads and parses the configured rule subscription, then merges imported rules tagged with `source = "rulesUrl"` into SwiftData without blocking the main actor.

`MagentService` manages the local Magent proxy runtime. `SystemNetworkSettingService` coordinates runtime activation and system network proxy settings.

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
