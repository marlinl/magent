import Foundation
import NIOCore
import NIOPosix


/// Magent Core 层的 Wire 匹配入口。
/// A service-owned Core instance. Its lifetime is independent from other Magent instances;
/// callers must serialize configuration mutations with the owning service lifecycle.
internal final class MagentCore: @unchecked Sendable {

    private let defaultDecision: Decision
    private let enableMatchTable: Bool
    private let routeCache: MagentCache<Decision>
    private let router: MagentRouter
    internal let defaultTimeout: Int64

    /// 以节点 UUID 为 key 保存当前可用的代理节点；相同 UUID 的新配置覆盖旧配置。
    private var nodes: [UUID: ProxyNode]
    private var addressNodes: [SocketAddress: UUID]
    private var udpWires: [UUID: Wire]

    internal init(defaultDecision: Decision, defaultProxyNode: ProxyNode, enableMatchTable: Bool,
        defaultTimeout: Int64, rules: [ProxyRule]) throws {
        self.defaultDecision = defaultDecision
        self.enableMatchTable = enableMatchTable
        self.routeCache = MagentCache(capacity: enableMatchTable ? 4096 : 0)
        self.router = try MagentRouter(rules)
        self.defaultTimeout = defaultTimeout
        self.nodes = [:]
        self.addressNodes = [:]
        self.udpWires = [:]
        try putProxyNode(defaultProxyNode)
    }

    /// 根据代理节点类型创建对应的 UDP Wire；创建失败时原样向上抛出异常。
    private func createUDPWire(_ node: ProxyNode) throws -> Wire {
        switch node.type {
        case .shadowsocks:
            return try ShadowsocksUDPWire(proxyNode: node)
        }
    }

    private func createTCPWire(_ node: ProxyNode) throws -> Wire {
        switch node.type {
        case .shadowsocks:
            return try ShadowsocksTCPWire(proxyNode: node)
        }
    }

    /// 批量写入代理节点；相同 UUID 按数组顺序覆盖，未包含的已有节点保持不变。
    internal func putAllProxyNodes(_ nodes: [ProxyNode]) throws {
        for node in nodes {
            try putProxyNode(node)
        }
    }

    /// 写入或覆盖单个代理节点。
    ///
    /// UDP Wire 必须经由 `createUDPWire(_:)` 创建，
    /// 使节点类型与对应 Wire 的映射只保留在一个位置。
    internal func putProxyNode(_ node: ProxyNode) throws {
        if let existingNodeID = addressNodes[node.address], existingNodeID != node.id {
            throw MagentError.invalidPolicy(
                "proxy node address \(node.address) is already used by \(existingNodeID)"
            )
        }

        let udpWire = try createUDPWire(node)
        if let previousNode = nodes[node.id], previousNode.address != node.address {
            addressNodes.removeValue(forKey: previousNode.address)
        }
        nodes[node.id] = node
        addressNodes[node.address] = node.id
        udpWires[node.id] = udpWire
    }

    /// 返回目标地址的路由决策。
    private func routeDecision(_ address: NetworkAddress) -> Decision {
        let key = Self.routeCacheKey(address)
        if let decision = routeCache.get(key) {
            return decision
        }

        return routeCache.getOrLoad(key) { _ in
            guard enableMatchTable else {
                return defaultDecision
            }
            return router.match(address) ?? defaultDecision
        }
    }

    /// 根据目标地址匹配路由决策并获得对应的 TCP Wire。
    ///
    /// 路由决策按地址类型和 host/IP 缓存。
    /// 当前规则不匹配端口，因此 cache key 不包含端口。
    /// 未启用匹配表或没有规则命中时，使用初始化时传入的默认决策。
    internal func routeTCPWire(_ address: NetworkAddress) throws -> Wire? {
        let decision = routeDecision(address)
        switch decision {
        case .direct:
            return nil

        case .proxy(let nodeID):
            guard let node = nodes[nodeID] else {
                throw MagentError.proxyNodeNotFound(nodeID)
            }
            return try createTCPWire(node)
        }
    }

