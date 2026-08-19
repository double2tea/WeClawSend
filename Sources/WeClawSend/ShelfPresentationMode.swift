import Foundation

/// The content currently presented by a file-basket window.
///
/// Collapsed is deliberately not part of this state. It is a window-session
/// concern and remains owned by `ShelfSessionState`.
enum ShelfPresentationMode: Equatable, Sendable {
    case collection
    case reader
    case reminder
}

/// The only presentation mode that is meaningful to restore across launches.
enum StoredShelfPresentationMode: String, Codable, Equatable, Sendable {
    case reminder
}

extension ShelfPresentationMode {
    var storedValue: StoredShelfPresentationMode? {
        switch self {
        case .collection, .reader:
            nil
        case .reminder:
            .reminder
        }
    }

    init(storedValue: StoredShelfPresentationMode?) {
        self = storedValue == .reminder ? .reminder : .collection
    }
}
