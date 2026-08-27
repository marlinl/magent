# Magent

A lightweight local proxy client built entirely in Swift. Magent opens local HTTP and SOCKS5 proxy ports on your machine, routing traffic through a Shadowsocks server — enabling secure, private network access.

## Project Structure

```
magent/
├── AGENTS.md                    # 贡献与协作说明
├── Magent/                      # 共享底层 Swift Package
│   ├── Package.swift            # SwiftPM manifest
│   ├── Sources/
│   │   ├── Crypto/              # MagentCrypto — AEAD 加解密核心
│   │   └── Local/               # MagentLocal — 代理协议 + Shadowsocks 传输
│   └── Tests/
│       ├── CryptoTests/
│       └── LocalTests/
├── MagentX/                     # macOS 客户端 (SwiftUI + SwiftNIO)
│   ├── MagentX.xcodeproj/
│   ├── MagentX/
│   │   ├── MagentXApp.swift     # App 入口
│   │   ├── Model/               # AppState、节点、策略、设置模型
│   │   ├── Controller/          # ProxyManager、SOCKS5/HTTP proxy server
│   │   ├── View/                # Dashboard、Nodes、Policy、Settings 页面
│   │   └── Assets.xcassets/
│   ├── MagentXTests/
│   ├── MagentXUITests/
│   ├── docs/design-prompts/     # 界面设计提示文档
│   ├── prototype.html           # 早期界面原型
│   └── README.md
├── iMagent/                     # iOS 客户端 (SwiftUI)
│   ├── iMagent.xcodeproj/
│   ├── iMagent/
│   ├── iMagentTests/
│   └── iMagentUITests/
├── .gitignore
├── .gitmodules                  # Shadowsocks upstream references
└── README.md
```

### Module Dependencies

```
┌──────────────┐  ┌──────────────┐
│   MagentX    │  │   iMagent    │
│  (macOS App) │  │  (iOS App)   │
└──────┬───────┘  └──────┬───────┘
       │                 │
       └────────┬────────┘
                │ depends on
                ▼
      ┌──────────────────┐
      │   Magent Package │
      │  ┌────────────┐  │
      │  │ MagentLocal │  │  ← LocalProxy 协议 + ShadowsocksProxy
      │  └─────┬──────┘  │
      │        │          │
      │  ┌─────┴──────┐  │
      │  │MagentCrypto│  │  ← AEAD 加密 (AES-GCM, ChaCha20-Poly1305)
      │  └─────┬──────┘  │
      │        │          │
      │  ┌─────┴──────┐  │
      │  │ swift-crypto│  │
      │  │ swift-nio   │  │
      │  └────────────┘  │
      └──────────────────┘
```

## Features

- **Dual Proxy Protocols** — Local HTTP and SOCKS5 proxy ports
- **Shadowsocks Backend** — Full AEAD encryption support via pure Swift crypto module
- **Pure Swift** — The entire project, including networking and crypto, is written in Swift
- **Cross-Platform** — Native macOS (MagentX) and iOS (iMagent) apps

## Supported Platforms

- **macOS** 12+ — MagentX
- **iOS** 15+ — iMagent

## Encryption

Magent implements Shadowsocks AEAD encryption in pure Swift:

- AES-128-GCM, AES-256-GCM
- ChaCha20-Poly1305
- XChaCha20-Poly1305 (via HChaCha20 key derivation)

## Getting Started

### Build Magent Package

```bash
cd Magent
swift build
swift test
```

Integration tests that need a real Shadowsocks server are skipped by default.
Run them only with local environment variables:

```bash
MAGENT_SS_HOST=server.example.com \
MAGENT_SS_PORT=8388 \
MAGENT_SS_PASSWORD=example-password \
swift test --filter LocalProxyTests
```

### Build MagentX (macOS)

Open `MagentX/MagentX.xcodeproj` in Xcode and build.

### Build iMagent (iOS)

Open `iMagent/iMagent.xcodeproj` in Xcode and build.

## License

No license file is included yet.
