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
│   ├── AccessControlRule.swift
│   ├── CurrentSelection.swift
│   ├── GeneralSettings.swift
│   ├── MagentNode.swift
│   ├── MagentProxyRule.swift
│   ├── ProxyPolicy.swift
│   └── ProxyPolicyRule.swift
├── Service/
│   ├── AclService.swift
│   ├── MagentProxyService.swift
│   ├── PacFileService.swift
│   └── SystemNetworkProxyService.swift
├── Controller/
│   ├── NodeController.swift
│   ├── PolicyController.swift
│   └── SettingsController.swift
├── View/
│   ├── ContentView.swift
│   ├── DashboardView.swift
│   ├── ProxyNodesView.swift
│   ├── ProxyPolicyView.swift
│   ├── ProxyRulesView.swift
│   └── SystemSettingsView.swift
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
- `GeneralSettings`: persisted global app configuration, including launch-at-login, menu bar behavior, local proxy listening, optional iCloud sync preference, the rules subscription URL, and the PSL download URL.
- `CurrentSelection`: persisted selection state for the active proxy node.
- `AccessControlRule`: persisted access-control rule. The rule-list refresh path stores imported rules with `source = "rulesUrl"`.
- `MagentProxyRule`: persisted proxy rule used directly by `ProxyRulesView`, including typed direct/proxy decisions.
- `ProxyPolicy`: persisted policy group with its own id, display name, suffix domain text, and optional selected Magent node id.
- `ProxyPolicyRule`: persisted join between a `ProxyPolicy` id and an `AccessControlRule` id.

## Services

`AclService` downloads and parses an access-control subscription list. It stores downloaded GFWList data as `~/.MagentX/gfwlist.txt`, stores Public Suffix List data as `~/.MagentX/PSL.dat`, and imports lightweight `AccessControlRuleImport` records tagged with `source = "rulesUrl"` as `MagentProxyRule` values on a background model context.

`PacFileService` compiles the complete persisted proxy rule set into `~/.MagentX/proxy.pac`. `ProxyRulesView` rewrites that file after subscription refreshes, and `MagentProxyService` serves the latest file through the local PAC HTTP endpoint.

## Controllers

- `NodeController`: manages `ProxyNode` CRUD through SwiftData.
- `PolicyController`: manages proxy policy business operations through SwiftData.
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

To run only the Magent proxy rule subscription-import tests:

```bash
xcodebuild -project MagentX/MagentX.xcodeproj -scheme MagentX \
  -destination 'platform=macOS' \
  -only-testing:MagentXTests/AclServiceMagentProxyRuleTests test
```