    /// 根据目标地址匹配路由决策并获得对应的 UDP Wire。
    ///
    /// `.direct` 返回 `nil`；`.proxy` 引用不存在的节点时抛出错误，禁止将代理配置错误降级为直连。
    internal func routeUDPWire(_ address: NetworkAddress) throws -> Wire? {
        let decision = routeDecision(address)
        switch decision {
        case .direct:
            return nil

        case .proxy(let nodeID):
            guard nodes[nodeID] != nil, let wire = udpWires[nodeID] else {
                throw MagentError.proxyNodeNotFound(nodeID)
            }
            return wire
        }
    }

    /// 为路由决策缓存构造稳定 key，并区分域名、IPv4 和 IPv6 地址。
    private static func routeCacheKey(_ address: NetworkAddress) -> String {
        switch address {
        case .domain(let host, _):
            return "domain:\(host.lowercased())"

        case .ipv4(let bytes, _):
            return "ipv4:\(bytes.base64EncodedString())"

        case .ipv6(let bytes, _):
            return "ipv6:\(bytes.base64EncodedString())"
        }
    }

    /// 使用指定 EventLoopGroup 创建下游 TCP client Channel。
    ///
    /// handler 在 Channel 激活前安装，避免连接成功后先收到数据再补装 handler。
    /// 返回的 Channel 关闭自动读取、允许远端 half-close，且每次显式读取最多产生一条消息，
    /// 由具体协议连接在下游写入完成后发起下一次读取并处理输入方向关闭。
    internal func createTCPClientChannel(group: EventLoopGroup, address: NetworkAddress, timeout: Int64,
        handler: ChannelHandler & Sendable) -> EventLoopFuture<Channel> {
        guard !address.host.isEmpty, (1...65535).contains(address.port) else {
            return group.next().makeFailedFuture(MagentError.invalidAddress("Invalid TCP destination"))
        }
        guard timeout > 0 else {
            return group.next().makeFailedFuture(
                MagentError.invalidOptions("TCP connection timeout must be greater than zero")
            )
        }

        return ClientBootstrap(group: group)
            .connectTimeout(.milliseconds(timeout))
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
            .connect(host: address.host, port: address.port)
            .flatMapErrorThrowing { error in
                if let channelError = error as? ChannelError, case .connectTimeout = channelError {
                    throw MagentError.channelConnectionTimedOut
                }
                throw MagentError.channelCreationFailed(String(describing: error))
            }
    }

    /// 使用已经解析完成的 NIO SocketAddress 创建下游 TCP client Channel。
    ///
    /// Wire 的目标地址已经是 SocketAddress，直接使用 `connect(to:)`，
    /// 避免重新转换成 NetworkAddress。
    /// 返回的 Channel 使用和 NetworkAddress 重载相同的手动读取约束。
    internal func createTCPClientChannel(group: EventLoopGroup, address: SocketAddress, timeout: Int64,
        handler: ChannelHandler & Sendable) -> EventLoopFuture<Channel> {
        if let port = address.port, !(1...65535).contains(port) {
            return group.next().makeFailedFuture(MagentError.invalidAddress("Invalid TCP destination"))
        }
        guard timeout > 0 else {
            return group.next().makeFailedFuture(
                MagentError.invalidOptions("TCP connection timeout must be greater than zero")
            )
        }

        return ClientBootstrap(group: group)
            .connectTimeout(.milliseconds(timeout))
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
            .connect(to: address)
            .flatMapErrorThrowing { error in
                if let channelError = error as? ChannelError, case .connectTimeout = channelError {
                    throw MagentError.channelConnectionTimedOut
                }
                throw MagentError.channelCreationFailed(String(describing: error))
            }
    }

