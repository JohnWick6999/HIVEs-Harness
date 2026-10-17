# HIVE's Harness

> 本地优先的 macOS 智能体。Swift 原生、零第三方依赖,模型、记忆、技能与密钥都留在你的机器上。

**HIVE's Harness** 是一个可独立运行的 Apple 原生 Agent:多模型对话、工具调用、任务计划、上下文压缩、长期记忆、Skills 自进化、插件市场、MCP、本地 OpenAI 兼容网关与可审计运行日志。

项目前身为 Python 版 [ShizukuAgent](https://github.com/windbreake/ShizukuAgent),本仓库是 Swift 原生重写;内部代码名统一为 `HiveHarness`,产品展示名为 **HIVE's Harness**。

## ✨ 功能特性

| 能力 | 说明 | 状态 |
|---|---|---|
| 💬 流式聊天 | 多会话、分支、撤销、SSE 逐字输出、工具轨迹 | ✅ |
| 🧠 多模型 | 多提供商、模型组回退、Keychain API Key、模型管理 UI | ✅ |
| 🎭 通用人格 | 7 个通用内置人格;可覆盖、恢复默认;自定义人格可增删 | ✅ |
| 🛠️ 工具与审批 | 文件、记忆、Shell、Git、本地 Agent CLI;三档工作模式 + Touch ID | ✅ |
| 📋 任务计划 | todo 工具、计划面板、超预算摘要压缩 | ✅ |
| 🧾 运行日志 | 模型/工具/审批/压缩时间线,事件回放与 JSON 导出 | ✅ |
| 🧩 MCP | stdio + Streamable HTTP;`servers.json` 管理 | ✅ |
| 🧬 Skills 自进化 | 轨迹反思、patch 优先、风险扫描、使用遥测、30 天归档 | ✅ |
| 🔁 技能版本 | 覆盖前自动备份、历史版本、一键回滚、`_ledger.jsonl` | ✅ |
| 🏪 插件市场 | 43 个内置卡片 + GitHub + 魔搭;展开/批量安装/校验/更新 | ✅ |
| 🧠 长期记忆 | 来源、置信度、检索次数可审计;可编辑与调整 | ✅ |
| 🌐 本地网关 | OpenAI 兼容 `/v1/models`、`/v1/chat/completions`(SSE) | ✅ |
| 💻 工作台 | 文件浏览、Git status/diff、Shell(完全控制 + 确认) | ✅ |
| 🔒 本地优先 | 数据在本地 SQLite / Documents;API Key 在钥匙串 | ✅ |

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

支持 stdio 与 Streamable HTTP;`mcp__<server>__<tool>` 仅在完全控制模式 + 审批后执行。

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
# 151 tests in 31 suites passed
```

## 🔄 与旧版的关系

- Python 原版:[windbreake/ShizukuAgent](https://github.com/windbreake/ShizukuAgent)
- 旧 Swift 仓库:`windbreake/ShizukuClaw`(仅存档)
- 当前仓库:`JohnWick6999/HIVEs-Harness`

## 📄 许可证

GPL-3.0。
