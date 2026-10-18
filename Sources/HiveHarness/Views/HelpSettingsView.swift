import SwiftUI
import HiveHarnessCore

// MARK: - Help model

struct HelpTopic: Identifiable, Equatable {
    let id: String
    let category: String
    let title: String
    let summary: String
    let icon: String
    let keywords: [String]
    let markdown: String

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        return title.lowercased().contains(needle)
            || summary.lowercased().contains(needle)
            || category.lowercased().contains(needle)
            || keywords.contains { $0.lowercased().contains(needle) }
            || markdown.lowercased().contains(needle)
    }
}

// MARK: - Help view

struct HelpSettingsView: View {
    @State private var query = ""
    @State private var selectedID = "quick-start"

    private var topics: [HelpTopic] { HelpTopic.all }
    private var filtered: [HelpTopic] { topics.filter { $0.matches(query) } }
    private var selected: HelpTopic? {
        filtered.first(where: { $0.id == selectedID })
            ?? filtered.first
            ?? topics.first
    }
    private var categories: [String] {
        var seen = Set<String>()
        return topics.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    var body: some View {
        HStack(spacing: 0) {
            indexPanel
                .frame(width: 192)
            Rectangle()
                .fill(HiveTheme.hairline)
                .frame(width: 1)
            detailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.quaternary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HiveTheme.hairline, lineWidth: 1)
        )
        .onChange(of: query) { _, _ in
            if !filtered.contains(where: { $0.id == selectedID }) {
                selectedID = filtered.first?.id ?? ""
            }
        }
    }

    // MARK: Index

