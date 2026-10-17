import Foundation
@testable import HiveHarnessCore
import Testing

private func makePersonaDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hiveharness-personas-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("人格仓库")
struct PersonaStoreTests {
    @Test("内置人格为通用人格,不含旧二次元角色")
    func builtinPersonas() {
        let store = PersonaStore()
        let personas = store.listPersonas()
        #expect(personas.count >= 7)
        #expect(personas.allSatisfy { $0.isBuiltin })
        #expect(store.load(id: "assistant") != nil)
        #expect(store.defaultPersona()?.id == "assistant")
        #expect(store.load(id: "engineer") != nil)
        #expect(store.load(id: "researcher") != nil)
        #expect(store.load(id: "shizuku") == nil)
        #expect(store.load(id: "azuma") == nil)
    }

    @Test("自定义人格可新增、编辑、删除")
    func customPersonaCRUD() throws {
        let dir = try makePersonaDirectory()
        let store = PersonaStore(userDirectory: dir)

        var persona = Persona(
            meta: .init(name: "我的助手", description: "自定义"),
            character: .init(name: "我的助手", personality: "简洁")
        )
        persona.id = "custom-test"
        try store.save(persona)

        let saved = try #require(store.load(id: "custom-test"))
        #expect(saved.isBuiltin == false)
        #expect(saved.meta.name == "我的助手")
        #expect(store.isBuiltin(id: "custom-test") == false)

        var edited = saved
        edited.meta.description = "已编辑"
        try store.save(edited)
        #expect(store.load(id: "custom-test")?.meta.description == "已编辑")

        try store.delete(id: "custom-test")
        #expect(store.load(id: "custom-test") == nil)
    }

    @Test("内置人格可覆盖并恢复默认,且不可删除")
    func builtinOverrideAndReset() throws {
        let dir = try makePersonaDirectory()
        let store = PersonaStore(userDirectory: dir)
        var builtin = try #require(store.load(id: "assistant"))
        let originalDescription = builtin.meta.description
        #expect(builtin.isBuiltin)

        builtin.meta.description = "我的定制助手"
        try store.save(builtin)
        #expect(store.isCustomized(id: "assistant"))
        #expect(store.load(id: "assistant")?.meta.description == "我的定制助手")
        #expect(store.load(id: "assistant")?.isBuiltin == true)

        try store.resetBuiltin(id: "assistant")
        #expect(store.isCustomized(id: "assistant") == false)
        #expect(store.load(id: "assistant")?.meta.description == originalDescription)

        #expect(throws: PersonaError.self) {
            try store.delete(id: "assistant")
        }
    }

    @Test("系统提示词包含行为规则")
    func promptIncludesRules() throws {
        let store = PersonaStore()
        let persona = try #require(store.load(id: "engineer"))
        let prompt = persona.buildSystemPrompt()
        #expect(prompt.contains("工程师"))
        #expect(prompt.contains("[行为规则]"))
        #expect(prompt.contains("[回复风格]"))
    }
}
