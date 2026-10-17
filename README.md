# HIVE's Harness

> 本地优先的 macOS 智能体。Swift 原生、零第三方依赖,模型、记忆、技能与密钥都留在你的机器上。

**HIVE's Harness** 是一个可独立运行的 Apple 原生 Agent:多模型对话、工具调用、任务计划、上下文压缩、长期记忆、Skills 自进化、插件市场、MCP、本地 OpenAI 兼容网关与可审计运行日志。

项目前身为 Python 版 [ShizukuAgent](https://github.com/windbreake/ShizukuAgent),本仓库是 Swift 原生重写;内部代码名统一为 `HiveHarness`,产品展示名为 **HIVE's Harness**。

## ✨ 功能特性

| 能力 | 说明 | 状态 |
|---|---|---|
| 💬 流式聊天 | 可折叠侧边栏(品牌/工作区/会话/用户)、多会话、分支、撤销、SSE、工具轨迹 | ✅ |
| 🙋 主动澄清 | 多问题向导(可回退/保留选择/动画切换);推荐项/自由补充;三档偏好 | ✅ |
| 🧠 多模型 | 多提供商、模型组回退、Keychain API Key、模型管理 UI | ✅ |
| 🎭 通用人格 | 7 个通用内置人格;可覆盖、恢复默认;自定义人格可增删 | ✅ |
| 🛠️ 工具与审批 | 文件、记忆、Shell、Git、本地 Agent CLI;三档工作模式 + Touch ID | ✅ |
| 📋 任务计划 | todo 工具、计划面板、超预算摘要压缩 | ✅ |
| 🧾 运行日志 | 模型/工具/审批/压缩时间线,事件回放、问答回看与 JSON 导出 | ✅ |
| 📊 AI 用量 | 底部状态条:token、缓存命中、模型轮数、运行/工具次数;按会话持久化 | ✅ |
| 🧩 MCP | stdio + Streamable HTTP;`servers.json` 管理 | ✅ |
| 🧬 Skills 自进化 | 轨迹反思、patch 优先、风险扫描、使用遥测、30 天归档 | ✅ |
| 🔁 技能版本 | 覆盖前自动备份、历史版本、一键回滚、`_ledger.jsonl` | ✅ |
| 🏪 插件市场 | 43 个内置卡片 + GitHub + 魔搭;展开/批量安装/校验/更新 | ✅ |
| 🧠 长期记忆 | 来源、置信度、检索次数可审计;可编辑与调整 | ✅ |
| 🌐 本地网关 | OpenAI 兼容 `/v1/models`、`/v1/chat/completions`(SSE) | ✅ |
| 💻 工作台 | 文件浏览、Git status/diff、Shell(完全控制 + 确认) | ✅ |
| 🔒 本地优先 | 数据在本地 SQLite / Documents;API Key 在钥匙串 | ✅ |

## 🎨 界面与交互

- **蜂巢视觉**:暖琥珀六边形标识、柔和径向光、玻璃卡片、低对比 hairline。
- **聊天**:助手消息带头像与 Markdown;围栏代码块带语言标签和一键复制;用户气泡右对齐。
- **空状态**:四张任务引导卡,点击填入输入框而不是直接发送。
- **输入**:大圆角浮层,聚焦时琥珀描边;发送按钮渐变。
- **侧边栏**:参考 DSH 的左侧工作区结构,顶部品牌、工作区/会话/功能分组,底部本地用户点击进入设置;可折叠为 64pt 图标栏。
- **设置**:8 个 Tab 改为侧边栏设置中心,避免拥挤;保留同一主题。
- **提问卡**:不弹模态框,内联在输入区上方;选项可多选、标推荐、自由补充、一键跳过。

## 🏗️ 架构

```text
┌──────────────────────────────────────────────┐
│              HiveHarness (SwiftUI)           │
│  聊天 / 设置 / 插件市场 / 工作台 / 运行日志    │
└──────────────────────┬───────────────────────┘
                       │
┌──────────────────────▼───────────────────────┐
│            HiveHarnessCore (SPM)             │
│  AgentLoop · LLM · Storage · Tools · Persona │
│  MCP · Skills · Marketplace · Gateway        │
│  Workbench · Config · Plugin                 │
└──────────────────────────────────────────────┘
```

- 单一共享核心 `HiveHarnessCore`,纯 Foundation + Swift Concurrency,可复用到 iOS / watchOS / visionOS。
- macOS App `HiveHarness` 只负责 UI 与系统集成。
- 零第三方依赖:系统 SQLite3、Security、LocalAuthentication、Network、CryptoKit。

## 🚀 构建与运行

```bash
# 单元测试(自动选择 Xcode 工具链)
./scripts/test.sh

# 开发运行(直接弹窗)
swift run HiveHarness

# 打包为 .app 并启动
./scripts/make_app.sh
open build/HiveHarness.app
```

要求:macOS 14+,Xcode 27.1(或可编译 Swift 6.2 的工具链)。

## 🎭 人格系统

内置 7 个通用人格,不含二次元角色:

| id | 人格 | 用途 |
|---|---|---|
| `assistant` | HIVE | 通用助手(默认) |
| `engineer` | 工程师 | 实现、调试、审查与验证 |
| `researcher` | 研究员 | 技术调研与证据分析 |
| `writer` | 写作助手 | 结构、语气与编辑 |
| `analyst` | 数据分析师 | 数据口径、指标与结论 |
| `planner` | 项目规划师 | 目标拆解、里程碑与风险 |
| `tutor` | 学习导师 | 分步讲解与理解检查 |

规则:

- **内置人格不可删除**;编辑后保存为你的覆盖版本,可随时「恢复默认」。
- **自定义人格**可新建、编辑、删除。
- 内置模板在 App 资源中;用户覆盖与自定义人格在:
  `~/Documents/HiveHarness/personas/<id>.json`
- 系统提示词由模板 + 行为规则 + 回复风格 + 行为规划组成。

## 🙋 主动澄清(ask_user)

当关键信息缺失且不同选择会显著改变方案时,Agent 会调用 `ask_user` **真正暂停工具循环**,等待界面回答后再继续。

自研点(针对主流 Agent 的常见不足):

- **不是装饰性提问**:答案会作为工具结果回填给模型,影响后续计划。
- **多问题向导**:一次 `ask_user` 可提交 2-4 个问题;用户可上一步/下一步,选择与自由补充逐题保留,最后统一提交。
- **流畅切换**:问题卡使用弹簧动画与推入/推出过渡,底部进度点指示当前位置。
- **先推断再问**:系统提示要求先从上下文/记忆/工具结果推断;能确定就不问。
- **可配置偏好**:设置 → Agent 可选「关闭 / 平衡(2 问)/ 积极(4 问)」。
- **问题预算**:每轮提问数由偏好决定,重复问题会被 gate 拦截,避免“问题轰炸”。
- **推荐项 + 自由补充**:选项可标 `recommended`,但用户始终可写自己的答案。
- **可跳过**:跳过时要求模型采用最保守、可逆的默认方案,并说明假设。
- **可审计**:问题与回答写入运行日志 `question` / `answer` 事件;运行日志新增「问答」页签,直接回看问与答。
- **通道隔离**:网关请求没有 UI 通道,不暴露 `ask_user`,避免外部调用永久挂起。

## 📊 AI 用量

聊天底部有一条常驻状态条:

- **tokens**:Prompt / Completion / 总计
- **缓存命中**:命中 token 数与命中率(来自模型返回的 usage)
- **调用**:模型轮数、用户运行次数、工具调用次数、平均每次 token
- 点 ⓘ 查看明细;菜单可「复制统计」「清零当前会话」

缓存字段兼容:

- OpenAI `usage.prompt_tokens_details.cached_tokens`
- DeepSeek `usage.prompt_cache_hit_tokens`
- 流式请求会带 `stream_options.include_usage`,以便最后一个 chunk 返回 usage

统计按会话保存在 SQLite `kv_store` 的 `usage.<thread_id>`,切换会话自动加载;模型未返回 usage 时用本地估算兜底。

上下文圆环同样优先使用模型返回的真实 prompt token(上次请求);只有提供商未返回 usage 时才显示本地估算。明细里会同时列出两者,避免“估算当实际”。

## 🧯 常见错误

- **`LLMError error 0` / 无法解析响应**:通常是 Base URL、模型名、API Key 填反或模型不存在。设置 → 模型会拒绝把 `sk-...` 填进“模型名”;Key 只放 API Key 字段(Keychain)。
- **HTTP 401/404**:检查 Key 与模型 id;DeepSeek 官方可用模型以 `/models` 返回为准。
- **MCP 不出现**:`servers.json` 中 `enabled` 必须为 true,并在设置 → MCP 重新载入。

## 🛠️ 首次使用

1. 打开 App → 设置 → 模型,填写 Base URL、模型名与 API Key(Keychain 存储)。
2. 选择人格与工作模式:
   - **对话**:只读工具。
   - **安全**:只能写工作区。
   - **完全控制**:外部写入/执行需要审批。
3. 在聊天中直接提问;需要工具时会显示审批条。
4. 顶栏可打开插件市场、工作台、运行日志。

## 📂 数据位置

| 内容 | 路径 |
|---|---|
| 数据库(对话/记忆/检查点/运行日志) | `~/Library/Application Support/HiveHarness/agent.db` |
| 配置文件 | `~/Library/Application Support/HiveHarness/config.json` |
| 工作区 | `~/Documents/HiveHarness/` |
| 用户人格 | `~/Documents/HiveHarness/personas/<id>.json` |
| MCP 配置 | `~/Documents/HiveHarness/mcp/servers.json` |
| 用户技能 | `~/Documents/HiveHarness/skills/<id>/SKILL.md` |
| 技能提案 | `~/Documents/HiveHarness/skills/_proposals/<id>.json` |
| 技能用量 | `~/Documents/HiveHarness/skills/.usage.json` |
| 归档技能 | `~/Documents/HiveHarness/skills/_archive/<id>/` |
| 技能历史版本 | `~/Documents/HiveHarness/skills/_versions/<id>/<timestamp>/` |
| 技能操作审计 | `~/Documents/HiveHarness/skills/_ledger.jsonl` |
| 插件工坊项目 | `~/Documents/HiveHarness/plugin-studio/<id>/` |
| API Key | 钥匙串(`com.hiveharness.app`) |

首次启动会自动迁移旧 `ShizukuClaw` 数据目录与钥匙串项。

## 🔌 MCP 配置

`~/Documents/HiveHarness/mcp/servers.json`:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
      "disabled": false
    }
  }
}
```

支持 stdio 与 Streamable HTTP;也兼容 Claude / VS Code 的 `{"mcpServers": {...}}` 对象格式。`mcp__<server>__<tool>` 仅在完全控制模式 + 审批后执行。

## 🧪 插件工坊(声明式)

顶栏 🏪 → **插件工坊**,不需要写 Swift/JS,直接声明插件包含什么:

```text
plugin-studio/<id>/
├── plugin.json          # 清单:名称/版本/作者/skills/MCP
├── README.md
└── skills/<id>/SKILL.md # 工作流
```

- 模板:**技能包**、**MCP 连接器**、**技能 + MCP**
- 编辑 `plugin.json` / `SKILL.md` → **校验** → **安装** → **导出 `.hiveplugin.json`**
- 安装时只写 `SKILL.md` 与 MCP 配置;MCP 默认停用,必须人工审查
- `commands` / `hooks` 仅兼容展示,不执行;插件中的脚本不会运行
- 支持本地导入 `.hiveplugin.json`,可分享给其他人

### 兼容层

| 输入 | 支持 |
|---|---|
| HIVE `plugin.json` | ✅ 原生 |
| Claude `.claude-plugin/plugin.json` | ✅ 解析 author 对象、skills、mcpServers |
| Claude `marketplace.json` | ✅ 展开子插件 |
| MCP `mcp.json` / `.mcp.json` / `server.json` | ✅ |
| Claude/VS Code `mcpServers` 对象 | ✅ 自动转换 |
| GitHub repo / `tree` / `blob` / `raw` 链接 | ✅ 自动限定子目录 |
| 直链 `.hiveplugin.json` | ✅ 下载、预览、安装技能 + MCP |
| GitLab / Gitee 仓库链接 | ✅ 链接导入 + tree/raw 安装 |
| npm 声明式包（unpkg） | ✅ 只读 package.json/文件,不执行 install 脚本 |
| DSH bundle 内声明式 SKILL/MCP | ✅ 扫描安装,忽略 Cordis/TS 代码 |
| DSH market `index.json` | ⏳ 暂不解析 |
| ModelScope skills 链接 | ✅ |
| DSH Cordis/TypeScript 代码插件 | ⏳ 不执行;可读取声明式资产,不运行 Cordis |

> DSH 的 Creator mode 本质是 Cordis/TypeScript 代码插件(见 [DSH Plugins](https://github.com/deepseek-ai/deepseek-harness));直接执行第三方代码不适合本地 Swift Agent。HIVE 工坊只生成可审计的声明式插件,这是有意取舍。

设计参考:[DSH plugin market](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/plugin-market.md)、[DSH bundle publish](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/basic/publish.md)、[Claude plugin reference](https://code.claude.com/docs/en/plugins-reference)、[Vercel Agent Plugins](https://vercel.com/blog/introducing-agent-plugins)、[MCP Registry server.json](https://github.com/modelcontextprotocol/registry)。

## 🏪 插件市场 / 自进化 / 运行日志

- **插件市场**:顶栏 🏪 → 搜索或切换 GitHub / 魔搭 / 内置;支持粘贴链接导入、Claude `marketplace.json` 展开、子目录/多技能包安装、MCP 清单预检、Git blob/Sha256 校验、来源清单、单个/批量更新。
- **自进化**:每 10 次工具迭代触发一次反思;优先 patch 现有技能;60 字描述、24k 正文上限、风险模式扫描;人工批准后启用;使用计数与 30 天归档;版本备份/回滚。
- **运行日志**:顶栏 🕘 → 模型、工具、审批、上下文压缩事件;支持单步/播放回放(纯展示,不重复执行副作用)与 JSON 导出。

## 📂 目录结构

```text
SCALW_APPLE/
├── Package.swift
├── Sources/
│   ├── HiveHarnessCore/          # 共享引擎库
│   │   ├── Agent/                # AgentLoop、任务计划、上下文、运行日志
│   │   ├── Config/               # AppConfig、Keychain、模型注册表
│   │   ├── LLM/                  # OpenAI 兼容 / Ollama 客户端
│   │   ├── Storage/              # SQLite 存储
│   │   ├── Tools/                # 工具注册表与内置工具
│   │   ├── Persona/              # 人格模型与仓库
│   │   ├── MCP/                  # MCP 客户端与注册表
│   │   ├── Skills/               # 技能仓库、自进化、工具
│   │   ├── Marketplace/          # 多源市场、安装器、校验
│   │   ├── Gateway/              # 本地 OpenAI 兼容网关
│   │   └── Workbench/            # 文件 / Git / Shell
│   └── HiveHarness/              # macOS SwiftUI App
├── Tests/HiveHarnessCoreTests/   # 单元测试
└── scripts/                      # 测试 / 构建 / 打包 / 发布
```

## ✅ 验证

```bash
./scripts/test.sh
# 181 tests in 35 suites passed
```

## 🔄 与旧版的关系

- Python 原版:[windbreake/ShizukuAgent](https://github.com/windbreake/ShizukuAgent)
- 旧 Swift 仓库:`windbreake/ShizukuClaw`(仅存档)
- 当前仓库:`JohnWick6999/HIVEs-Harness`

## 📄 许可证

GPL-3.0。
