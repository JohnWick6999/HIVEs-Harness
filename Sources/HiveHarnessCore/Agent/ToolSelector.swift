import Foundation

/// 按用户问题选择要暴露给模型的工具,减少无关工具对上下文和选择的干扰。
/// 始终保留基础读写/记忆/计划/技能/提问工具;外部与专项工具按关键词启用。
public enum ToolSelector {
    public static let core: Set<String> = [
        "read_file", "list_dir", "search_memory", "add_memory",
        "todowrite", "todoread", "list_skills", "run_skill", "ask_user",
    ]

    public static func select(
        specs: [ToolSpec],
        query: String,
        mode: WorkMode
    ) -> [ToolSpec] {
        let text = query.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return specs
        }

        let writeWords = ["写", "改", "修", "创建", "保存", "删除", "重命名", "实现", "重构", "代码", "脚本", "文件", "write", "edit", "create", "fix", "implement", "refactor", "code", "save", "delete", "rename"]
        let netWords = ["天气", "联网", "网络", "搜索", "查询", "查一下", "网页", "网址", "http", "api", "最新", "新闻", "温度", "汇率", "股票", "weather", "search", "url", "fetch", "online"]
        let cliWords = ["cli", "命令", "终端", "shell", "codex", "opencode", "claude", "hermes", "本机", "命令行"]
        let pluginWords = ["插件", "扩展", "技能包", "plugin", "extension"]
        let subagentWords = ["调研", "研究", "审查", "并行", "多角度", "多视角", "比较", "长任务", "后台", "子代理", "research", "review", "parallel", "subagent", "background"]
        let mcpWords = ["mcp", "服务器", "工具集"]

        func matches(_ words: [String]) -> Bool {
            words.contains { text.contains($0) }
        }

        let hasWrite = matches(writeWords)
        let hasNet = matches(netWords)
        let hasCLI = matches(cliWords)
        let hasPlugin = matches(pluginWords)
        let hasSubagent = matches(subagentWords)
        let hasMCP = matches(mcpWords)
        let anySpecial = hasWrite || hasNet || hasCLI || hasPlugin || hasSubagent || hasMCP
        guard anySpecial else { return specs }

        var names = core
        if hasWrite { names.insert("write_file") }
        if hasNet { names.insert("http_get") }
        if hasCLI { names.insert("run_local_agent") }
        if hasPlugin { names.insert("create_plugin") }
        if hasSubagent {
            names.insert("run_subagent")
            names.insert("run_subagent_cluster")
            names.insert("spawn_background_task")
        }
        if hasMCP {
            for spec in specs where spec.name.hasPrefix("mcp__") {
                names.insert(spec.name)
            }
        }

        // 保持原工具顺序;未知/未命中的专项工具不再暴露。
        let selected = specs.filter { names.contains($0.name) }
        return selected.isEmpty ? specs : selected
    }
}
