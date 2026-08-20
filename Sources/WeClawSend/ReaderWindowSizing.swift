import CoreGraphics
import Foundation

enum ShelfWindowSizingMode: Equatable, Sendable {
    case collection
    case collapsed
    case reader
    case audio
    case reminder
}

/// Window geometry in logical points. All methods are pure with respect to
/// their arguments; visible-frame handling is deterministic and side-effect
/// free.
enum ReaderWindowSizing {
    static let collectionSize = CGSize(width: 340, height: 340)
    static let collapsedSize = CGSize(width: 248, height: 52)
    static let readerPreferredSize = CGSize(width: 640, height: 720)
    static let readerMinimumSize = CGSize(width: 480, height: 420)
    static let audioPreferredSize = CGSize(width: 520, height: 228)
    static let audioMinimumSize = CGSize(width: 400, height: 196)
    static let audioMaximumSize = CGSize(width: 720, height: 320)
    static let reminderPreferredSize = CGSize(width: 440, height: 240)
    static let reminderMinimumSize = CGSize(width: 320, height: 140)
    static let reminderMaximumSize = CGSize(width: 760, height: 500)
    static let visibleFrameInset: CGFloat = 12

    static func preferredSize(for mode: ShelfWindowSizingMode) -> CGSize {
        switch mode {
        case .collection:
            collectionSize
        case .collapsed:
            collapsedSize
        case .reader:
            readerPreferredSize
        case .audio:
            audioPreferredSize
        case .reminder:
            reminderPreferredSize
        }
    }

    static func preferredSize(for mode: ShelfPresentationMode) -> CGSize {
        switch mode {
        case .collection:
            collectionSize
        case .reader:
            readerPreferredSize
        case .reminder:
            reminderPreferredSize
        }
    }

    static func minimumSize(for mode: ShelfWindowSizingMode) -> CGSize {
        switch mode {
        case .collection:
            collectionSize
        case .collapsed:
            collapsedSize
        case .reader:
            readerMinimumSize
        case .audio:
            audioMinimumSize
        case .reminder:
            reminderMinimumSize
        }
    }

    static func maximumSize(for mode: ShelfWindowSizingMode) -> CGSize? {
        switch mode {
        case .collection:
            collectionSize
        case .collapsed:
            collapsedSize
        case .reader:
            nil
        case .audio:
            audioMaximumSize
        case .reminder:
            reminderMaximumSize
        }
    }

    static func validStoredSize(_ size: CGSize?) -> CGSize? {
        guard let size,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else {
            return nil
        }
        return size
    }

    static func validStoredSize(width: Double?, height: Double?) -> CGSize? {
        guard let width, let height,
              width.isFinite,
              height.isFinite,
              width > 0,
              height > 0
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func resolvedSize(
        for mode: ShelfWindowSizingMode,
        storedSize: CGSize? = nil,
        visibleFrame: CGRect? = nil
    ) -> CGSize {
        let candidate = validStoredSize(storedSize) ?? preferredSize(for: mode)
        return clamp(candidate, for: mode, visibleFrame: visibleFrame)
    }

    static func resolvedSize(
        for mode: ShelfPresentationMode,
        storedSize: CGSize? = nil,
        visibleFrame: CGRect? = nil
    ) -> CGSize {
        let candidate = validStoredSize(storedSize) ?? preferredSize(for: mode)
        let sizingMode: ShelfWindowSizingMode = switch mode {
        case .collection: .collection
        case .reader: .reader
        case .reminder: .reminder
        }
        return clamp(candidate, for: sizingMode, visibleFrame: visibleFrame)
    }

    static func resolvedSize(
        for mode: ShelfPresentationMode,
        storedWidth: Double?,
        storedHeight: Double?,
        visibleFrame: CGRect? = nil
    ) -> CGSize {
        resolvedSize(
            for: mode,
            storedSize: validStoredSize(width: storedWidth, height: storedHeight),
            visibleFrame: visibleFrame
        )
    }

    static func resolvedSize(
        for mode: ShelfWindowSizingMode,
        storedSizeDescription: String?,
        visibleFrame: CGRect? = nil
    ) -> CGSize {
        resolvedSize(
            for: mode,
            storedSize: parseStoredSize(storedSizeDescription),
            visibleFrame: visibleFrame
        )
    }

    static func resolvedSize(
        for mode: ShelfWindowSizingMode,
        storedWidth: Double?,
        storedHeight: Double?,
        visibleFrame: CGRect? = nil
    ) -> CGSize {
        resolvedSize(
            for: mode,
            storedSize: validStoredSize(width: storedWidth, height: storedHeight),
            visibleFrame: visibleFrame
        )
    }

    static func clamp(
        _ size: CGSize,
        for mode: ShelfWindowSizingMode,
        visibleFrame: CGRect? = nil
    ) -> CGSize {
        let profileMinimum = minimumSize(for: mode)
        let profileMaximum = maximumSize(for: mode)
        let available = availableSize(in: visibleFrame)

        let maximumWidth = min(profileMaximum?.width ?? .greatestFiniteMagnitude, available?.width ?? .greatestFiniteMagnitude)
        let maximumHeight = min(profileMaximum?.height ?? .greatestFiniteMagnitude, available?.height ?? .greatestFiniteMagnitude)
        let minimumWidth = min(profileMinimum.width, maximumWidth)
        let minimumHeight = min(profileMinimum.height, maximumHeight)

        return CGSize(
            width: clamped(size.width, lowerBound: minimumWidth, upperBound: maximumWidth),
            height: clamped(size.height, lowerBound: minimumHeight, upperBound: maximumHeight)
        )
    }

    private static func availableSize(in visibleFrame: CGRect?) -> CGSize? {
        guard let visibleFrame,
              visibleFrame.size.width.isFinite,
              visibleFrame.size.height.isFinite,
              visibleFrame.size.width > 0,
              visibleFrame.size.height > 0
        else {
            return nil
        }
        return CGSize(
            width: max(0, visibleFrame.size.width - visibleFrameInset * 2),
            height: max(0, visibleFrame.size.height - visibleFrameInset * 2)
        )
    }

    private static func clamped(_ value: CGFloat, lowerBound: CGFloat, upperBound: CGFloat) -> CGFloat {
        guard value.isFinite else { return lowerBound }
        return min(max(value, lowerBound), upperBound)
    }

    private static func parseStoredSize(_ description: String?) -> CGSize? {
        guard let description else { return nil }
        let components = description.split { character in
            !(character.isNumber || character == "." || character == "+" || character == "-" || character == "e" || character == "E")
        }
        guard components.count >= 2,
              let width = Double(components[0]),
              let height = Double(components[1]),
              width.isFinite,
              height.isFinite,
              width > 0,
              height > 0
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}
