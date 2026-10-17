import AppKit
import SwiftUI
import HiveHarnessCore

/// 插件市场:内置目录 + GitHub + 魔搭,瀑布流卡片,链接导入与安装预检。
struct MarketplaceView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var source: MarketplaceSource?
    @State private var items: [MarketplaceItem] = []
    @State private var errors: [String] = []
    @State private var loading = false
    @State private var loadingMore = false
    @State private var page = 1
    @State private var hasMore = false
    @State private var selected: MarketplaceItem?
    @State private var showImport = false
    @State private var showToken = false
    @State private var showStudio = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !errors.isEmpty {
                Text(errors.joined(separator: "\n"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                Divider()
            }
            content
        }
        .frame(minWidth: 900, minHeight: 620)
        .task(id: "\(query)|\(source?.rawValue ?? "all")") {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
        .sheet(item: $selected) { item in
            MarketplaceDetailView(item: item)
                .environment(state)
        }
        .sheet(isPresented: $showImport) {
            importSheet
        }
        .sheet(isPresented: $showToken) {
            tokenSheet
        }
        .sheet(isPresented: $showStudio) {
            PluginStudioView()
                .environment(state)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "storefront")
                Text("插件市场").font(.title3.weight(.semibold))
            }
            Spacer()
            TextField("搜索技能 / 插件 / 作者", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            Picker("来源", selection: $source) {
                Text("全部").tag(MarketplaceSource?.none)
                ForEach(MarketplaceSource.allCases) { item in
                    Text(item.title).tag(Optional(item))
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            Button("插件工坊") { showStudio = true }
            Button("导入链接") { showImport = true }
            Button {
                showToken = true
            } label: {
                Image(systemName: "key")
            }
            .help("设置 GitHub Token(提高 API 配额)")
            Button("关闭") { dismiss() }
        }
        .padding(12)
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                if loading && items.isEmpty {
                    ProgressView("正在加载市场…")
                        .padding(60)
                } else if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("没有找到匹配的插件")
                            .font(.headline)
                        Text("试试导入 GitHub / 魔搭链接,或换个关键词。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(60)
                } else {
                    waterfall
                    if loadingMore {
                        ProgressView("加载更多…")
                            .padding(20)
                    } else if hasMore {
                        Button("加载更多") {
                            Task { await load(reset: false) }
                        }
                        .padding(16)
                    }
                }
            }
        }
    }

    private var waterfall: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<3, id: \.self) { column in
                LazyVStack(spacing: 12) {
                    ForEach(
                        Array(items.enumerated()).filter { $0.offset % 3 == column },
                        id: \.element.id
                    ) { pair in
                        card(pair.element)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(12)
    }

    private func card(_ item: MarketplaceItem) -> some View {
        Button {
            selected = item
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    icon(item)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(item.author.isEmpty ? item.source.title : item.author)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(item.kind.title)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(item.summary.isEmpty ? "暂无描述" : item.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.tags.isEmpty {
                    Text(item.tags.prefix(4).map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let stars = item.stars {
                        Label("\(stars)", systemImage: "star")
                    }
                    if let downloads = item.downloads {
                        Label("\(downloads)", systemImage: "arrow.down.circle")
                    }
                    Spacer()
                    Text(item.source.title)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            if item.id == items.last?.id, hasMore, !loadingMore {
                Task { await load(reset: false) }
            }
        }
    }

    private func icon(_ item: MarketplaceItem) -> some View {
        AsyncImage(url: item.iconURL.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Image(systemName: iconName(item.kind))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.3))
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func iconName(_ kind: MarketplaceKind) -> String {
        switch kind {
        case .skill: return "wand.and.stars"
        case .mcp: return "server.rack"
        case .plugin: return "puzzlepiece.extension"
        }
    }

    // MARK: - 加载

    private func load(reset: Bool) async {
        if reset {
            page = 1
            loading = true
        } else {
            guard hasMore, !loadingMore else { return }
            loadingMore = true
        }
        let requestedPage = page
        let result = await state.searchMarketplace(
            query: query,
            source: source,
            page: requestedPage
        )
        if reset {
            items = result.items
        } else {
            let existing = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
        }
        errors = result.errors
        hasMore = result.hasMore
        page = requestedPage + 1
        loading = false
        loadingMore = false
    }

    // MARK: - 导入

    private var importSheet: some View {
        ImportSheet(
            onResolve: { raw in
                let item = try await state.importMarketplaceLink(raw)
                showImport = false
                selected = item
            }
        )
    }

    private var tokenSheet: some View {
        TokenSheet(initial: state.githubToken) { token in
            state.setGitHubToken(token)
            showToken = false
        }
    }
}

// MARK: - 导入

private struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onResolve: (String) async throws -> Void

    @State private var text = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入插件来源").font(.headline)
            Text("支持 GitHub 仓库、ModelScope 技能页,例如:\nhttps://github.com/owner/repo\nhttps://modelscope.cn/skills/@anthropics/skill-creator")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("https://…", text: $text)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("解析") {
                    Task {
                        loading = true
                        do {
                            try await onResolve(text)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        loading = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loading || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - Token

private struct TokenSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String) -> Void
    @State private var token: String

    init(initial: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _token = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub Token").font(.headline)
            Text("可选。只保存在钥匙串,用于提高 GitHub API 配额(未认证仅 60 次/时)。")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("ghp_…", text: $token)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(token)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - 详情与安装预检

private struct MarketplaceDetailView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let item: MarketplaceItem

    @State private var plan: MarketplaceInstallPlan?
    @State private var loading = false
    @State private var installing = false
    @State private var error: String?
    @State private var message: String?
    @State private var expanded: [MarketplaceItem] = []
    @State private var expanding = false
    @State private var selectedChild: MarketplaceItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.title3.weight(.semibold))
                    Text("\(item.author) · \(item.source.title) · \(item.kind.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text(item.summary.isEmpty ? "暂无描述" : item.summary)
                .font(.callout)

            HStack(spacing: 14) {
                if let stars = item.stars { Label("\(stars) stars", systemImage: "star") }
                if let downloads = item.downloads { Label("\(downloads) downloads", systemImage: "arrow.down.circle") }
                if let license = item.license { Label(license, systemImage: "doc.text") }
                if let url = item.homepage.flatMap(URL.init(string:)) {
                    Link("打开来源", destination: url)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            if loading {
                ProgressView("正在检查安装内容…")
                    .padding(.vertical, 20)
            } else if let plan {
                planView(plan)
            } else if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if item.kind == .plugin {
                Divider()
                HStack {
                    Text("插件市场目录")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button(expanding ? "展开中…" : "展开子插件") {
                        Task { await expand() }
                    }
                    .disabled(expanding)
                }
                if !expanded.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(expanded) { child in
                                Button {
                                    selectedChild = child
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "puzzlepiece.extension")
                                            .foregroundStyle(.secondary)
                                        Text(child.name).font(.caption.weight(.medium))
                                        Text(child.summary)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .task { await prepare() }
        .sheet(item: $selectedChild) { child in
            MarketplaceDetailView(item: child)
                .environment(state)
        }
    }

    @ViewBuilder
    private func planView(_ plan: MarketplaceInstallPlan) -> some View {
        if plan.isBuiltin {
            Text("内置技能已随 App 预装,可直接在对话中通过 list_skills / run_skill 使用。")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            if !plan.files.isEmpty {
                Text("将安装 \(plan.files.count) 个技能\(plan.ref.isEmpty ? "" : "(ref: \(plan.ref))")")
                    .font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.files, id: \.skillID) { file in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(file.skillID).font(.caption.weight(.medium))
                                Text(file.path).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
            }

            if !plan.mcpServers.isEmpty {
                Text("将写入 \(plan.mcpServers.count) 个 MCP 服务器(默认停用)")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.mcpServers) { server in
                        HStack(spacing: 6) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.secondary)
                            Text(server.name).font(.caption.weight(.medium))
                            Text(server.type == "http" ? server.url : "\(server.command) \(server.args.joined(separator: " "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !plan.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if !plan.overwriting.isEmpty {
                Text("将覆盖已有技能: \(plan.overwriting.joined(separator: "、"))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("安装器只写入 SKILL.md,不会执行仓库中的脚本。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(installing ? "安装中…" : "确认安装") {
                    install(plan)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(installing)
            }
        }
    }

    private func expand() async {
        expanding = true
        do {
            expanded = try await state.expandMarketplaceItem(item)
        } catch {
            self.error = error.localizedDescription
        }
        expanding = false
    }

    private func prepare() async {
        loading = true
        do {
            plan = try await state.planMarketplaceInstall(item)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func install(_ plan: MarketplaceInstallPlan) {
        installing = true
        do {
            let skills = try state.installMarketplacePlan(plan)
            var parts: [String] = []
            if !skills.isEmpty {
                parts.append("技能 " + skills.map(\.name).joined(separator: "、"))
            }
            if !plan.mcpServers.isEmpty {
                parts.append("MCP \(plan.mcpServers.count) 个(默认停用)")
            }
            message = "已安装: " + parts.joined(separator: " · ")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        installing = false
    }
}
