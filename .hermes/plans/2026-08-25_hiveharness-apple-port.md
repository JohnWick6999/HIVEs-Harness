# HiveHarness Apple 移植计划(历史归档)

> 原名 ShizukuClaw,现统一为 HIVE's Harness / HiveHarness。以下为早期计划,已大部分完成。

> **目标:** 把 HiveHarness(Python 本地 AI 智能体)用 Swift 原生重写,适配 Apple 全生态:macOS、iOS、iPadOS、watchOS、visionOS(按优先级推进)。

**命名(已定):** 软件名 **HiveHarness**(App/产品名);内部核心库名 **HiveHarnessCore**(引擎库);与 GitHub 原仓库同名,保持品牌一致。

**架构:** 单一共享核心 Swift Package(`HiveHarnessCore`,纯 Foundation + Swift Concurrency,全平台通用)+ 每平台一个薄 SwiftUI App 壳。核心承载 Agent 循环、LLM 客户端、工具、记忆、存储、MCP、人格,平台壳只负责 UI 和系统集成。

**技术栈:** Swift 6.4 / SwiftUI / Swift Concurrency(actor + async/await)/ GRDB(SQLite)/ URLSession / SPM。可选:Apple 官方 `modelcontextprotocol/swift-sdk`(MCP 客户端)。

---

## 1. 现状盘点

### 1.1 原项目(参考基线)
- **旧版 `HiveHarness_remake_alpha1.0`(可运行,功能基线):** FastAPI + Vue3 前后端分离;工具循环 Agent(OpenAI 兼容 API,最多 6 轮);SQLite/MySQL/PG 存储抽象;MCP 服务器注册表;插件策略系统;Skill 框架;5 个人格(SKILL.md + persona.json);双层密码安全;文件工作区沙箱。
- **新版根目录(LangGraph 骨架,仅作架构参考):** `LLMClient` 抽象(chat/embed)、`State` 状态、路由图、ToolRegistry。当前有 4 个致命 bug,不可运行。

### 1.2 本机开发环境
| 项目 | 状态 |
|---|---|
| macOS 27.0 (arm64) | ✅ |
| Swift 6.4 (swiftlang-6.4.0) | ✅ |
| Swift Package Manager | ✅(CLT 自带,`swift build`/`swift test` 可跑) |
| Xcode | ❌ **未安装**(只有 Command Line Tools)→ iOS/watchOS/visionOS 目标、模拟器、TestFlight 全部依赖 Xcode |
| 硬件 | M5 Pro 64GB(本地构建绰绰有余) |

**关键前提:Phase 0 必须从 App Store 安装 Xcode(约 12GB,免费),否则只有 macOS 命令行目标能构建。**

---

## 2. 总体架构

