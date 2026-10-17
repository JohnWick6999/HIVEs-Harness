import Foundation

enum OfficeApplication: String {
    case word
    case excel
    case powerpoint

    var displayName: String {
        switch self {
        case .word: return "Microsoft Word"
        case .excel: return "Microsoft Excel"
        case .powerpoint: return "Microsoft PowerPoint"
        }
    }

    var path: String {
        switch self {
        case .word: return "/Applications/Microsoft Word.app"
        case .excel: return "/Applications/Microsoft Excel.app"
        case .powerpoint: return "/Applications/Microsoft PowerPoint.app"
        }
    }
}

enum OfficeFormat: String {
    case docx
    case xlsx
    case pptx
    case pdf

    var app: OfficeApplication {
        switch self {
        case .docx: return .word
        case .xlsx: return .excel
        case .pptx, .pdf: return .powerpoint
        }
    }

    static func from(url: URL) -> OfficeFormat? {
        OfficeFormat(rawValue: url.pathExtension.lowercased())
    }
}

enum OfficeAutomation {
    static func ensureInstalled(_ app: OfficeApplication) throws {
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw ToolError.execution("未安装 \(app.displayName)。本工具需要 Microsoft Office 16+。")
        }
    }

    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let parts = escaped.components(separatedBy: "\n")
        return parts.map { "\"\($0)\"" }.joined(separator: " & linefeed & ")
    }

    static func run(_ script: String, arguments: [String], timeout: TimeInterval = 120) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let box = OfficeProcessBox(process)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { box.terminate() }
        timer.resume()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()

        let output = String(data: data.prefix(128_000), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ToolError.execution(
                "\(process.terminationStatus == 15 ? "Office 自动化超时" : "Office 自动化失败"): \(output.suffix(1_200))"
            )
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prepareOutput(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

private final class OfficeProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var terminated = false

    init(_ process: Process) { self.process = process }

    func terminate() {
        lock.lock()
        if terminated { lock.unlock(); return }
        terminated = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }
}

// MARK: - Read

public struct OfficeReadTool: Tool {
    public let name = "office_read"
    public let spec = ToolSpec(
        name: "office_read",
        description: "Read text/content from Microsoft Word .docx, Excel .xlsx, or PowerPoint .pptx using the installed Microsoft Office apps. Requires Full Control mode and approval.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string", "description": "Office 文件路径"],
            ]),
            "required": AnyCodable(["path"]),
        ]
    )
    private let safePath: SafePath

    public init(workspace: URL) {
        self.safePath = SafePath(workspace: workspace)
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard let raw = arguments["path"]?.value as? String else {
            throw ToolError.invalidArguments("office_read 需要 path")
        }
        let url = safePath.resolveAny(raw)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.execution("文件不存在: \(url.path)")
        }
        guard let format = OfficeFormat.from(url: url), format != .pdf else {
            throw ToolError.invalidArguments("office_read 支持 docx/xlsx/pptx")
        }
        try OfficeAutomation.ensureInstalled(format.app)
        let output: String
        switch format {
        case .docx:
            output = try readWord(url)
        case .xlsx:
            output = try readExcel(url)
        case .pptx:
            output = try readPowerPoint(url)
        case .pdf:
            throw ToolError.invalidArguments("PDF 请使用 read_pdf")
        }
        return ToolResult(text: String(output.prefix(16_000)), files: [url])
    }

    private func readWord(_ url: URL) throws -> String {
        let script = """
        on run argv
          set inPath to item 1 of argv
          tell application "Microsoft Word"
            set d to open file name inPath
            set resultText to content of text object of d
            try
              close d saving no
            end try
            return resultText
          end tell
        end run
        """
        return try OfficeAutomation.run(script, arguments: [url.path])
    }

    private func readExcel(_ url: URL) throws -> String {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-read-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: temp) }
        let script = """
        on run argv
          set inPath to item 1 of argv
          set outPath to item 2 of argv
          tell application "Microsoft Excel"
            set wb to open workbook filename inPath
            save workbook as wb filename outPath file format CSV file format
          end tell
        end run
        """
        _ = try OfficeAutomation.run(script, arguments: [url.path, temp.path])
        return (try? String(contentsOf: temp, encoding: .utf8)) ?? ""
    }

    private func readPowerPoint(_ url: URL) throws -> String {
        let script = """
        on run argv
          set inPath to item 1 of argv
          tell application "Microsoft PowerPoint"
            set pres to open inPath
            set outText to ""
            repeat with s in slides of pres
              repeat with shp in shapes of s
                try
                  if has text frame of shp then
                    set outText to outText & (content of text range of text frame of shp) & linefeed
                  end if
                end try
              end repeat
            end repeat
            return outText
          end tell
        end run
        """
        return try OfficeAutomation.run(script, arguments: [url.path])
    }
}

