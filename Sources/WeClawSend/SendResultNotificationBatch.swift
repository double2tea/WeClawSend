import Foundation

/// Coalesces multiple send terminal results into one notification body.
struct SendResultNotificationBatch: Equatable, Sendable {
    private(set) var successCount = 0
    private(set) var failureCount = 0
    private(set) var sampleSuccessName: String?
    private(set) var sampleFailureName: String?
    private(set) var sampleFailureMessage: String?

    var isEmpty: Bool {
        successCount == 0 && failureCount == 0
    }

    var totalCount: Int {
        successCount + failureCount
    }

    mutating func recordSuccess(fileName: String) {
        successCount += 1
        sampleSuccessName = fileName
    }

    mutating func recordFailure(fileName: String, message: String?) {
        failureCount += 1
        sampleFailureName = fileName
        if let message, !message.isEmpty {
            sampleFailureMessage = message
        }
    }

    var body: String {
        switch (successCount, failureCount) {
        case (1, 0):
            return "发送完成：\(sampleSuccessName ?? "文件")"
        case (let success, 0) where success > 1:
            return "已发送 \(success) 个文件"
        case (0, 1):
            let name = sampleFailureName ?? "文件"
            if let sampleFailureMessage, !sampleFailureMessage.isEmpty {
                return "发送失败：\(name)（\(sampleFailureMessage)）"
            }
            return "发送失败：\(name)"
        case (0, let failure) where failure > 1:
            return "\(failure) 个文件发送失败"
        case (let success, let failure) where success > 0 && failure > 0:
            return "发送完成 \(success) 个，失败 \(failure) 个"
        default:
            return "发送已结束"
        }
    }
}
