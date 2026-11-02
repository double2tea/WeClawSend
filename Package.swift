// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WeClawSend",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "WeClawSend", targets: ["WeClawSend"]),
        .executable(name: "weclaw", targets: ["WeClawCLI"])
    ],
    targets: [
        .systemLibrary(name: "CCommonCrypto"),
        .executableTarget(name: "WeClawCLI"),
        .executableTarget(
            name: "WeClawSend",
            dependencies: ["CCommonCrypto"]
        )
    ]
)
