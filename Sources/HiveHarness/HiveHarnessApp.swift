import SwiftUI
import HiveHarnessCore

@main
struct HiveHarnessApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("HIVE's Harness", id: "main") {
            ChatView()
                .environment(appState)
                .frame(minWidth: 720, minHeight: 600)
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)

        // 菜单栏常驻:随时唤起、快速提问
        MenuBarExtra("HIVE's Harness", systemImage: "hexagon") {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// 菜单栏菜单内容
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var quickText = ""

    var body: some View {
        // 快速提问输入框(回车即发送)
        TextField("快速提问…", text: $quickText)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                sendQuick()
            }
        Button("发送") {
            sendQuick()
        }
        .disabled(quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Divider()

        Button("打开主窗口") {
            openWindow(id: "main")
        }
        Button("刷新当前人格历史") {
            state.loadHistory()
        }
        Button("清空当前对话") {
            state.clearMessages()
        }

        Divider()

        Button("退出 HIVE's Harness") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func sendQuick() {
        let text = quickText
        quickText = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 打开窗口让用户看到回复,再发送
        openWindow(id: "main")
        Task {
            await state.sendStreaming(text)
        }
    }
}
