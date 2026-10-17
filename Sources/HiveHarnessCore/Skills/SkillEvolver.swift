import Foundation

/// 一次成功运行的可复盘轨迹。
public struct AgentTrajectory: Sendable, Equatable {
    public var userMessage: String
    public var reply: String
    public var persona: String
    public var threadID: String
    public var traces: [ToolTrace]
    public var createdAt: Date

    public init(
        userMessage: String,
        reply: String,
        persona: String,
        threadID: String,
        traces: [ToolTrace],
        createdAt: Date = Date()
    ) {
        self.userMessage = userMessage
        self.reply = reply
        self.persona = persona
        self.threadID = threadID
        self.traces = traces
        self.createdAt = createdAt
    }
}

/// 自动生成的技能提案:先落盘待审,批准后才进入技能库。
public struct SkillProposal: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var tags: [String]
    public var body: String
    public var reason: String
    public var sourceThreadID: String
    public var author: String
    public var createdAt: Date
    /// create / patch
    public var action: String?
    /// patch 时的目标技能 id
    public var targetID: String?
    /// 静态扫描出的风险提示
    public var warnings: [String]?

    public init(
        id: String,
        name: String,
        description: String,
        tags: [String] = [],
        body: String,
        reason: String = "",
        sourceThreadID: String = "",
        author: String = "HIVE (evolved)",
        createdAt: Date = Date(),
        action: String = "create",
        targetID: String? = nil,
        warnings: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.tags = tags
        self.body = body
        self.reason = reason
        self.sourceThreadID = sourceThreadID
        self.author = author
        self.createdAt = createdAt
        self.action = action
        self.targetID = targetID
        self.warnings = warnings
    }
}

/// 技能自进化:从成功轨迹生成提案,人工批准后写入技能目录。
public final class SkillEvolver: @unchecked Sendable {
    public let skillsDirectory: URL
    public let proposalsDirectory: URL
    private let lock = NSLock()

