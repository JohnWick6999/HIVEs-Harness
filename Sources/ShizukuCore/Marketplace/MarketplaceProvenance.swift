import Foundation

/// 市场安装来源清单(写入技能目录 `.marketplace.json`,只读展示/审计)。
public struct MarketplaceProvenance: Codable, Sendable, Equatable {
    public var itemID: String
    public var name: String
    public var source: String
    public var installURL: String
    public var ref: String
    public var sha256: String
    /// GitHub blob SHA-1 / ModelScope Sha256(远端声明的校验值)
    public var remoteHash: String?
    /// 插件在仓库内的子目录
    public var installPath: String?
    public var installedAt: String

    public init(
        itemID: String,
        name: String,
        source: String,
        installURL: String,
        ref: String,
        sha256: String,
        remoteHash: String? = nil,
        installPath: String? = nil,
        installedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.itemID = itemID
        self.name = name
        self.source = source
        self.installURL = installURL
        self.ref = ref
        self.sha256 = sha256
        self.remoteHash = remoteHash
        self.installPath = installPath
        self.installedAt = installedAt
    }
}
