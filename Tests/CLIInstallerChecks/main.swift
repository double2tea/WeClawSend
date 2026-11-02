import Foundation

@main
struct Checks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("WeClaw Send.app")
        let binary = app.appendingPathComponent("Contents/MacOS/weclaw")
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let link = bin.appendingPathComponent("weclaw")
        precondition(CLIInstaller.install(appURL: app, binDirectory: bin) == .installed)
        let destination = try fm.destinationOfSymbolicLink(atPath: link.path)
        precondition(destination == binary.path)
        precondition(CLIInstaller.install(appURL: app, binDirectory: bin) == .installed)
        try fm.removeItem(at: link)
        try Data("other".utf8).write(to: link)
        precondition(CLIInstaller.install(appURL: app, binDirectory: bin) == .conflict)
        let contents = try Data(contentsOf: link)
        precondition(contents == Data("other".utf8))
        precondition(CLIInstaller.install(appURL: app, binDirectory: bin, replaceExisting: true) == .installed)
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/missing/other")
        precondition(CLIInstaller.install(appURL: app, binDirectory: bin) == .conflict)
        precondition(CLIInstaller.install(appURL: app, binDirectory: bin, replaceExisting: true) == .installed)
        try fm.removeItem(at: link)
        try fm.createDirectory(at: link, withIntermediateDirectories: false)
        precondition(CLIInstaller.install(appURL: app, binDirectory: bin, replaceExisting: true) == .conflict)
        print("CLI installer checks passed")
    }
}
