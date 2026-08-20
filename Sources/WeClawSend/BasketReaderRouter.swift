import Foundation
import UniformTypeIdentifiers

enum BasketReaderKind: String, Codable, Equatable, Sendable {
    case managedText
    case externalText
    case pdf
    case image
    case media
    case quickLook
    case fileInfo
}

enum BasketReaderRoutingError: Error, Equatable, Sendable {
    case nonFileURL
    case missingPath
    case symbolicLink
    case unsupportedItem
}

enum BasketReaderRoute: Equatable, Sendable {
    case reader(BasketReaderKind)
    case failure(BasketReaderRoutingError)

    var kind: BasketReaderKind? {
        guard case let .reader(kind) = self else { return nil }
        return kind
    }

    var error: BasketReaderRoutingError? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}

/// Pure content-to-reader routing. It performs only read-only URL metadata
/// checks and never constructs a view or a preview controller.
struct BasketReaderRouter: Sendable {
    static func route(for url: URL, isManagedText: Bool = false) -> BasketReaderRoute {
        guard url.isFileURL else { return .failure(.nonFileURL) }

        let lexicalURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: lexicalURL.path) else {
            return .failure(.missingPath)
        }

        guard let values = try? lexicalURL.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        ) else {
            return .failure(.unsupportedItem)
        }
        guard values.isSymbolicLink != true else { return .failure(.symbolicLink) }

        if values.isDirectory == true || values.isPackage == true {
            return .reader(.fileInfo)
        }
        guard values.isRegularFile == true else {
            return .failure(.unsupportedItem)
        }

        // Managed text is an ownership decision made by the text-clip store,
        // so it takes precedence over the file extension and UTI.
        if isManagedText {
            return .reader(.managedText)
        }

        let type = contentType(for: lexicalURL)
        let fileExtension = lexicalURL.pathExtension.lowercased()
        if ["txt", "md", "markdown"].contains(fileExtension) {
            return .reader(.externalText)
        }
        if type?.conforms(to: .pdf) == true {
            return .reader(.pdf)
        }
        if type?.conforms(to: .image) == true {
            return .reader(.image)
        }
        if type?.conforms(to: .audiovisualContent) == true
            || ["mp4", "m4v", "mov", "m4a", "mp3", "wav", "aac", "aiff", "caf"].contains(fileExtension)
        {
            return .reader(.media)
        }

        // Quick Look is the intentionally conservative fallback for regular
        // files. Its own provider decides whether a preview is available;
        // routing should not duplicate that provider's format table.
        return .reader(.quickLook)
    }

    static func route(for itemURL: URL, managedText: Bool) -> Result<BasketReaderKind, BasketReaderRoutingError> {
        switch route(for: itemURL, isManagedText: managedText) {
        case let .reader(kind):
            .success(kind)
        case let .failure(error):
            .failure(error)
        }
    }

    private static func contentType(for url: URL) -> UTType? {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let resourceType = values.contentType
        {
            return resourceType
        }
        let fileExtension = url.pathExtension
        guard !fileExtension.isEmpty else { return nil }
        return UTType(filenameExtension: fileExtension)
    }

    static func isMediaFile(_ url: URL) -> Bool {
        route(for: url).kind == .media
    }

    static func isAudioFile(_ url: URL) -> Bool {
        let lexicalURL = url.standardizedFileURL
        let type = contentType(for: lexicalURL)
        if type?.conforms(to: .audio) == true {
            return true
        }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            return false
        }
        return ["mp3", "m4a", "wav", "aac", "aiff", "caf"].contains(
            lexicalURL.pathExtension.lowercased()
        )
    }
}