    /// 使用指定 EventLoopGroup 和本地 SocketAddress 绑定 UDP Channel。
    internal func createUDPClientChannel(group: EventLoopGroup, address: SocketAddress,
        handler: ChannelHandler & Sendable) -> EventLoopFuture<Channel> {
        return DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(
                ChannelOptions.recvAllocator,
                value: FixedSizeRecvByteBufferAllocator(capacity: 65_535)
            )
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
            .bind(to: address)
            .flatMapErrorThrowing { error in
                throw MagentError.channelCreationFailed(String(describing: error))
            }
    }
}

// MARK: - MagentRouter

/// 初始化时构建的不可变路由表。
///
/// 这里故意不再定义“编译规则”或“匹配目标”等中间类型。
/// 规则本体、原始顺序、特异度和各类索引使用相同的数组下标关联，
/// 既保持数据结构直接，也让路由状态在初始化后保持不可变。
private struct MagentRouter: Sendable {
    /// 经过规范化和去重的规则。
    private let rules: [ProxyRule]

    /// 规则在初始化参数中的位置，用作所有显式优先级相同时的稳定决胜条件。
    private let sequences: [Int]

    /// 同一 `order` 下的匹配特异度：精确域名高于后缀，后缀高于关键字；
    /// CIDR 使用前缀长度。
    private let specificities: [Int]

    /// 规范化完整域名到规则下标的索引。
    private let exactDomains: [String: Int]

    /// 规范化域名后缀到规则下标的索引。
    private let domainSuffixes: [String: Int]

    /// 小写关键字到规则下标的索引。
    /// 关键字需要执行包含判断，因此匹配时仍需线性扫描。
    private let domainKeywords: [String: Int]

    /// 已规范化 CIDR 到规则下标的索引。
    /// 当前规模下线性扫描清晰且足够，后续可独立替换为前缀树。
    private let ipRanges: [NetworkCIDR: Int]

    /// 去重并索引已经由 `ProxyRule` 规范化的完整规则集合。
    ///
    /// 相同类型和相同规范化匹配值被视为同一条逻辑规则。
    /// 重复出现时最后一条生效，这使配置文件后面的规则可以明确覆盖前面的同值规则，
    /// 同时仍由该规则自己的 `order` 参与全局优先级比较。
    fileprivate init(_ sourceRules: [ProxyRule]) throws {
        var compiledRules: [ProxyRule] = []
        var compiledSequences: [Int] = []
        var compiledSpecificities: [Int] = []
        var compiledCIDRs: [NetworkCIDR?] = []
        var identityIndexes: [String: Int] = [:]

        for (sequence, rule) in sourceRules.enumerated() {
            let identity: String
            let specificity: Int
            let cidr: NetworkCIDR?

            switch rule.matchType {
            case .exactDomain:
                identity = "exactDomain|\(rule.matchValue)"
                specificity = 4_000 + rule.matchValue.utf8.count
                cidr = nil

            case .domainSuffix:
                identity = "domainSuffix|\(rule.matchValue)"
                specificity = 3_000 + rule.matchValue.split(separator: ".").count
                cidr = nil

            case .domainKeyword:
                identity = "domainKeyword|\(rule.matchValue)"
                specificity = 1_000 + rule.matchValue.utf8.count
                cidr = nil

            case .ipCIDR:
                let parsedCIDR = try NetworkCIDR(rule.matchValue)
                identity = "ipCIDR|\(rule.matchValue)"
                specificity = 2_000 + parsedCIDR.prefixLength
                cidr = parsedCIDR

            case .urlRegex:
                throw MagentError.invalidPolicy("urlRegex is not supported by MagentRouter")
            }

            if let existingIndex = identityIndexes[identity] {
                compiledRules[existingIndex] = rule
                compiledSequences[existingIndex] = sequence
                compiledSpecificities[existingIndex] = specificity
                compiledCIDRs[existingIndex] = cidr
            } else {
                identityIndexes[identity] = compiledRules.count
                compiledRules.append(rule)
                compiledSequences.append(sequence)
                compiledSpecificities.append(specificity)
                compiledCIDRs.append(cidr)
            }
        }

        var exactDomainIndex: [String: Int] = [:]
        var domainSuffixIndex: [String: Int] = [:]
        var domainKeywordIndex: [String: Int] = [:]
        var ipRangeIndex: [NetworkCIDR: Int] = [:]

        for index in compiledRules.indices {
            let rule = compiledRules[index]

            switch rule.matchType {
            case .exactDomain:
                exactDomainIndex[rule.matchValue] = index

            case .domainSuffix:
                domainSuffixIndex[rule.matchValue] = index

            case .domainKeyword:
                domainKeywordIndex[rule.matchValue] = index

            case .ipCIDR:
                guard let cidr = compiledCIDRs[index] else {
                    throw MagentError.invalidPolicy("missing compiled CIDR: \(rule.matchValue)")
                }
                ipRangeIndex[cidr] = index

            case .urlRegex:
                throw MagentError.invalidPolicy("urlRegex is not supported by MagentRouter")
            }
        }

        rules = compiledRules
        sequences = compiledSequences
        specificities = compiledSpecificities
        exactDomains = exactDomainIndex
        domainSuffixes = domainSuffixIndex
        domainKeywords = domainKeywordIndex
        ipRanges = ipRangeIndex
    }

