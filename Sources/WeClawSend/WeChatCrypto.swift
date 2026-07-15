import CCommonCrypto
import CryptoKit
import Foundation
import Security

enum WeChatCryptoError: LocalizedError {
    case random(OSStatus)
    case encryption(CCCryptorStatus)
    case createEncryptedFile

    var errorDescription: String? {
        switch self {
        case let .random(status):
            "无法生成加密密钥（\(status)）"
        case let .encryption(status):
            "文件加密失败（\(status)）"
        case .createEncryptedFile:
            "无法创建加密临时文件"
        }
    }
}

struct EncryptedFileMetadata: Sendable {
    let plaintextSize: Int
    let ciphertextSize: Int
    let plaintextMD5: String
}

enum WeChatCrypto {
    static func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw WeChatCryptoError.random(status)
        }
        return data
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func aes128ECBEncrypt(_ plaintext: Data, key: Data) throws -> Data {
        precondition(key.count == kCCKeySizeAES128)
        let outputCapacity = plaintext.count + kCCBlockSizeAES128
        var ciphertext = Data(count: outputCapacity)
        var encryptedCount = 0
        let status = ciphertext.withUnsafeMutableBytes { output in
            plaintext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        input.baseAddress,
                        plaintext.count,
                        output.baseAddress,
                        outputCapacity,
                        &encryptedCount
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw WeChatCryptoError.encryption(status)
        }
        ciphertext.removeSubrange(encryptedCount..<ciphertext.count)
        return ciphertext
    }

    static func aes128ECBEncryptFile(
        at sourceURL: URL,
        to destinationURL: URL,
        key: Data,
        checkCancellation: () throws -> Void
    ) throws -> EncryptedFileMetadata {
        precondition(key.count == kCCKeySizeAES128)

        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            CCCryptorCreate(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                keyBytes.baseAddress,
                key.count,
                nil,
                &cryptor
            )
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw WeChatCryptoError.encryption(createStatus)
        }
        defer { CCCryptorRelease(cryptor) }

        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw WeChatCryptoError.createEncryptedFile
        }
        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? input.close()
            try? output.close()
        }

        var hasher = Insecure.MD5()
        var plaintextSize = 0
        var ciphertextSize = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try checkCancellation()
            hasher.update(data: chunk)
            plaintextSize += chunk.count

            let encryptedCapacity = chunk.count + kCCBlockSizeAES128
            var encrypted = Data(count: encryptedCapacity)
            var encryptedCount = 0
            let status = encrypted.withUnsafeMutableBytes { outputBytes in
                chunk.withUnsafeBytes { inputBytes in
                    CCCryptorUpdate(
                        cryptor,
                        inputBytes.baseAddress,
                        chunk.count,
                        outputBytes.baseAddress,
                        encryptedCapacity,
                        &encryptedCount
                    )
                }
            }
            guard status == kCCSuccess else {
                throw WeChatCryptoError.encryption(status)
            }
            encrypted.removeSubrange(encryptedCount..<encrypted.count)
            try output.write(contentsOf: encrypted)
            ciphertextSize += encryptedCount
        }

        try checkCancellation()
        let finalCapacity = kCCBlockSizeAES128
        var finalBlock = Data(count: finalCapacity)
        var finalCount = 0
        let finalStatus = finalBlock.withUnsafeMutableBytes { bytes in
            CCCryptorFinal(cryptor, bytes.baseAddress, finalCapacity, &finalCount)
        }
        guard finalStatus == kCCSuccess else {
            throw WeChatCryptoError.encryption(finalStatus)
        }
        finalBlock.removeSubrange(finalCount..<finalBlock.count)
        try output.write(contentsOf: finalBlock)
        ciphertextSize += finalCount

        return EncryptedFileMetadata(
            plaintextSize: plaintextSize,
            ciphertextSize: ciphertextSize,
            plaintextMD5: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}

extension Data {
    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
