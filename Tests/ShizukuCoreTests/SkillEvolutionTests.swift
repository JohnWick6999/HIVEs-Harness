import Foundation
@testable import ShizukuCore
import Testing

private func evolutionDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("shizuku-evolve-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func sampleTrajectory() -> AgentTrajectory {
    AgentTrajectory(
        userMessage: "帮我审查这个文件",
        reply: "发现两个问题",
        persona: "shizuku",
        threadID: "thread-1",
        traces: [
            ToolTrace(tool: "read_file", arguments: #"{"path":"a.swift"}"#, result: "代码"),
            ToolTrace(tool: "write_file", arguments: #"{"path":"report.md"}"#, result: "已写入"),
        ]
    )
}

private let validProposalJSON = #"""
{"skip":false,"id":"code-review-auto","name":"代码审查流程","description":"需要审查 Swift 文件时使用","tags":["review","swift"],"body":"1. 读取目标文件\n2. 检查错误处理与并发\n3. 按严重级别输出问题\n4. 给出最小修复建议\n5. 验证修复","reason":"这次审查流程可复用"}
"""#

@Suite("技能自进化")
struct SkillEvolutionTests {
    @Test("成功轨迹生成提案并落盘")
    func generatesProposal() async throws {
        let dir = try evolutionDirectory()
        let evolver = SkillEvolver(skillsDirectory: dir)
        let proposal = await evolver.consider(
            trajectory: sampleTrajectory(),
            existingIDs: []
        ) { _, _ in validProposalJSON }

        let unwrapped = try #require(proposal)
        #expect(unwrapped.id == "code-review-auto")
        #expect(unwrapped.tags == ["review", "swift"])
        #expect(evolver.proposals().count == 1)
        #expect(evolver.proposals().first?.body.contains("读取目标文件") == true)
    }

    @Test("一次性任务返回 skip 时不生成提案")
    func skipsOneOff() async throws {
        let dir = try evolutionDirectory()
        let evolver = SkillEvolver(skillsDirectory: dir)
        let proposal = await evolver.consider(
            trajectory: sampleTrajectory(),
            existingIDs: []
        ) { _, _ in #"{"skip":true,"reason":"一次性问答"}"# }

        #expect(proposal == nil)
        #expect(evolver.proposals().isEmpty)
    }

    @Test("无效 JSON / 过短正文被拒绝")
    func rejectsInvalid() async throws {
        let dir = try evolutionDirectory()
        let evolver = SkillEvolver(skillsDirectory: dir)
        let invalid = await evolver.consider(
            trajectory: sampleTrajectory(),
            existingIDs: []
        ) { _, _ in "not json" }
        #expect(invalid == nil)

        let tooShort = await evolver.consider(
            trajectory: sampleTrajectory(),
            existingIDs: []
        ) { _, _ in
            #"{"skip":false,"id":"short","name":"短","description":"太短","body":"1. 做"}"#
        }
        #expect(tooShort == nil)
    }

    @Test("重复 id 自动加后缀")
    func uniqueID() async throws {
        let dir = try evolutionDirectory()
        let evolver = SkillEvolver(skillsDirectory: dir)
        let proposal = await evolver.consider(
            trajectory: sampleTrajectory(),
            existingIDs: ["code-review-auto"]
        ) { _, _ in validProposalJSON }
        #expect(proposal?.id == "code-review-auto-2")
    }

    @Test("批准后进入技能库,拒绝后删除提案")
    func approveAndReject() async throws {
        let dir = try evolutionDirectory()
        let evolver = SkillEvolver(skillsDirectory: dir)

        let proposal = try #require(
            await evolver.consider(
                trajectory: sampleTrajectory(),
                existingIDs: []
            ) { _, _ in validProposalJSON }
        )
        let skill = try evolver.approve(proposal)
        #expect(skill.id == "code-review-auto")
        #expect(skill.isBuiltin == false)
        #expect(evolver.proposals().isEmpty)

        let store = SkillStore(userDirectory: dir)
        #expect(store.load(id: "code-review-auto") != nil)

        let second = try #require(
            await evolver.consider(
                trajectory: sampleTrajectory(),
                existingIDs: ["code-review-auto"]
            ) { _, _ in validProposalJSON }
        )
        try evolver.reject(second)
        #expect(evolver.proposals().isEmpty)
    }
}