    /// 匹配目标地址并返回最高优先级规则的决策。
    ///
    /// 优先级依次为：更小的 `order`、更高的特异度、更早的初始化参数位置。
    /// 最后一项只负责保证结果稳定，不会覆盖调用方显式设置的 `order`。
    ///
    /// 热点地址通常由外层缓存以均摊 O(1) 返回。缓存未命中时，
    /// 精确域名平均 O(1)，后缀 O(标签数)，关键字 O(关键字数量 × 域名长度)，
    /// CIDR O(CIDR 数量 × 16 字节)。
    fileprivate func match(_ address: NetworkAddress) -> Decision? {
        var bestIndex: Int?

        func consider(_ candidateIndex: Int?) {
            guard let candidateIndex else { return }
            guard let currentIndex = bestIndex else {
                bestIndex = candidateIndex
                return
            }

            let candidateRule = rules[candidateIndex]
            let currentRule = rules[currentIndex]

            if candidateRule.order != currentRule.order {
                if candidateRule.order < currentRule.order {
                    bestIndex = candidateIndex
                }
                return
            }

            if specificities[candidateIndex] != specificities[currentIndex] {
                if specificities[candidateIndex] > specificities[currentIndex] {
                    bestIndex = candidateIndex
                }
                return
            }

            if sequences[candidateIndex] < sequences[currentIndex] {
                bestIndex = candidateIndex
            }
        }

        switch address {
        case .domain(let host, _):
            guard let normalizedHost = try? Self.normalizedDomain(host) else { return nil }

            consider(exactDomains[normalizedHost])

            var suffixCandidate = normalizedHost[...]
            while true {
                consider(domainSuffixes[String(suffixCandidate)])
                guard let dotIndex = suffixCandidate.firstIndex(of: ".") else { break }
                suffixCandidate = suffixCandidate[suffixCandidate.index(after: dotIndex)...]
            }

            for (keyword, ruleIndex) in domainKeywords where normalizedHost.contains(keyword) {
                consider(ruleIndex)
            }

        case .ipv4, .ipv6:
            for (cidr, ruleIndex) in ipRanges where cidr.contains(address) {
                consider(ruleIndex)
            }
        }

        guard let bestIndex else { return nil }
        return rules[bestIndex].decision
    }

    /// 将配置域名和请求域名转换为同一种比较形式，
    /// 并拒绝无法作为 DNS 主机名执行的规则。
    private static func normalizedDomain(_ value: String) throws -> String {
        let domain = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)

        guard domain.isEmpty == false, domain.utf8.count <= 253 else {
            throw MagentError.invalidPolicy("invalid domain: \(value)")
        }