```
┌──────────────────────────── 平台壳(SwiftUI) ────────────────────────────┐
│  macOS App      iOS/iPadOS App     watchOS App      visionOS App         │
│  (菜单栏+窗口)    (聊天+分享扩展)    (快捷问答)        (空间窗口, P5)        │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │  进程内直接调用(async)
┌───────────────────────────────▼─────────────────────────────────────────┐
│                      HiveHarnessCore(共享 Swift Package)                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐      │
│  │AgentLoop │ │ LLMClients│ │ Tools    │ │ Memory   │ │ MCP      │      │
│  │(工具循环/ │ │ (OpenAI  │ │ (Tool协议│ │ (GRDB    │ │ (stdio/  │      │
│  │ 图路由)   │ │  兼容/本地)│ │  +注册表) │ │  +向量检索)│ │  http)   │      │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘      │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌───────────────────────────┐  │
│  │Persona   │ │ Plugin   │ │ Config   │ │ Storage(GRDB 4表/迁移)     │  │
│  │(人格系统) │ │(策略引擎) │ │(Keychain)│ │                           │  │
│  └──────────┘ └──────────┘ └──────────┘ └───────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

**设计原则:**
- **Core 零 UI 依赖**——只依赖 Foundation + 少量 SPM 包,保证 `swift test` 可在无 Xcode 环境全量验证。
- **全异步**——所有 I/O 走 `async/await`,Agent 循环是 `actor`,天然线程安全(解决原 Python 版 RLock 手写锁的问题)。
- **功能对等而非代码移植**——保留原版的行为与配置模型(OpenAI 兼容端点、人格、记忆、工具),用 Swift 惯用法重写。

---

## 3. 模块映射表(Python → Swift)

| 原 Python 模块 | Swift 对应 | 说明 |
|---|---|---|
| `app/agent/loop.py`(工具循环) | `AgentLoop`(actor) | 最多 6 轮工具调用;`ToolResult` 结构化返回 |
| `src/graph/*`(LangGraph 骨架) | `AgentGraph`(actor,自定义状态机) | v1 先用简单路由(`router → tools/respond`);不引入第三方图库,保持可控 |
| `src/llm/*`(`LLMClient`) | `LLMClient`(protocol, Sendable) | `chat(streaming:)` / `embed`;实现 `OpenAICompatibleClient`(可指向任何兼容端点,含用户代理/中转)、`LocalOllamaClient`(macOS,本地 11434) |
| `src/tools/*`(ToolRegistry) | `Tool`(protocol) + `ToolRegistry`(actor) | 内置 5 工具:listDir / readFile / writeFile / searchMemory / addMemory;`runLocalAgent` 仅 macOS |
| `app/storage/adapter.py`(674 行) | `Storage`(GRDBStore) | 4 张表对齐:chatRecords / memories / checkpoints / kvStore;`Codable` 模型 + 迁移;只保留 SQLite(Apple 场景不需要 MySQL/PG) |
| 记忆向量检索(hash+余弦) | `EmbeddingStore` | 同款本地 hash 向量 + 余弦相似度;macOS 可选升级 `NaturalLanguage` 框架嵌入 |
| `app/mcp_manager.py` | `MCPClient` | JSON-RPC 2.0;stdio 传输(Process 管道,仅 macOS)+ http/sse 传输(全平台);MCP 工具动态注册进 ToolRegistry |
| `app/plugin_manager.py` | `PluginManager` | plugin.json 解码 + 策略(网络/执行时限/域白名单) |
| `app/persona_store.py` | `PersonaStore` | 5 个人格内嵌为 Bundle 资源;`buildSystemPrompt` 同逻辑 |
| `app/config.py` | `AppConfig`(Codable) | 敏感字段(API Key)→ Keychain;常规字段 → AppStorage/UserDefaults |
| `app/main.py`(FastAPI) | 不需要 | 进程内调用;仅当需要浏览器/外部客户端时,再考虑内嵌本地 HTTP 服务(P5 可选) |
| `frontend/`(Vue) | SwiftUI Views | macOS 完整桌面 UI;iOS 移动聊天 UI |
| 安全(双层密码/命令白名单) | `SecurityManager` + Face ID/Touch ID | 工作模式解锁用系统生物认证;iOS 无法执行任意命令,天然更安全 |

---

## 4. 各平台适配方案

### 4.1 macOS(第一优先级,功能最全)
- 菜单栏常驻 + 主窗口聊天界面;窗口可最小化到菜单栏
- 文件工具访问**应用沙箱外路径**需安全作用域书签(security-scoped bookmarks),替代原版工作区沙箱(更安全)
- MCP stdio 服务器、`runLocalAgent`(调 opencode/codex/hermes 等 CLI)仅此平台可用
- 系统集成:App Intents(快捷指令)、Services、拖拽文件进聊天窗口
- 分发:Developer ID 签名 + notarization(公证)

### 4.2 iOS / iPadOS(第二优先级)
- 聊天优先 UI:iPad 分栏(侧栏人格 + 对话 + 工具轨迹),iPhone 单页导航
- **Share Extension**:任何 App 选中文本/图片 → 发送给 HIVE(对应原版附件处理)
- **WidgetKit 小组件**:快捷提问入口
- **App Intents**:Siri "问 HIVE..."
- 后台长任务 → 后台任务 + 本地通知(不支持常驻进程)
- MCP 仅支持 http/sse 远程服务器;本地文件工具只能访问 App 沙箱内文件

### 4.3 watchOS(第三优先级)
- WatchConnectivity 中继:手表提问 → iPhone 上 Core 处理 → 结果回推
- 快捷问答、提醒类工具(watchOS 天然适合)

### 4.4 visionOS(第四优先级,尝鲜)
- 空间窗口聊天;Volumes 里放人格 3D 形象(可选,后期)

### 4.5 跨设备
- **CloudKit 同步**:记忆/聊天记录/人格配置跨设备(iCloud 需要开发者账号,免费账号可开发调试)
- **Handoff**:macOS ↔ iOS 无缝接力
- 平台能力差异用"功能矩阵"明确标注(见 §8)

---

## 5. 分阶段实施计划

### Phase 0:环境与骨架(0.5 天)
1. **安装 Xcode**(App Store,约 12GB)——解锁全部平台目标。`xcode-select -s /Applications/Xcode.app/Contents/Developer`
2. 在 `SCALW_APPLE/` 初始化 git 仓库 + 目录结构:
   ```
   SCALW_APPLE/
   ├── Package.swift            # HiveHarnessCore
   ├── Sources/HiveHarnessCore/…
   ├── Tests/HiveHarnessCoreTests/…
   ├── HIVE macOS/           # Xcode 工程(macOS target)
   └── README.md
   ```
3. 验证:`swift build && swift test` 空包通过;`git init && 首次 commit`

### Phase 1:HiveHarnessCore v1(核心,1.5 周)——纯 SPM,全程 `swift test` 验证
> ✅ **已完成(2026-08-25)** 8 个提交,54 项测试全绿,0 警告,~3800 行 Swift。
> 关键偏差:① 弃用 GRDB → 系统 SQLite3 封装(实测 github.com 不可达,零依赖保证构建可复现);② Tool 协议升级为 async(MCP 工具需要);③ 记忆检索加"共享字符过滤 + 余弦排序"(64 维哈希向量碰撞噪声实测达 0.3,纯余弦阈值不可靠)。
1. **Config + Keychain**:`AppConfig` Codable(provider/model/baseURL/temperature/maxRounds/人格默认值);Keychain 封装 `KeychainStore`
2. **LLM 层**:`LLMClient` protocol(async chat 支持 streaming + 非流式、embed);`OpenAICompatibleClient`(URLSession,任意 baseURL + Bearer Key,与原版 `base_url` 配置对齐);`LocalOllamaClient`(macOS)
3. **Storage**:GRDB 接入,4 表 schema + 迁移 v1;`ChatRecord/Memory/Checkpoint/KV` Codable 模型;`MemoryStore`(写入/列表/搜索,hash 向量 + 余弦)
4. **Tools**:`Tool` protocol + `ToolRegistry` actor;内置 5 工具;路径沙箱 `SafePath`(对齐原版 `_safe_path` 逃逸防护)
5. **AgentLoop**:actor 工具循环(最多 6 轮,OpenAI 工具调用协议,`temperature 0.4` 对齐原版);无 Key 时本地回退回复;人格 prompt 注入 + 长期记忆注入;checkpoint 保存(最近 40 条,对齐原版)
6. **Persona**:`Persona` Codable + Bundle 资源(5 人格);`PersonaStore`
7. **MCP 客户端**:JSON-RPC 2.0 编解码 + stdio 传输(Process);`MCPServer` 注册表(servers.json 兼容原格式);工具自动注册
8. **PluginManager**:plugin.json 解析 + 策略默认值
9. 单测覆盖:LLM mock、工具沙箱、记忆检索、循环轮次上限、MCP JSON-RPC 编解码

### Phase 2:macOS App(2 周)
1. Xcode 工程 `HiveHarness`(macOS target):SwiftUI 聊天界面(消息流 + 流式打字效果 + 工具调用轨迹展示,对应原版 trace)
2. 人格选择器、长期记忆管理页(查看/删除/新增)
3. 设置页:模型/端点/API Key(Keychain 存储,回显 `***` 逻辑对齐原版)、工作模式开关 + 生物认证解锁
4. **MCP 服务器管理 UI**(servers.json 兼容原格式:新增/编辑/启停/状态)
5. **插件管理 UI**(plugin.json 列表、策略编辑:网络/执行时限/域白名单)
6. 文件工具接入:工作区目录选择(安全作用域书签)
7. 菜单栏常驻 + 全局快捷键唤起
8. 验证:本地起 `ollama` 或任意 OpenAI 兼容端点实测端到端对话 + 工具调用 + MCP 工具

### Phase 3:iOS / iPadOS App(2 周)
1. iOS 工程(最低 iOS 17):复用 Core;聊天 UI(iPad 分栏)
2. Share Extension:文本/图片 → Agent
3. WidgetKit 快捷提问 + App Intents(Siri)
4. 附件/图片处理(对齐原版 `_collect_images` 逻辑:多模态 URL 传给模型)
5. 后台任务 + 本地通知(长任务完成提醒)

### Phase 4:watchOS(1.5 周,可选,待 macOS/iOS 稳定后启动)
1. watchOS App:WatchConnectivity 中继(手表提问 → iPhone 处理 → 回推)+ 快捷问答
2. ~~CloudKit 同步~~ **已搁置**(单机优先);~~Handoff~~ 标记为后期可选
3. 复杂功能(Complication)可选

### Phase 5:visionOS 与打磨(1 周)
1. visionOS 空间窗口聊天(复用 Core)
2. 可选:内嵌本地 HTTP 服务(OpenAI 兼容 `/v1/chat/completions`,给浏览器/外部工具用)
3. 分发准备:TestFlight(iOS/watchOS/visionOS)、Developer ID 公证(macOS)
4. 文档:功能矩阵、配置说明、人格自定义指南

---

## 6. 技术选型明细

| 依赖 | 用途 | 理由 |
|---|---|---|
| GRDB.swift | SQLite 存储 | 类型安全、迁移友好、纯 Swift,替代手写 sqlite3 绑定;对齐原版 4 表 |
| URLSession | LLM HTTP | 系统自带,流式 SSE 支持 |
| modelcontextprotocol/swift-sdk | MCP 客户端 | Apple 官方 SDK 方向;若体积/复杂度超标则自研(JSON-RPC 很简单) |
| KeychainAccess | Keychain 封装 | 或直接用 Security framework,零依赖 |
| NaturalLanguage(系统) | 可选嵌入升级 | macOS 上替代 hash 向量,提升记忆检索质量 |
| 不引入 | LangGraph 图库 | v1 路由简单,自研 actor 状态机更可控 |

---

## 7. 验证策略

- **核心层**:`swift test`(LLM mock、沙箱逃逸、记忆余弦检索、循环上限、MCP 编解码),CI 可跑
- **平台层**:Xcode 单测 + UI 测试(聊天冒烟);真机/模拟器手动验证
- **端到端**:真实 OpenAI 兼容端点(用户已有代理/中转)+ 本地 Ollama 双通道实测
- **回归**:原版 Python 仓库保留作行为参照,关键行为(回退回复文案、记忆注入格式、checkpoint 40 条)对齐

---

## 8. 功能矩阵(预期能力)

| 功能 | macOS | iOS/iPadOS | watchOS | visionOS |
|---|:---:|:---:|:---:|:---:|
| 聊天 + 流式回复 | ✅ | ✅ | ✅(中继) | ✅ |
| 人格系统(5 人格) | ✅ | ✅ | ✅ | ✅ |
| 长期记忆 + 检索 | ✅ | ✅ | ✅(读) | ✅ |
| 文件工具(沙箱内) | ✅ | ✅ | — | ✅ |
| 系统外文件(书签) | ✅ | — | — | — |
| MCP stdio 服务器 | ✅ | — | — | — |
| MCP http/sse | ✅ | ✅ | — | ✅ |
| 本地模型(Ollama) | ✅ | — | — | — |
| runLocalAgent(调 CLI) | ✅ | — | — | — |
| Share Extension | — | ✅ | — | — |
| Widget/快捷指令 | ✅(App Intents) | ✅ | ✅(复杂功能) | — |
| CloudKit 同步 | ✅ | ✅ | ✅ | ✅ |
| 生物认证解锁 | ✅ | ✅ | — | ✅ |

---

## 9. 风险与开放问题

| 风险 | 影响 | 对策 |
|---|---|---|
| **Xcode 未安装** | 阻塞 Phase 0 之后所有平台构建 | Phase 0 第一步安装;Core 阶段可用 CLT 先行 |
| macOS 沙箱 vs MCP stdio 子进程 | App Store 沙箱限制 Process 派生 | 默认非沙箱 Developer ID 分发;或助手进程方案 |
| iOS 无法派生进程 | runLocalAgent / stdio MCP 在 iOS 不可用 | 功能矩阵明示;iOS 聚焦聊天+记忆+远程 MCP |
| Swift 6 严格并发改造成本 | 编译期报错多 | Core 一开始就按 `Sendable`/actor 设计,不后补 |
| CloudKit/TestFlight 需要开发者账号 | 免费账号可开发调试,分发受限 | 先免费账号开发;上架前再付费(¥688/年) |
| LLM 端点网络(用户在境内) | 直连 OpenAI 不稳 | 沿用原版设计:任意 baseURL 可配(用户已有加速器/中转) |

**✅ 已确认决策(2026-08-25):**
1. **首发平台:macOS 先行**,跑通后再做 iOS
2. **MCP/插件系统全量进 v1**,包括插件管理 UI(macOS 设置页)
3. **不做 iCloud 同步**,单机优先;CloudKit/Handoff 标记为"后期可选"(Phase 4 原内容搁置)
4. **Xcode 由用户自行安装**,装完通知后开始 Phase 0 执行

---

## 10. 预期时间线(单人)

| 阶段 | 工期 | 交付物 |
|---|---|---|
| Phase 0 环境骨架(等 Xcode 装好) | 0.5 天 | Xcode + git + 空包可测 |
| Phase 1 HiveHarnessCore | 1.5 周 | `swift test` 全绿的核心库(含 MCP/插件) |
| Phase 2 macOS App | 2 周 | 可日常使用的 macOS 版(含 MCP/插件管理 UI) |
| Phase 3 iOS App | 2 周 | iOS/iPadOS 版 + 分享扩展 |
| Phase 4 watchOS(可选) | 1.5 周 | 手表快捷问答 |
| Phase 5 visionOS + 分发 | 1 周 | 全平台 + TestFlight |
| **合计** | **约 8 周** | 核心 3.5 周内出可用 macOS 版 |

> 核心(Phase 1 + 2)约 3.5 周即可产出可用的 macOS 版,后续平台按需推进。