// MARK: - Create

public struct OfficeCreateTool: Tool {
    public let name = "office_create"
    public let spec = ToolSpec(
        name: "office_create",
        description: "Create a Microsoft Office file. Use type docx with text; xlsx with rows [[...],[...]]; pptx with slides [{title,body}]. Requires Full Control mode and approval.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string", "description": "输出路径,扩展名决定类型"],
                "type": ["type": "string", "enum": ["docx", "xlsx", "pptx"]],
                "text": ["type": "string", "description": "docx 正文"],
                "rows": ["type": "array", "description": "xlsx 二维数组"],
                "slides": ["type": "array", "description": "pptx 幻灯片数组"],
            ]),
            "required": AnyCodable(["path"]),
        ]
    )
    private let safePath: SafePath

    public init(workspace: URL) {
        self.safePath = SafePath(workspace: workspace)
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard let raw = arguments["path"]?.value as? String else {
            throw ToolError.invalidArguments("office_create 需要 path")
        }
        let url = safePath.resolveAny(raw)
        let declared = (arguments["type"]?.value as? String)?.lowercased()
        guard let format = declared.flatMap(OfficeFormat.init(rawValue:)) ?? OfficeFormat.from(url: url),
              format != .pdf
        else { throw ToolError.invalidArguments("类型必须是 docx/xlsx/pptx") }
        try OfficeAutomation.ensureInstalled(format.app)
        try OfficeAutomation.prepareOutput(url)
        switch format {
        case .docx:
            let text = arguments["text"]?.value as? String ?? ""
            try createWord(text, at: url)
        case .xlsx:
            let rows = (arguments["rows"]?.value as? [[Any]]) ?? []
            try createExcel(rows, at: url)
        case .pptx:
            let slides = (arguments["slides"]?.value as? [[String: Any]]) ?? []
            try createPowerPoint(slides, at: url)
        case .pdf:
            throw ToolError.invalidArguments("请使用 office_export_pdf")
        }
        return ToolResult(text: "已创建 \(format.rawValue.uppercased()): \(url.path)", files: [url])
    }

    private func createWord(_ text: String, at url: URL) throws {
        let script = """
        on run argv
          set outPath to item 1 of argv
          set bodyText to item 2 of argv
          tell application "Microsoft Word"
            activate
            set d to make new document
            set content of text object of d to bodyText
            save as d file name outPath file format format document
            try
              close d saving no
            end try
          end tell
        end run
        """
        _ = try OfficeAutomation.run(script, arguments: [url.path, String(text.prefix(200_000))])
    }

    private func createExcel(_ rows: [[Any]], at url: URL) throws {
        var commands: [String] = []
        for (r, row) in rows.prefix(500).enumerated() {
            for (c, cell) in row.prefix(100).enumerated() {
                let address = "\(Self.column(c))\(r + 1)"
                let value = (cell as? String) ?? String(describing: cell)
                commands.append("set value of range \"\(address)\" of active sheet of wb to \(OfficeAutomation.quote(value))")
            }
        }
        let body = commands.joined(separator: "\n")
        let script = """
        on run argv
          set outPath to item 1 of argv
          tell application "Microsoft Excel"
            activate
            set wb to make new workbook
            \(body)
            save workbook as wb filename outPath file format workbook normal file format
          end tell
        end run
        """
        _ = try OfficeAutomation.run(script, arguments: [url.path])
    }

    private func createPowerPoint(_ slides: [[String: Any]], at url: URL) throws {
        var commands: [String] = []
        for slide in slides.prefix(60) {
            let title = slide["title"] as? String ?? ""
            let body = slide["body"] as? String ?? ""
            commands.append("set s to make new slide at end of pres")
            commands.append("set tb to make new text box at s with properties {left position:60, top:50, width:760, height:90}")
            commands.append("set content of text range of text frame of tb to \(OfficeAutomation.quote(title))")
            if !body.isEmpty {
                commands.append("set bb to make new text box at s with properties {left position:60, top:160, width:760, height:380}")
                commands.append("set content of text range of text frame of bb to \(OfficeAutomation.quote(body))")
            }
        }
        let body = commands.joined(separator: "\n")
        let script = """
        on run argv
          set outPath to item 1 of argv
          tell application "Microsoft PowerPoint"
            activate
            set pres to make new presentation at end of presentations
            \(body)
            save pres in outPath
          end tell
        end run
        """
        _ = try OfficeAutomation.run(script, arguments: [url.path])
    }

    private static func column(_ index: Int) -> String {
        var value = index + 1
        var result = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            result = String(UnicodeScalar(65 + remainder)!) + result
            value = (value - 1) / 26
        }
        return result
    }
}

