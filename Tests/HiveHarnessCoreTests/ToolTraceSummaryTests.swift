import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("工具调用聚合")
struct ToolTraceSummaryTests {
    @Test("同一工具只算一个工具并统计次数")
    func grouped() {
        let traces = [
            ToolTrace(tool: "http_get", arguments: "a", result: ""),
            ToolTrace(tool: "http_get", arguments: "b", result: ""),
            ToolTrace(tool: "http_get", arguments: "c", result: ""),
            ToolTrace(tool: "http_get", arguments: "d", result: ""),
            ToolTrace(tool: "read_file", arguments: "{}", result: ""),
        ]
        let summary = ToolTraceSummary.grouped(traces)
        #expect(summary.count == 2)
        #expect(summary[0].name == "http_get")
        #expect(summary[0].count == 4)
        #expect(summary[1].name == "read_file")
        #expect(summary[1].count == 1)
    }
}
