import AppKit
import SwiftUI
import HiveHarnessCore

/// 左侧工作区侧边栏:品牌 / 工作区 / 会话 / 功能 / 用户。
struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Binding var expanded: Bool

    let onMarketplace: () -> Void
    let onWorkbench: () -> Void
    let onRuns: () -> Void
    let onBackground: () -> Void
    let onSettings: () -> Void

    @State private var showArchived = false
    @State private var renameID: String?
    @State private var renameDraft = ""
    @State private var deleteID: String?
    @State private var dragStartWidth: Double?
    @AppStorage(HiveTheme.sidebarWidthKey) private var sidebarWidth = HiveTheme.defaultSidebarWidth

    private var expandedWidth: CGFloat {
        CGFloat(min(360, max(200, sidebarWidth)))
    }

    private var width: CGFloat { expanded ? expandedWidth : 68 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            if expanded {
                newSessionButton
                workspaceSection
                sessionsSection
                Spacer(minLength: 8)
                featuresSection
            } else {
                collapsedActions
                Spacer(minLength: 8)
            }
            userFooter
        }
        .padding(.horizontal, expanded ? 12 : 8)
        .padding(.vertical, 12)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .hiveGlass(corner: 0, tint: HiveTheme.amber.opacity(0.025))
        .overlay(alignment: .trailing) {
            ZStack {
                Rectangle()
                    .fill(HiveTheme.hairline)
                    .frame(width: 1)
                if expanded {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside {
                                NSCursor.resizeLeftRight.set()
                            } else if dragStartWidth == nil {
                                NSCursor.arrow.set()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if dragStartWidth == nil {
                                        dragStartWidth = sidebarWidth
                                    }
                                    let start = dragStartWidth ?? sidebarWidth
                                    sidebarWidth = min(360, max(200, start + value.translation.width))
                                }
                                .onEnded { _ in
                                    dragStartWidth = nil
                                    NSCursor.arrow.set()
                                }
                        )
                        .help("拖动调整侧栏宽度")
                }
            }
            .frame(width: 8)
        }
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    // MARK: - 品牌

    private var brand: some View {
        HStack(spacing: 9) {
            if expanded {
                HiveMark(size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("HIVE'S")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .tracking(0.4)
                    Text("HARNESS")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(HiveTheme.amberDeep)
                }
                Spacer()
                Button {
                    withAnimation { expanded = false }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(HiveTheme.card, in: Circle())
                }
                .buttonStyle(.plain)
                .help("折叠侧边栏")
            } else {
                Button {
                    withAnimation { expanded = true }
                } label: {
                    HiveMark(size: 30)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .help("展开侧边栏")
            }
        }
        .frame(height: 48)
        .padding(.horizontal, expanded ? 2 : 0)
    }

    private var newSessionButton: some View {
        Button {
            state.newSession()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(HiveTheme.amberDeep)
                Text("新会话")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(HiveTheme.softGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(HiveTheme.amber.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }

    // MARK: - 工作区

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("工作区")
            Button {
                NSWorkspace.shared.open(state.workspace)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(HiveTheme.amberDeep)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.workspace.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                        Text(state.workspace.path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .hiveGlass(corner: 9, tint: HiveTheme.amber.opacity(0.025), interactive: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在 Finder 中打开工作区")
        }
        .padding(.top, 16)
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionTitle("会话")
                Spacer()
                Text("\(state.sessions.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(state.sessions) { session in
                        sessionRow(session)
                    }
                }
            }
            .frame(maxHeight: 190)

            if !state.archivedSessions.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showArchived.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("已归档")
                        Text("\(state.archivedSessions.count)")
                            .monospacedDigit()
                        Spacer()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showArchived {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(state.archivedSessions) { session in
                                archivedRow(session)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .padding(.top, 14)
        .alert("重命名会话", isPresented: Binding(
            get: { renameID != nil },
            set: { if !$0 { renameID = nil } }
        )) {
            TextField("会话名称", text: $renameDraft)
            Button("保存") {
                if let id = renameID {
                    state.renameSession(id, title: renameDraft)
                }
                renameID = nil
            }
            Button("取消", role: .cancel) { renameID = nil }
        }
        .confirmationDialog(
            "删除这个会话?",
            isPresented: Binding(
                get: { deleteID != nil },
                set: { if !$0 { deleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let id = deleteID {
                    state.deleteSession(id)
                }
                deleteID = nil
            }
            Button("取消", role: .cancel) { deleteID = nil }
        } message: {
            Text("聊天记录、任务计划与上下文会被一并删除,无法恢复。")
        }
    }

    private func sessionRow(_ session: SessionRecord) -> some View {
        HStack(spacing: 2) {
            Button {
                state.selectSession(session.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: session.id == state.currentThreadID
                          ? "bubble.left.fill"
                          : "bubble.left")
                        .font(.caption)
                        .foregroundStyle(session.id == state.currentThreadID
                                         ? HiveTheme.amberDeep
                                         : .secondary)
                    Text(session.title)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("重命名") {
                    renameID = session.id
                    renameDraft = session.title
                }
                Button("归档") { state.archiveSession(session.id) }
                Divider()
                Button("删除", role: .destructive) { deleteID = session.id }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("会话操作")
        }
        .padding(.trailing, 4)
        .background(
            session.id == state.currentThreadID
                ? HiveTheme.amber.opacity(0.11)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    private func archivedRow(_ session: SessionRecord) -> some View {
        HStack(spacing: 2) {
            Button {
                state.unarchiveSession(session.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "archivebox")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(session.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("恢复并打开")

            Menu {
                Button("重命名") {
                    renameID = session.id
                    renameDraft = session.title
                }
                Button("恢复并打开") { state.unarchiveSession(session.id) }
                Divider()
                Button("删除", role: .destructive) { deleteID = session.id }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.trailing, 4)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
                .padding(.vertical, 8)
            sectionTitle("功能")
            SidebarAction(icon: "storefront", title: "插件市场", action: onMarketplace)
            SidebarAction(icon: "wrench.and.screwdriver", title: "工作台", action: onWorkbench)
            SidebarAction(icon: "clock.arrow.circlepath", title: "运行日志", action: onRuns)
            SidebarAction(
                icon: "rectangle.stack.badge.play",
                title: "后台任务",
                badge: state.backgroundTasks.filter { $0.status == .running }.count,
                action: onBackground
            )
        }
        .padding(.bottom, 8)
    }

    private var collapsedActions: some View {
        VStack(spacing: 10) {
            collapsedButton("plus", help: "新会话") { state.newSession() }
            collapsedDivider
            collapsedButton("folder", help: "打开工作区") {
                NSWorkspace.shared.open(state.workspace)
            }
            Menu {
                ForEach(state.sessions) { session in
                    Button(session.title) { state.selectSession(session.id) }
                }
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 14))
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("会话")
            collapsedDivider
            collapsedButton("storefront", help: "插件市场", action: onMarketplace)
            collapsedButton("wrench.and.screwdriver", help: "工作台", action: onWorkbench)
            collapsedButton("clock.arrow.circlepath", help: "运行日志", action: onRuns)
            collapsedButton("rectangle.stack.badge.play", help: "后台任务", action: onBackground)
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity)
    }

    private var collapsedDivider: some View {
        Rectangle()
            .fill(HiveTheme.hairline)
            .frame(height: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
    }

    // MARK: - 用户

    private var userFooter: some View {
        Button(action: onSettings) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(HiveTheme.gradient)
                        .frame(width: 28, height: 28)
                    Text(NSUserName().prefix(1).uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(NSUserName())
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text("设置与偏好")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, expanded ? 8 : 4)
            .padding(.vertical, 7)
            .hiveGlass(corner: 10, tint: HiveTheme.amber.opacity(0.025), interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开设置")
        .padding(.top, 12)
    }

    // MARK: - 小件

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
    }

    private func collapsedButton(
        _ icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct SidebarAction: View {
    let icon: String
    let title: String
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(HiveTheme.amber.opacity(0.16), in: Capsule())
                        .foregroundStyle(HiveTheme.amberDeep)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
