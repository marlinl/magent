import Foundation

/// Magent 代理核心错误。
///
/// 这些错误用于描述协议解析、地址、策略、节点引用、加密以及连接生命周期相关的
/// 中断原因。
/// 关联值通常保存更具体的上下文，便于日志或 UI 展示。
public enum MagentError: Error, Equatable, Sendable {
    /// HTTP/SOCKS/Shadowsocks 等协议解析出的目标地址不合法。
    case invalidAddress(String)

    /// 本地代理请求或远端节点返回的数据格式不符合协议要求。
    case malformedRequest(String)

    /// 调用方传入的运行选项不合法，或当前状态下不允许执行该操作，
    /// 例如不支持的代理命令（SOCKS BIND 等）。
    case invalidOptions(String)

    /// 加密、解密、派生密钥或认证校验失败；关联值包含错误类型和具体内容。
    case cryptoError(String)

    /// 代理规则配置不合法，例如匹配值为空或 proxy 规则没有引用节点。
    case invalidPolicy(String)

    /// 代理规则引用的节点 UUID 在当前节点表中不存在。
    case proxyNodeNotFound(UUID)

    /// 连接已经关闭，不能继续读写或推进代理链路。
    case connectionClosed

    /// Magent 代理服务状态或运行失败。
    case serverFailed(String)

    /// 创建、连接或绑定 NIO Channel 失败。
    case channelCreationFailed(String)

    /// NIO Channel 连接超时。
    case channelConnectionTimedOut

    /// 构造不带附加内容的加密错误描述。
    internal static func cryptoError(type: String) -> Self {
        .cryptoError(type)
    }

    /// 构造包含期望值和实际值的加密错误描述。
    internal static func cryptoError(type: String, expected: Int, actual: Int) -> Self {
        .cryptoError("\(type): expected \(expected), actual \(actual)")
    }

    /// 构造包含底层错误类型和内容的加密错误描述。
    internal static func cryptoError(type: String, underlying error: Error) -> Self {
        let errorType = String(reflecting: Swift.type(of: error))
        return .cryptoError("\(type): \(errorType): \(String(describing: error))")
    }
}
