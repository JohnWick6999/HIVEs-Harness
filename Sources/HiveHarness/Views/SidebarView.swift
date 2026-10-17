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
    let onSettings: () -> Void

    private var width: CGFloat { expanded ? 232 : 64 }

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
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(HiveTheme.hairline)
                .frame(width: 1)
        }
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    // MARK: - 品牌

    private var brand: some View {
        HStack(spacing: 9) {
            if expanded {
                HiveMark(size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("HIVE")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .tracking(0.6)
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
                    VStack(spacing: 3) {
                        HiveMark(size: 30)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .help("展开侧边栏")
            }
        }
        .frame(height: 44)
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
        .padding(.top, 8)
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
                .background(HiveTheme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在 Finder 中打开工作区")
        }
        .padding(.top, 14)
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
                    ForEach(state.sessions.prefix(20)) { session in
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
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                session.id == state.currentThreadID
                                    ? HiveTheme.amber.opacity(0.11)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 190)
        }
        .padding(.top, 12)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionTitle("功能")
            SidebarAction(icon: "storefront", title: "插件市场", action: onMarketplace)
            SidebarAction(icon: "wrench.and.screwdriver", title: "工作台", action: onWorkbench)
            SidebarAction(icon: "clock.arrow.circlepath", title: "运行日志", action: onRuns)
        }
        .padding(.bottom, 8)
    }

    private var collapsedActions: some View {
        VStack(spacing: 6) {
            collapsedButton("plus", help: "新会话") { state.newSession() }
            collapsedButton("folder", help: "打开工作区") {
                NSWorkspace.shared.open(state.workspace)
            }
            Menu {
                ForEach(state.sessions) { session in
                    Button(session.title) { state.selectSession(session.id) }
                }
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("会话")
            collapsedButton("storefront", help: "插件市场", action: onMarketplace)
            collapsedButton("wrench.and.screwdriver", help: "工作台", action: onWorkbench)
            collapsedButton("clock.arrow.circlepath", help: "运行日志", action: onRuns)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
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
            .background(HiveTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开设置")
        .padding(.top, 8)
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
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct SidebarAction: View {
    let icon: String
    let title: String
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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
