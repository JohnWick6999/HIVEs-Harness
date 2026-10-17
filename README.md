# ShizukuClaw · Apple 原生移植版

> 由 [Shizuku_Nya_Bot](https://github.com/windbreake/ShizukuClaw) 重构而来的本地 AI 智能体,使用 **Swift 原生重写**,适配 Apple 全生态(macOS / iOS / iPadOS / watchOS / visionOS)。

**ShizukuClaw** 是一个跑在你设备上的陪伴型 AI:人格系统、长期记忆、工具调用、MCP 插件,全部本地存储,OpenAI 兼容端点即插即用(官方 API / 中转 / 本地 Ollama 均可)。

当前阶段:**Alpha 0.1(macOS 先行)**,核心引擎 `ShizukuCore` 已完整可用。

---

## ✨ 功能特性

| 功能 | 说明 | 状态 |
|---|---|---|
| 💬 流式聊天 | 字符级打字动画,SSE 流式输出 | ✅ |
| 🐱 人格系统 | 5 个内置人格(小雫/azuma/selena/Yukikaze/ui),对话历史按人格隔离 | ✅ |
| 🧠 长期记忆 | SQLite 存储 + 哈希向量余弦检索,聊天自动记忆(≥12 字),可视化管理页 | ✅ |
| 🔧 工具调用 | 文件读写(工作区沙箱)、记忆检索/写入、本地 Agent CLI(macOS) | ✅ |
| ✅ 任务计划 | todowrite/todoread,计划持久化 + 实时进度面板,运行绑定防跨轮串写 | ✅ |
| 🗂️ 多会话 | 会话列表 / 新建 / 撤销上一轮 / 分叉 / 清空 / 删除,按人格隔离,旧历史自动迁移 | ✅ |
| 🧮 上下文压缩 | CJK token 估算,85% 自动摘要压缩,保留最近两轮,原始消息不删除,顶栏用量环 | ✅ |
| 🛡️ 工作模式与审批 | 对话/安全/完全控制三档;读任意路径、写受模式限制;外部写入与执行需审批;Touch ID 解锁 | ✅ |
| 📄 文件产物卡片 | 工具产出的文件渲染为可点击附件,点击打开 / Finder 定位 | ✅ |
| 🔌 MCP 客户端 | JSON-RPC 2.0 over stdio / Streamable HTTP,servers.json,工具以 `mcp__<server>__` 前缀注册,仅完全控制模式可用 | ✅ |
| 🧩 插件系统 | plugin.json 清单扫描 + 安全策略(网络/执行时限/域名白名单) | ✅ |
| 🖥️ 菜单栏常驻 | 顶栏图标 + 快速提问,随时唤起 | ✅ |
| 🔑 密钥安全 | API Key 存钥匙串(Keychain),不进配置文件 | ✅ |
| ⚙️ 多模型接入 | 多提供商 / 多模型 / 模型组回退链;任意 OpenAI 兼容端点或本地 Ollama;每提供商独立 Key | ✅ |

## 🏗️ 架构

```
┌────────────── 平台壳(SwiftUI)──────────────┐
│  macOS App(菜单栏+窗口)· iOS · watchOS …   │
└──────────────────┬─────────────────────────┘
                   │ 进程内调用(async/await)
┌──────────────────▼─────────────────────────┐
│           ShizukuCore(共享引擎库)           │
│  Config · LLM · Storage · Tools · Agent    │
│  Persona · MCP · Plugin                    │
│  (纯 Foundation + 系统 SQLite3,零第三方依赖) │
└────────────────────────────────────────────┘
```

### 核心模块

| 模块 | 职责 |
|---|---|
| `Config/` | AppConfig(Codable)、KeychainStore、ModelRegistry(提供商/模型/回退组) |
| `LLM/` | LLMClient 协议、OpenAI 兼容客户端(SSE 流式)、本地 Ollama 客户端 |
| `Storage/` | 系统 SQLite3 封装(chat_records/memories/checkpoints/kv_store/task_plans/session_context/sessions)、哈希向量余弦检索 |
| `Tools/` | Tool 协议(async)、注册表、SafePath 工作区沙箱、6 个内置工具 + todowrite/todoread |
| `Agent/` | AgentLoop actor:工具循环、无 Key 回退、checkpoint、自动记忆;TaskPlan 计划;ContextManager 压缩 |
| `Persona/` | Persona 模型 + 5 内置人格(Bundle 资源,id=文件名) |
| `MCP/` | JSON-RPC 2.0 编解码、stdio 子进程 / Streamable HTTP 传输、配置加载、工具适配器 |
| `Plugin/` | plugin.json 扫描、安全策略(容错解码) |

## 🛠️ 技术栈

- **Swift 6.2+**(清单按 6.2 声明,当前用 6.4 / Xcode-beta 工具链验证)/ SwiftUI / Swift Concurrency(actor + async/await)
- **Swift Package Manager**,**零第三方依赖**(系统 SQLite3 + Foundation + Security)
- 部署目标:macOS 14+ / iOS 17+ / watchOS 10+ / visionOS 1+
- 测试:swift-testing,93 项用例覆盖全部核心模块

## 🚀 构建与运行

```bash
# 单元测试(核心引擎)—— 用脚本自动选择 Xcode 工具链
./scripts/test.sh

# 开发运行(直接弹窗)
swift run ShizukuClaw

# 打包为正式 .app 并启动(推荐日常使用)
./scripts/make_app.sh && open build/ShizukuClaw.app
```

> 为什么测试要走脚本:Command Line Tools 的 Swift Testing 宏插件位于
> `usr/lib/swift/host/plugins/testing/`,swift-driver 默认不加载,直接 `swift test`
> 会报 `plugin for module 'TestingMacros' not found`。脚本会优先使用已安装的
> Xcode / Xcode-beta 工具链(`DEVELOPER_DIR`)。仅编译 App 不受此影响。

### 仓库关系

| remote | 地址 | 用途 |
|---|---|---|
| `upstream` | `github.com/windbreake/ShizukuAgent` | Python 原版,行为参照 |
| `legacy` | `github.com/windbreake/ShizukuClaw` | 旧仓库,仅存档 |

当前仓库是独立 macOS Agent 的 Swift 实现;新建托管仓库后会把 `origin` 指向新地址。

### 首次使用

1. 启动 App,点击右上角 ⚙️ 设置
2. 填写模型配置(二选一):
   - **OpenAI 兼容端点**:Base URL(如 `https://api.deepseek.com`)+ 模型名 + API Key(存入钥匙串)
   - **本地 Ollama**:供应商选 Ollama,模型填已拉取的模型名(如 `qwen2.5`)
3. 不配置也能用:无 Key 时自动进入**本地回退模式**回复
4. 顶栏 🐱 图标 = 菜单栏常驻,随时快速提问

### 数据位置

| 数据 | 路径 |
|---|---|
| 数据库(对话/记忆/检查点) | `~/Library/Application Support/ShizukuClaw/agent.db` |
| 工作区(文件工具沙箱) | `~/Documents/ShizukuClaw/` |
| 配置文件 | `~/Library/Application Support/ShizukuClaw/config.json` |
| MCP 配置 | `~/Documents/ShizukuClaw/mcp/servers.json` |
| API Key | 钥匙串(`com.shizukuclaw.app`,按 `provider.<id>.api_key` 存储) |

### MCP 配置示例

```json
{
  "servers": [
    {
      "id": "files",
      "name": "Files",
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Documents"],
      "enabled": true
    },
    {
      "id": "remote",
      "name": "Remote",
      "type": "http",
      "url": "https://example.com/mcp",
      "headers": {"Authorization": "Bearer …"},
      "enabled": true
    }
  ]
}
```

MCP 工具名会带 `mcp__<server>__` 前缀;只有**完全控制**模式会把它们暴露给模型,每次调用前都要在对话里审批。设置 → MCP 可直接编辑并重载。

## 📂 目录结构

```
├── Sources/
│   ├── ShizukuCore/          # 共享引擎库(核心)
│   └── ShizukuClaw/          # macOS App(SwiftUI)
├── Tests/ShizukuCoreTests/   # 单元测试(含假 MCP 服务器夹具)
├── scripts/
│   ├── make_app.sh           # .app 打包脚本
│   └── Info.plist            # App bundle 配置
├── .hermes/plans/            # 移植规划文档
└── Package.swift
```

## 🔄 与原版的关系

本仓库是原版 Python 项目的 **Swift 原生重写**(行为对等,非代码移植):
- 保留:人格、长期记忆、工具循环、MCP 注册表、工作区沙箱、OpenAI 兼容端点设计
- 演进:actor 并发替代手写锁、`ToolResult` 结构化产物(文件卡片)、流式事件流、字符级打字动画
- 修复了原版若干 bug(如 ToolRegistry 判断反转、SSE 空行分隔符解析)

## 🗺️ 路线图

- [x] Phase 0 环境与骨架
- [x] Phase 1 ShizukuCore 核心引擎(8 模块,57 测试)
- [x] Phase 2 macOS App(聊天/流式/工具卡片/菜单栏/记忆管理)
- [x] Phase 2 收尾:工作模式+生物认证、MCP 管理 UI
- [ ] 全局快捷键、插件管理 UI
- [ ] Phase 3 iOS / iPadOS 版(复用核心 + 分享扩展)
- [ ] Phase 4 watchOS(可选)
- [ ] Phase 5 visionOS + TestFlight 分发

## 📄 许可证

参考原项目:GPL-3.0
