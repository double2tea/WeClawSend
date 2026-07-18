import Foundation

struct PopoverAutoClosePolicy {
    static let inactivityInterval: TimeInterval = 30
    static let transferCompletionInterval: TimeInterval = 5

    private var deadline: Date?
    private var hadActiveTransfers = false

    mutating func opened(at date: Date) {
        hadActiveTransfers = false
        deadline = date.addingTimeInterval(Self.inactivityInterval)
    }

    mutating func interacted(at date: Date) {
        deadline = date.addingTimeInterval(Self.inactivityInterval)
    }

    mutating func shouldClose(
        at date: Date,
        hasActiveTransfers: Bool,
        blocksAutoClose: Bool
    ) -> Bool {
        let completedTransfers = hadActiveTransfers && !hasActiveTransfers
        hadActiveTransfers = hasActiveTransfers

        if hasActiveTransfers || blocksAutoClose {
            deadline = nil
            return false
        }
        if completedTransfers {
            deadline = date.addingTimeInterval(Self.transferCompletionInterval)
        } else if deadline == nil {
            deadline = date.addingTimeInterval(Self.inactivityInterval)
        }
        return deadline.map { date >= $0 } ?? false
    }

    mutating func closed() {
        deadline = nil
        hadActiveTransfers = false
    }
}
