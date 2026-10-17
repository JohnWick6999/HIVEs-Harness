import AppKit
import Quartz
import SwiftUI
import WebKit
import HiveHarnessCore

enum ArtifactKind: String, CaseIterable, Identifiable, Codable {
    case html
    case pdf
    case image
    case office
    case text
    case code
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .html: return "网页 / HTML"
        case .pdf: return "PDF"
        case .image: return "图片"
        case .office: return "Office 文档"
        case .text: return "文本 / Markdown"
        case .code: return "代码"
        case .other: return "其他文件"
        }
    }

    var icon: String {
        switch self {
        case .html: return "safari"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .office: return "doc.text"
        case .text: return "text.alignleft"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc"
        }
    }

    static func from(extension ext: String) -> ArtifactKind {
        switch ext.lowercased() {
        case "html", "htm", "xhtml": return .html
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg": return .image
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf": return .office
        case "md", "markdown", "txt", "json", "yaml", "yml", "csv", "log", "xml", "plist": return .text
        case "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "css", "scss", "sh", "zsh", "sql", "toml":
            return .code
        default: return .other
        }
    }
}

enum ArtifactOpenMode: String, CaseIterable, Identifiable, Codable {
    case sidebar
    case window
    case external

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sidebar: return "右侧边栏"
        case .window: return "独立窗口"
        case .external: return "系统默认应用"
        }
    }

    var icon: String {
        switch self {
        case .sidebar: return "sidebar.right"
        case .window: return "macwindow"
        case .external: return "arrow.up.forward.app"
        }
    }
}

struct Artifact: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let name: String
    let kind: ArtifactKind

    init(url: URL, name: String? = nil) {
        self.id = UUID()
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.kind = ArtifactKind.from(extension: url.pathExtension)
    }

    init(attachment: FileAttachment) {
        self.init(url: URL(fileURLWithPath: attachment.path), name: attachment.name)
    }
}

enum ArtifactPreferences {
    static func key(for kind: ArtifactKind) -> String {
        "artifact.openMode.\(kind.rawValue)"
    }

    static func mode(for kind: ArtifactKind) -> ArtifactOpenMode {
        let raw = UserDefaults.standard.string(forKey: key(for: kind)) ?? ""
        return ArtifactOpenMode(rawValue: raw) ?? .sidebar
    }

    static func set(_ mode: ArtifactOpenMode, for kind: ArtifactKind) {
        UserDefaults.standard.set(mode.rawValue, forKey: key(for: kind))
    }
}

struct ArtifactPreviewPanel: View {
    let artifact: Artifact
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: artifact.kind.icon)
                    .foregroundStyle(HiveTheme.amberDeep)
                VStack(alignment: .leading, spacing: 1) {
                    Text(artifact.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(artifact.kind.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(artifact.url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .help("用系统默认应用打开")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭预览")
            }
            .padding(12)
            .hiveGlass(corner: 0, tint: HiveTheme.amber.opacity(0.03))

            Rectangle().fill(HiveTheme.hairline).frame(height: 1)
            preview
        }
        .frame(minWidth: 320, idealWidth: 430, maxWidth: 620)
        .frame(maxHeight: .infinity)
        .hiveGlass(corner: 0, tint: HiveTheme.amber.opacity(0.02))
    }

    @ViewBuilder
    private var preview: some View {
        switch artifact.kind {
        case .html:
            ArtifactWebView(url: artifact.url)
        case .text, .code:
            ArtifactTextView(url: artifact.url, isCode: artifact.kind == .code)
        default:
            ArtifactQuickLookView(url: artifact.url)
        }
    }
}

private struct ArtifactWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        load(in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url { load(in: view) }
    }

    private func load(in view: WKWebView) {
        if url.isFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: url))
        }
    }
}

private struct ArtifactQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }
}

private struct ArtifactTextView: View {
    let url: URL
    let isCode: Bool

    private var text: String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取文件"
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(size: 11, design: isCode ? .monospaced : .rounded))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