    private var indexPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("帮助与文档")
                    .font(.system(.callout, design: .rounded).weight(.bold))
                Text("内置说明 · 不联网")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 9)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("搜索设置或问题", text: $query)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if filtered.isEmpty {
                        Text("没有找到相关主题")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else if query.isEmpty {
                        ForEach(categories, id: \.self) { category in
                            Text(category)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 3)
                            ForEach(filtered.filter { $0.category == category }) { topic in
                                indexRow(topic)
                            }
                        }
                    } else {
                        Text("搜索结果 · \(filtered.count)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 3)
                        ForEach(filtered) { topic in
                            indexRow(topic)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .background(.ultraThinMaterial.opacity(0.42))
    }

    private func indexRow(_ topic: HelpTopic) -> some View {
        let active = topic.id == selected?.id
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                selectedID = topic.id
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: topic.icon)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(topic.title)
                        .font(.caption)
                        .lineLimit(1)
                    if !query.isEmpty {
                        Text(topic.summary)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                active ? HiveTheme.amber.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .foregroundStyle(active ? HiveTheme.amberDeep : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPanel: some View {
        if let topic = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: topic.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HiveTheme.amberDeep)
                        Text(topic.category)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Text("内置帮助")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Text(topic.title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(topic.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HiveMarkdownView(text: topic.markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    HStack(spacing: 8) {
                        Text("没解决？")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("查看故障排查") {
                            selectedID = "troubleshooting"
                            query = ""
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        Spacer()
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "没有找到帮助主题",
                systemImage: "questionmark.circle",
                description: Text("换一个关键词，或清空搜索查看全部文档。")
            )
        }
    }
}

// MARK: - Embedded documentation

extension HelpTopic {
    static let all: [HelpTopic] = [
        HelpTopic(
            id: "quick-start",
            category: "快速开始",
            title: "第一次把任务交给 HIVE",
            summary: "从配置 Provider 到拿到第一个产物。",
            icon: "sparkles",
            keywords: ["开始", "配置", "新会话", "发送", "快速"],
            markdown: #"""
## 最短路径

1. 打开「设置 → 模型」，确认至少有一个**启用的 Provider** 和一个**启用的模型**。
2. 在「Agent 回退链」里把模型加入候选链。
3. 回到主窗口，在输入框描述目标，按 `Enter` 发送。
4. Agent 需要工具时会请求审批；确认后继续执行。
5. 产物会以文件卡片回到对话，点击即可预览。

## 第一次配置建议

| 项目 | 建议 |
|---|---|
| 端点类型 | OpenAI 兼容 |
| API 协议 | Chat Completions（默认） |
| Base URL | DeepSeek 填 `https://api.deepseek.com` |
| 模型名 | `deepseek-flash` 或 `deepseek-v4-pro` |
| API Key | 填到 Provider 的 API Key 字段 |

> **不要**把 API Key 填到「模型名」。模型名是 `deepseek-flash` 这类真实 ID。

## 你会看到什么

- 对话上方的运行状态：模型轮数、工具调用、用量
- 工具审批卡：写文件、Shell、外部执行等高风险操作
- 右侧产物预览：HTML / PDF / Office / 图片 / 文本
- 左侧缩略轨：快速回到任意一轮
"""#
        ),
        HelpTopic(
            id: "provider",
            category: "模型与连接",
            title: "Provider 与端点类型",
            summary: "OpenAI 兼容和 Ollama 分别代表什么。",
            icon: "network",
            keywords: ["Provider", "提供商", "OpenAI", "Ollama", "端点", "Base URL"],
            markdown: #"""
## 端点类型不是响应格式

- **OpenAI 兼容**：标准 API Key + `/v1` 风格端点。DeepSeek、OpenAI、绝大多数中转都属于这一类。
- **Ollama**：本地 Ollama 服务，默认 `http://127.0.0.1:11434`，不需要 API Key。

## 字段说明

| 字段 | 作用 |
|---|---|
| 名称 | 仅界面展示 |
| 端点类型 | 端点/鉴权方式，不是响应格式 |
| Base URL | API 根地址，不要手动拼 `/chat/completions` |
| 启用 | 关闭后该 Provider 下所有模型不可用 |
| API Key | 只保存到 Keychain |
| API 协议 | Chat Completions / Responses / Anthropic Messages |

## 示例

```text
DeepSeek Chat:
Base URL = https://api.deepseek.com
API 协议 = Chat Completions

DeepSeek Responses:
Base URL = https://api.deepseek.com
API 协议 = Responses

DeepSeek Anthropic:
Base URL = https://api.deepseek.com/anthropic
API 协议 = Anthropic Messages
```

> 一个 Provider 只能选一种协议。若要同时使用 Chat 和 Responses，新增两个 Provider。
"""#
        ),
        HelpTopic(
            id: "protocols",
            category: "模型与连接",
            title: "API 协议：Chat / Responses / Anthropic",
            summary: "三种协议的区别、端点和常见错误。",
            icon: "arrow.triangle.branch",
            keywords: ["API", "协议", "Responses", "Anthropic", "Chat Completions", "格式"],
            markdown: #"""
## 三种协议

| 协议 | 端点 | 说明 |
|---|---|---|
| Chat Completions | `/chat/completions` | 默认，兼容性最好 |
| Responses | `/responses` | OpenAI Responses 格式，DeepSeek 支持 |
| Anthropic Messages | `/v1/messages` | Claude Code / Anthropic SDK 生态 |

## 为什么要分开

三种协议的请求体、工具调用、流式事件不同：

- Chat Completions 用 `choices[].delta`
- Responses 用 `response.output_text.delta` / `output_item`
- Anthropic 用 `content_block_delta` / `tool_use`

HIVE 会把它们统一成同一种 `content / reasoning / toolCalls / usage`。

## 常见误区

- 「OpenAI 兼容」不是协议；它只是端点类型。
- 改完协议必须点设置页右下角**保存**。
- Responses 是无状态接口，客户端会自动回传完整历史。
- Anthropic 的 Base URL 通常以 `/anthropic` 结尾。
"""#
        ),
        HelpTopic(
            id: "model-fields",
            category: "模型与连接",
            title: "模型参数逐项说明",
            summary: "展示名、模型名、上下文、输出与能力标签。",
            icon: "cpu",
            keywords: ["模型名", "展示名", "上下文", "输出", "工具", "视觉", "仅辅助"],
            markdown: #"""
## 基础

| 选项 | 说明 |
|---|---|
| 展示名 | 界面显示名称，可自由填写 |
| 模型名 | 真正发送给 API 的 `model` ID |
| 提供商 | 该模型使用哪个 Provider |
| 启用 | 关闭后不参与任何调用 |

## 上下文

- **自动上下文**：按模型名自动匹配已知窗口。
- **检测到**：系统识别出的窗口，例如 DeepSeek 100M。
- **窗口**：实际发给上下文管理器的预算。
- 手动调整窗口会自动关闭「自动上下文」。

## 输出与能力

| 选项 | 说明 |
|---|---|
| 输出 | 单次请求的最大输出 token |
| 工具 | 允许 function calling / 工具调用 |
| 视觉 | 允许图片输入 |
| 仅辅助 | 只能做嵌入、搜索等辅助任务，不能进入 Agent 回退链 |

> 上下文是「可输入预算」，输出是「本次最多生成多少」，两者不要混淆。
"""#
        ),
        HelpTopic(
            id: "fallback",
            category: "模型与连接",
            title: "Agent 回退链怎么工作",
            summary: "模型失败时如何自动切换，以及为什么没有回复。",
            icon: "arrow.up.arrow.down",
            keywords: ["回退", "fallback", "模型组", "失败", "切换", "没有回复"],
            markdown: #"""
## 工作方式

Agent 按「Agent 回退链」从上到下尝试：

```text
1. deepseek-flash
2. backup-model
3. local-model
```

- 第一个模型请求失败（网络、限流、HTTP 错误）时，切换到下一个。
- 工具调用失败不会自动切换模型，会先作为工具结果回填。
- 全部候选都没有 API Key 时，使用本地回退回复。

## 操作

- 「加入模型」把模型加入链尾。
- 上下箭头调整优先级。
- 减号从链中移除。
- 「仅辅助」模型不会出现在可用链中。

## 检查

1. 模型是否启用？
2. Provider 是否启用？
3. API Key 是否保存？
4. 模型名是否与 Provider 支持的一致？
"""#
        ),
        HelpTopic(
            id: "reasoning",
            category: "模型与连接",
            title: "推理强度、上下文与用量",
            summary: "五个推理档位、上下文圆环和缓存命中。",
            icon: "gauge.with.dots.needle.50percent",
            keywords: ["推理", "reasoning", "上下文", "usage", "缓存", "token", "圆环"],
            markdown: #"""
## 推理强度

底部模型面板提供五档：

| 档位 | 行为 |
|---|---|
| 关闭 | 不发送 thinking / reasoning |
| 低 | 快速回答 |
| 中 | 平衡 |
| 高 | 更深推理 |
| 极高 | 最大推理预算 |

DeepSeek 会发送 `thinking` 和 `reasoning_effort`；`极高` 发送 `max`。

## 上下文

- 底部圆环显示上次请求的真实 prompt token 与预算。
- 接近上限时自动压缩历史，保留目标与关键约束。
- 上下文不是越大越好；预算过大反而增加成本与噪声。

## 用量

- `Prompt`：输入 token
- `Completion`：输出 token
- `Cached`：命中前缀缓存的 token
- 提供商未返回 usage 时才使用本地估算兜底
"""#
        ),
        HelpTopic(
            id: "agent",
            category: "Agent 设置",
            title: "Agent 标签页",
            summary: "默认人格、工具轮数、主动提问和技能提案。",
            icon: "person.crop.circle",
            keywords: ["Agent", "人格", "轮数", "提问", "技能", "设置"],
            markdown: #"""
## 默认行为

| 选项 | 作用 |
|---|---|
| 默认人格 | 新会话使用的人格 |
| 最大工具轮数 | 一次任务最多执行多少轮工具调用 |
| 成功后自动提炼技能提案 | 完成后生成可复用 Skill，需人工批准 |
| 主动提问 | 关闭 / 平衡 / 积极 |

## 主动提问

- **关闭**：尽量直接执行。
- **平衡**：遇到关键歧义才提问。
- **积极**：方案不明确时先确认。

提问会作为工具结果回填，影响后续计划；不是装饰性对话。
"""#
        ),
        HelpTopic(
            id: "modes",
            category: "Agent 设置",
            title: "工作模式与审批",
            summary: "对话、沙箱、完全控制的边界。",
            icon: "lock.shield",
            keywords: ["工作模式", "审批", "沙箱", "完全控制", "权限", "安全"],
            markdown: #"""
## 三种模式

| 模式 | 能力 |
|---|---|
| 对话 | 只读与回答，不执行写操作 |
| 沙箱 | 允许受限的本地操作 |
| 完全控制 | 可写文件、执行 Shell、调用外部应用 |

## 审批

- 写文件、Shell、外部执行等高风险管理动作会先请求审批。
- 审批卡会展示命令、路径或变更内容。
- 拒绝后 Agent 会尝试更保守的替代方案。

## 建议

- 日常问答用「对话」。
- 代码修改用「沙箱」，确认 diff 后再切换。
- 只有在明确知道命令含义时才使用「完全控制」。
"""#
        ),
        HelpTopic(
            id: "tools",
            category: "Agent 能力",
            title: "工具链与后台任务",
            summary: "文件、Git、Shell、Office、MCP、插件与子代理。",
            icon: "wrench.and.screwdriver",
            keywords: ["工具", "office", "MCP", "插件", "子代理", "后台", "Git", "Shell"],
            markdown: #"""
## 工具类别

| 工具 | 用途 |
|---|---|
| 文件 / 代码 | 读取、搜索、写文件、应用补丁 |
| Git / Diff | 状态、变更、行级审计 |
| Shell | 本地命令、构建、测试 |
| HTTP / Web | 抓取、搜索、API |
| Office | Word / Excel / PowerPoint 读取、创建、PDF |
| MCP | 外部服务与数据源 |
| 插件 | 可扩展能力包 |
| 本地代理 | 子任务与代理集群 |
| 技能 | 可复用工作流 |

## 后台任务

长任务可以转到后台，不阻塞主对话；在「后台任务」中查看状态、结果与产物。

## 工具失败

- 先看工具结果里的 stderr / 错误信息。
- 路径、权限、依赖是三类最常见原因。
- 高风险工具需要完全控制模式与审批。
"""#
        ),
        HelpTopic(
            id: "rail",
            category: "对话与产物",
            title: "对话缩略轨",
            summary: "自动定位当前轮、悬停预览、点击跳转与回弹。",
            icon: "rectangle.leftthird.inset.filled",
            keywords: ["缩略轨", "rail", "跳转", "当前", "悬停", "高亮", "滚动"],
            markdown: #"""
## 当前轮次

- 自然滚动对话时，缩略轨自动定位到当前可见轮次。
- `assistant` / `tool` 消息会归到最近的 `user` 轮。
- 滚回底部时重新定位最新轮。

## 视觉状态

| 状态 | 表现 |
|---|---|
| 当前轮 | 琥珀色、加宽、光晕 |
| 悬停其他轮 | 淡蜂蜜色细线 |
| 普通 | 低对比灰白 |

## 操作

- 悬停：右侧出现该轮摘要。
- 点击：跳转到该轮，并高亮。
- 选中/未选中使用弹簧回弹。
- 上滑后，右上角出现「回到最新对话」。
"""#
        ),
        HelpTopic(
            id: "artifacts",
            category: "对话与产物",
            title: "产物预览与代码 Diff",
            summary: "右侧浏览器、QuickLook、文本查看器和打开方式。",
            icon: "doc.richtext",
            keywords: ["产物", "预览", "HTML", "PDF", "Office", "QuickLook", "diff"],
            markdown: #"""
## 打开方式

- 点击消息下方的文件卡片。
- 或点击顶部「预览」按钮，从产物菜单中选择。
- 设置 → 产物，可分别配置每种类型的默认打开方式。

## 预览器

| 类型 | 预览 |
|---|---|
| HTML / Web | 内置 WKWebView |
| PDF / Office | QuickLook |
| 图片 | 内置图片预览 |
| 文本 / 代码 | 内置文本查看器 |

## 代码 Diff

代码修改后会出现行级 diff 浮窗；确认变更后再合并或继续。
"""#
        ),
        HelpTopic(
            id: "appearance",
            category: "外观与效率",
            title: "外观、玻璃与快捷操作",
            summary: "主题、Liquid Glass、侧栏宽度和常用按键。",
            icon: "paintpalette",
            keywords: ["外观", "主题", "玻璃", "Liquid Glass", "快捷键", "侧栏"],
            markdown: #"""
## 外观

| 选项 | 作用 |
|---|---|
| 主题 | 跟随系统 / 浅色 / 深色 |
| 液态玻璃强度 | 0–100%，影响高光与折射 |
| 侧栏宽度 | 200–360pt，也可拖动边缘 |
| 底部 Token 用量栏 | 显示或隐藏统计 |

## 常用操作

- `Enter`：发送
- `Shift + Enter`：换行
- 输入框左侧：附件 / 权限 / 模型
- 顶部「预览」：产物菜单
- 左侧缩略轨：跳转历史轮次

> 玻璃只作用于背景层，正文保持可读。
"""#
        ),
        HelpTopic(
            id: "troubleshooting",
            category: "故障排查",
            title: "常见错误与排查顺序",
            summary: "401/404、协议错误、上下文超限、工具被拒。",
            icon: "exclamationmark.triangle",
            keywords: ["报错", "401", "404", "失败", "排查", "错误", "超时", "协议"],
            markdown: #"""
## 先检查四件事

1. Base URL 是否是 API 根地址？
2. API 协议是否与端点匹配？
3. 模型名是否是真实 ID？
4. API Key 是否保存到 Keychain？

## HTTP 401 / 403

- Key 错误、过期或没有权限。
- 确认 Key 填在 Provider 的 API Key 字段，不是模型名。

## HTTP 404

- Base URL 多了 `/chat/completions` 等路径。
- 模型名不存在，或端点不支持该模型。
- 使用 Responses / Anthropic 时端点路径不匹配。

## 无法解析响应

- 检查「API 协议」：Chat、Responses、Anthropic 三选一。
- 如果端点只支持 Chat，选 Responses 会失败。
- 查看错误信息里的 HTTP 状态与响应片段。

## 上下文超限

- 降低「窗口」或减少附件。
- 等待自动压缩，或开启新会话。
- 不要把输出 token 当成上下文窗口。

## 工具被拒绝 / 超时

- 确认工作模式与审批。
- 查看工具 stderr。
- Office 工具首次使用需要 macOS 自动化权限。
"""#
        ),
        HelpTopic(
            id: "privacy",
            category: "数据与隐私",
            title: "数据、密钥与本地存储",
            summary: "什么留在本机，什么会发给模型。",
            icon: "hand.raised",
            keywords: ["隐私", "数据", "Keychain", "钥匙串", "本地", "备份", "数据库"],
            markdown: #"""
## 留在本机

- 工作区文件
- SQLite 会话与运行记录
- 记忆、技能、插件配置
- API Key（Keychain）

## 会发给模型

- 当前请求的消息、工具结果与必要上下文
- 图片附件（如果模型支持视觉）

## 位置

```text
~/Library/Application Support/HiveHarness/
~/Documents/HiveHarness/
```

## 建议

- 定期备份整个 `HiveHarness` 数据目录。
- 不要把 API Key 写进普通配置文件或截图。
- 敏感文件先确认工作区与工具权限。
"""#
        ),
    ]
}
