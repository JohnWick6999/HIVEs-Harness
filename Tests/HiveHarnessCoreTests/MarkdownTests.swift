import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("Markdown 块解析")
struct MarkdownTests {
    @Test("标题、列表、引用、代码、分隔线")
    func blocks() {
        let source = """
        ##标题实例
        这是正文,包含 **粗体**。

        - 第一项
        - 第二项

        1. 步骤一
        2. 步骤二

        > 引用内容

        ```swift
        let value = 1
        ```

        ---
        """
        let blocks = MarkdownParser.parse(source)
        #expect(blocks.contains(.heading(level: 2, text: "标题实例")))
        #expect(blocks.contains { if case .paragraph(let text) = $0 { text.contains("粗体") } else { false } })
        #expect(blocks.contains(.bullet(["第一项", "第二项"])))
        #expect(blocks.contains(.ordered(["步骤一", "步骤二"])))
        #expect(blocks.contains(.quote("引用内容")))
        #expect(blocks.contains { if case .code(let language, let code) = $0 { language == "swift" && code.contains("value") } else { false } })
        #expect(blocks.contains(.divider))
    }

    @Test("管道表格解析")
    func table() throws {
        let table = try #require(MarkdownTableParser.parse("""
        | 工具 | 用途 |
        | --- | --- |
        | glob | 查找文件 |
        | grep | 搜索内容 |
        """))
        #expect(table.headers == ["工具", "用途"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0] == ["glob", "查找文件"])
        #expect(table.rows[1] == ["grep", "搜索内容"])
    }

    @Test("表格:代码内竖线与转义竖线不分列")
    func tablePipes() throws {
        let table = try #require(MarkdownTableParser.parse("""
        | 表达式 | 说明 |
        | --- | --- |
        | `a|b` | 代码里的竖线 |
        | a \\| b | 转义竖线 |
        """))
        #expect(table.rows.count == 2)
        #expect(table.rows[0].count == 2)
        #expect(table.rows[0][0] == "`a|b`")
        #expect(table.rows[1][0] == "a | b")
    }

    @Test("表格:短行补齐列数")
    func tablePadding() throws {
        let table = try #require(MarkdownTableParser.parse("""
        | A | B | C |
        | --- | --- | --- |
        | 1 | 2 |
        """))
        #expect(table.rows[0] == ["1", "2", ""])
    }

    @Test("无空格标题也识别")
    func headingWithoutSpace() {
        #expect(MarkdownParser.parse("###标题").contains(.heading(level: 3, text: "标题")))
    }

    @Test("普通文本保持段落")
    func paragraph() {
        #expect(MarkdownParser.parse("第一行\n第二行") == [.paragraph("第一行\n第二行")])
    }
}