// MARK: - Export PDF

public struct OfficeExportPDFTool: Tool {
    public let name = "office_export_pdf"
    public let spec = ToolSpec(
        name: "office_export_pdf",
        description: "Export a Word, Excel, or PowerPoint file to PDF using Microsoft Office. Full Control mode + approval required.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string"],
                "output": ["type": "string", "description": "可选输出 PDF 路径"],
            ]),
            "required": AnyCodable(["path"]),
        ]
    )
    private let safePath: SafePath

    public init(workspace: URL) {
        self.safePath = SafePath(workspace: workspace)
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard let raw = arguments["path"]?.value as? String else {
            throw ToolError.invalidArguments("office_export_pdf 需要 path")
        }
        let input = safePath.resolveAny(raw)
        guard let format = OfficeFormat.from(url: input), format != .pdf else {
            throw ToolError.invalidArguments("源文件必须是 docx/xlsx/pptx")
        }
        let outputRaw = arguments["output"]?.value as? String
        let output = outputRaw.map { safePath.resolveAny($0) }
            ?? input.deletingPathExtension().appendingPathExtension("pdf")
        try OfficeAutomation.ensureInstalled(format.app)
        try OfficeAutomation.prepareOutput(output)
        switch format {
        case .docx:
            try exportWord(input, output)
        case .xlsx:
            try exportExcel(input, output)
        case .pptx:
            try exportPowerPoint(input, output)
        case .pdf:
            break
        }
        return ToolResult(text: "已导出 PDF: \(output.path)", files: [output])
    }

    private func exportWord(_ input: URL, _ output: URL) throws {
        let script = """
        on run argv
          set inPath to item 1 of argv
          set outPath to item 2 of argv
          tell application "Microsoft Word"
            set d to open file name inPath
            save as d file name outPath file format format PDF
            try
              close d saving no
            end try
          end tell
        end run
        """
        _ = try OfficeAutomation.run(script, arguments: [input.path, output.path])
    }

    private func exportExcel(_ input: URL, _ output: URL) throws {
        let script = """
        on run argv
          set inPath to item 1 of argv
          set outPath to item 2 of argv
          tell application "Microsoft Excel"
            set wb to open workbook filename inPath
            save workbook as wb filename outPath file format PDF file format
          end tell
        end run
        """
        _ = try OfficeAutomation.run(script, arguments: [input.path, output.path])
    }

    private func exportPowerPoint(_ input: URL, _ output: URL) throws {
        let script = """
        on run argv
          set inPath to item 1 of argv
          set outPath to item 2 of argv
          tell application "Microsoft PowerPoint"
            set pres to open inPath
            save pres in outPath
          end tell
        end run
        """
        _ = try OfficeAutomation.run(script, arguments: [input.path, output.path])
    }
}
