// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WeClawSend",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "WeClawSend", targets: ["WeClawSend"])
    ],
    targets: [
        .systemLibrary(name: "CCommonCrypto"),
        .executableTarget(
            name: "WeClawSend",
            dependencies: ["CCommonCrypto"]
        )
    ]
)