        for label in labels {
            let bytes = label.utf8
            let hasValidLength = bytes.isEmpty == false && bytes.count <= 63
            let hasValidEdges = bytes.first != 45 && bytes.last != 45
            let hasValidCharacters = bytes.allSatisfy { byte in
                (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
            }

            guard hasValidLength, hasValidEdges, hasValidCharacters else {
                throw MagentError.invalidPolicy("invalid domain: \(value)")
            }
        }

        return domain
    }
}

// MARK: - NetworkCIDR

/// 一段规范化后的 IPv4 或 IPv6 CIDR 网络。
///
/// 初始化时会清零主机位，所以 `192.168.1.25/24` 与 `192.168.1.0/24` 是同一个值。
/// 这个性质同时保证了重复规则去重和 `Hashable` 比较使用网络语义，
/// 而不是依赖用户输入的文本形式。
private struct NetworkCIDR: Hashable, Sendable {
    /// 已清零主机位的 4 字节 IPv4 或 16 字节 IPv6 网络地址。
    private let network: Data

    /// 网络前缀长度；IPv4 为 `0...32`，IPv6 为 `0...128`。
    fileprivate let prefixLength: Int

    /// 解析一个 IPv4 或 IPv6 CIDR。省略前缀时按单主机网络处理，即 IPv4 `/32`、IPv6 `/128`。
    fileprivate init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let address = Self.addressBytes(String(parts[0])) else {
            throw MagentError.invalidPolicy("invalid CIDR: \(value)")
        }

        let prefix: Int
        if parts.count == 2 {
            guard let parsedPrefix = Int(parts[1]) else {
                throw MagentError.invalidPolicy("invalid CIDR prefix: \(value)")
            }
            prefix = parsedPrefix
        } else {
            prefix = address.count * 8
        }

        guard (0...(address.count * 8)).contains(prefix) else {
            throw MagentError.invalidPolicy("invalid CIDR prefix: \(value)")
        }

        network = Self.masked(address, prefixLength: prefix)
        prefixLength = prefix
    }

    /// 判断目标地址是否属于当前网络。
    /// IPv4 与 IPv6 严格隔离，域名不会在这里触发 DNS 解析。
    fileprivate func contains(_ address: NetworkAddress) -> Bool {
        let addressBytes: Data

        switch address {
        case .ipv4(let data, _):
            guard network.count == 4 else { return false }
            addressBytes = data

        case .ipv6(let data, _):
            guard network.count == 16 else { return false }
            addressBytes = data

        case .domain:
            return false
        }

        guard addressBytes.count == network.count else { return false }

        let fullByteCount = prefixLength / 8
        guard addressBytes.prefix(fullByteCount) == network.prefix(fullByteCount) else { return false }

        let remainingBitCount = prefixLength % 8
        guard remainingBitCount > 0 else { return true }

        let mask = UInt8.max << UInt8(8 - remainingBitCount)
        return addressBytes[fullByteCount] & mask == network[fullByteCount] & mask
    }

    /// 使用 NIO 的字面量解析，避免自行实现 IPv6 压缩格式和字节序处理。
    private static func addressBytes(_ value: String) -> Data? {
        guard let address = try? SocketAddress(ipAddress: value, port: 0) else { return nil }

        switch address {
        case .v4(let ipv4):
            return withUnsafeBytes(of: ipv4.address.sin_addr) { Data($0) }

        case .v6(let ipv6):
            return withUnsafeBytes(of: ipv6.address.sin6_addr) { Data($0) }

        case .unixDomainSocket:
            return nil
        }
    }

    /// 清零前缀之后的所有位，使等价 CIDR 具有完全相同的存储值。
    private static func masked(_ address: Data, prefixLength: Int) -> Data {
        var result = address

        for index in result.indices {
            let byteStartBit = index * 8
            if byteStartBit + 8 <= prefixLength {
                continue
            }

            if byteStartBit >= prefixLength {
                result[index] = 0
                continue
            }

            let retainedBitCount = prefixLength - byteStartBit
            let mask = UInt8.max << UInt8(8 - retainedBitCount)
            result[index] &= mask
        }

        return result
    }
}