    public init(skillsDirectory: URL) {
        self.skillsDirectory = skillsDirectory.standardizedFileURL
        self.proposalsDirectory = skillsDirectory
            .standardizedFileURL
            .appendingPathComponent("_proposals", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: proposalsDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - 提案列表

    public func proposals() -> [SkillProposal] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: proposalsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SkillProposal? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SkillProposal.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 反思生成

    /// 分析成功轨迹;没有可复用流程时返回 nil。
    public func consider(
        trajectory: AgentTrajectory,
        existingSkills: [Skill],
        reflect: @Sendable (_ system: String, _ user: String) async throws -> String
    ) async -> SkillProposal? {
        guard !trajectory.traces.isEmpty else { return nil }
        let existingIDs = existingSkills.map(\.id)
        let catalog = existingSkills.prefix(40)
            .map { "- \($0.id): \($0.name) — \($0.description)" }
            .joined(separator: "\n")
        let user = Self.transcript(trajectory)
            + "\n\n现有技能(优先 patch,避免重复创建):\n"
            + (catalog.isEmpty ? "（无）" : catalog)

        guard let raw = try? await reflect(Self.systemPrompt, String(user.prefix(12_000))),
              !raw.isEmpty,
              let response = Self.decodeResponse(raw),
              response.skip != true,
              let name = response.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              let description = response.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              let body = response.body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              !description.isEmpty,
              body.count >= 40,
              body.count <= 24_000
        else { return nil }

        if Self.isOneOffName(name) { return nil }
        let action = (response.action ?? "create").lowercased()
        let warnings = Self.riskWarnings(body)
        let tags = Array((response.tags ?? []).prefix(5))
        let summary = String(description.prefix(60))

        if action == "patch" {
            guard let target = response.target?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let skill = existingSkills.first(where: { $0.id == target })
            else { return nil }
            let proposal = SkillProposal(
                id: target,
                name: skill.name,
                description: summary,
                tags: tags,
                body: body,
                reason: String((response.reason ?? "").prefix(500)),
                sourceThreadID: trajectory.threadID,
                action: "patch",
                targetID: target,
                warnings: warnings
            )
            save(proposal)
            return proposal
        }

        guard let proposedID = response.id else { return nil }
        var used = Set(existingIDs)
        used.formUnion(proposals().map(\.id))
        let id = Self.uniqueID(Self.sanitize(proposedID), used: &used)
        let proposal = SkillProposal(
            id: id,
            name: String(name.prefix(80)),
            description: summary,
            tags: tags,
            body: body,
            reason: String((response.reason ?? "").prefix(500)),
            sourceThreadID: trajectory.threadID,
            action: "create",
            warnings: warnings
        )
        save(proposal)
        return proposal
    }

    // MARK: - 批准 / 拒绝

    @discardableResult
    public func approve(_ proposal: SkillProposal) throws -> Skill {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-evolved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let tags = proposal.tags
            .map { $0.replacingOccurrences(of: ",", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let description = proposal.description
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ":", with: "：")
        let markdown = """
        ---
        id: \(proposal.id)
        name: \(proposal.name)
        description: \(description)
        version: 0.1.0
        author: \(proposal.author)
        tags: [\(tags)]
        enabled: true
        ---

        \(proposal.body)
        """
        try markdown.write(
            to: temp.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let store = SkillStore(userDirectory: skillsDirectory)
        let skill = try store.install(from: temp)
        try? FileManager.default.removeItem(at: proposalURL(proposal.id))
        return skill
    }

    public func reject(_ proposal: SkillProposal) throws {
        let url = proposalURL(proposal.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - 持久化

    private func save(_ proposal: SkillProposal) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(proposal) else { return }
        try? data.write(to: proposalURL(proposal.id), options: .atomic)
    }

    private func proposalURL(_ id: String) -> URL {
        proposalsDirectory.appendingPathComponent("\(id).json")
    }

    // MARK: - Prompt / 解析

    static let systemPrompt = """
    你是技能整理器。分析一次成功的 Agent 运行,判断是否存在可复用于未来类似任务的流程。
    只有当流程具有复用价值时才生成技能;一次性事实、闲聊、简单问答返回 {"skip":true,"reason":"..."}。
    优先级:能扩展现有技能就 patch,只有确实不同才 create;禁止为 PR/issue/错误串/一次性任务建技能。
    严格输出 JSON,不要 Markdown 代码块:
    {"skip":false,"action":"create|patch","target":"现有技能 id(仅 patch)","id":"kebab-case","name":"技能名","description":"不超过 60 字,说明何时触发","tags":["tag"],"body":"Markdown 步骤","reason":"为什么值得复用"}
    要求:
    - id 为 3-40 位小写字母/数字/短横线,例如 file-diff-review
    - body 为 6-20 行可执行步骤,写清输入、工具、验证方式与失败处理
    - 不包含密钥、令牌、用户绝对路径、破坏性命令或未实际发生的步骤
    - description 硬上限 60 字,用于技能索引路由
    """

    static func transcript(_ trajectory: AgentTrajectory) -> String {
        var lines = [
            "用户: \(String(trajectory.userMessage.prefix(1_500)))",
            "工具调用:",
        ]
        for trace in trajectory.traces.prefix(12) {
            let arguments = String(trace.arguments.prefix(300))
            let result = String(trace.result.prefix(400))
            lines.append("- \(trace.tool)(\(arguments)) -> \(result)")
        }
        lines.append("助手: \(String(trajectory.reply.prefix(1_500)))")
        let joined = lines.joined(separator: "\n")
        return String(joined.prefix(8_000))
    }

    struct ProposalResponse: Decodable {
        var skip: Bool?
        var reason: String?
        var action: String?
        var target: String?
        var id: String?
        var name: String?
        var description: String?
        var tags: [String]?
        var body: String?
    }

    static func decodeResponse(_ raw: String) -> ProposalResponse? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n")
        }
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProposalResponse.self, from: data)
    }

    // MARK: - 校验辅助

    static func isOneOffName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if name.contains("#") { return true }
        if lower.hasPrefix("pr ") || lower.hasPrefix("issue ") { return true }
        if lower.hasPrefix("fix ") && lower.contains("bug") { return true }
        return false
    }

    static func riskWarnings(_ body: String) -> [String] {
        let patterns = [
            "rm -rf /", "| sh", "| bash", "~/.ssh", "chmod 777", "base64 -d", "sudo ",
        ]
        return patterns
            .filter { body.localizedCaseInsensitiveContains($0) }
            .map { "包含高风险命令模式: \($0)" }
    }

    // MARK: - ID

    static func sanitize(_ raw: String) -> String {
        var result = ""
        for character in raw.lowercased() {
            if (character.isASCII && character.isLetter)
                || (character.isASCII && character.isNumber)
                || character == "-" {
                result.append(character)
            } else {
                result.append("-")
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        if result.count < 3 { result = "auto-skill" }
        return String(result.prefix(40))
    }

    static func uniqueID(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var index = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        used.insert(candidate)
        return candidate
    }
}
