import Foundation

/// 文件访问策略:把工作模式与审批回调注入文件工具。
/// - 读:三种模式都允许工作区外绝对路径(与上游一致)
/// - 写:工作区内直接写;工作区外仅 full 模式,且必须先通过审批
public struct FileAccessPolicy: Sendable {
    public let mode: WorkMode
    public let approval: ApprovalHandler?

    public init(mode: WorkMode, approval: ApprovalHandler? = nil) {
        self.mode = mode
        self.approval = approval
    }

    public func resolveRead(_ raw: String, safePath: SafePath) throws -> URL {
        if mode.allowsOutsideRead {
            return safePath.resolveAny(raw)
        }
        return try safePath.resolve(raw)
    }

    public func resolveWrite(_ raw: String, safePath: SafePath) async throws -> URL {
        guard mode != .chat else {
            throw ToolError.permissionDenied("对话模式只读,不允许写文件。")
        }
        let target = safePath.resolveAny(raw)
        if safePath.isInsideWorkspace(target) {
            return target
        }
        guard mode.allowsOutsideWrite else {
            throw ToolError.permissionDenied(
                "\(mode.title)模式只能写入工作区;如需写入 \(target.path),请切换到完全控制模式。"
            )
        }
        guard let approval else {
            throw ToolError.approvalDenied("未配置审批处理器,已拒绝写入工作区外文件: \(target.path)")
        }
        let request = ApprovalRequest(kind: .externalWrite, detail: target.path)
        let decision = await approval(request)
        guard decision != .reject else {
            throw ToolError.approvalDenied("用户拒绝写入 \(target.path)")
        }
        return target
    }
}
