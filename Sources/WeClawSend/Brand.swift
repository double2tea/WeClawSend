import AppKit
import SwiftUI

/// 高级简约：墨色标识 + 中性灰表面，强调色克制使用。
enum Brand {
    static let name = "WeClaw Send"
    static let shortName = "WeClaw"
    static let bundleID = "com.chacha.WeClawSend"
    static let githubURL = URL(string: "https://github.com/double2tea/WeClawSend")!
    static let portfolioURL = URL(string: "https://zeezhi.pages.dev/")!
    static let supportEmailURL = URL(string: "mailto:double_tea@foxmail.com")!
    static let feedbackURL = URL(string: "https://my.feishu.cn/docx/ZBq3dUnj1o55Q3xfJrpc9hfRnlh")!
    static let pythonDownloadURL = URL(string: "https://www.python.org/downloads/macos/")!

    /// 主强调：深墨，随深浅色微调
    static let accent = adaptiveColor(
        light: NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1),
        dark: NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
    )
    /// 按钮填充（浅色模式用墨色，保证对比）
    static let action = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    /// 系统控件强调色：跟随用户外观与辅助功能设置。
    static let controlAccent = Color(nsColor: .controlAccentColor)

    /// Logo：纯墨底 + 白飞机
    static let logoTop = Color(red: 42 / 255, green: 42 / 255, blue: 46 / 255)
    static let logoMid = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let logoBottom = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)
    static let logoInk = Color.white

    static let surface = Color.primary.opacity(0.035)
    static let surfaceElevated = Color.primary.opacity(0.05)
    static let hairline = Color.primary.opacity(0.08)

    static let success = Color(red: 46 / 255, green: 125 / 255, blue: 86 / 255)
    static let danger = Color(red: 180 / 255, green: 56 / 255, blue: 50 / 255)
    static let warning = Color(red: 170 / 255, green: 120 / 255, blue: 40 / 255)

    static let fileInk = Color.secondary
    static let fileVideo = Color.secondary
    static let fileAudio = Color.secondary
    static let fileDoc = Color.secondary

    static let panelWidth: CGFloat = 400
    static let panelHeight: CGFloat = 520
    static let radiusCard: CGFloat = 12
    static let radiusControl: CGFloat = 10
    static let radiusChip: CGFloat = 100

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        )
    }

    static var menuBarImage: NSImage {
        if let image = Bundle.main.image(forResource: "MenuBarIcon") {
            let copy = image.copy() as? NSImage ?? image
            copy.isTemplate = true
            copy.size = NSSize(width: 18, height: 18)
            return copy
        }
        let fallback = NSImage(
            systemSymbolName: "paperplane.fill",
            accessibilityDescription: Brand.name
        ) ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    static let githubMarkImage: NSImage = {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M10.226 17.284c-2.965-.36-5.054-2.493-5.054-5.256 0-1.123.404-2.336 1.078-3.144-.292-.741-.247-2.314.09-2.965.898-.112 2.111.36 2.83 1.01.853-.269 1.752-.404 2.853-.404 1.1 0 1.999.135 2.807.382.696-.629 1.932-1.1 2.83-.988.315.606.36 2.179.067 2.942.72.854 1.101 2 1.101 3.167 0 2.763-2.089 4.852-5.098 5.234.763.494 1.28 1.572 1.28 2.807v2.336c0 .674.561 1.056 1.235.786 4.066-1.55 7.255-5.615 7.255-10.646C23.5 6.188 18.334 1 11.978 1 5.62 1 .5 6.188.5 12.545c0 4.986 3.167 9.12 7.435 10.669.606.225 1.19-.18 1.19-.786V20.63a2.9 2.9 0 0 1-1.078.224c-1.483 0-2.359-.808-2.987-2.313-.247-.607-.517-.966-1.034-1.033-.27-.023-.359-.135-.359-.27 0-.27.45-.471.898-.471.652 0 1.213.404 1.797 1.235.45.651.921.943 1.483.943.561 0 .92-.202 1.437-.719.382-.381.674-.718.944-.943"/></svg>"#
        guard let image = NSImage(data: Data(svg.utf8)) else {
            preconditionFailure("无法加载 GitHub 图标")
        }
        image.isTemplate = true
        return image
    }()
}

/// 顶栏小标识：仅此一处使用实心品牌标。
struct BrandMark: View {
    var size: CGFloat = 32
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Brand.logoTop, Brand.logoBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            BrandPlaneGlyph(size: size * 0.58)
                .foregroundStyle(Brand.logoInk)
                .offset(x: size * 0.015, y: size * 0.01)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Brand.name)
    }
}

struct BrandPlaneGlyph: View {
    var size: CGFloat = 18

    var body: some View {
        BrandPlaneShape()
            .fill(style: FillStyle(eoFill: false, antialiased: true))
            .frame(width: size, height: size)
    }
}

private struct BrandPlaneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let s = min(rect.width, rect.height)
        let ang = -14.0 * Double.pi / 180
        let cosA = CGFloat(Darwin.cos(ang))
        let sinA = CGFloat(Darwin.sin(ang))

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let xr = x * cosA - y * sinA
            let yr = x * sinA + y * cosA
            return CGPoint(x: cx + xr * s, y: cy + yr * s)
        }

        var path = Path()
        path.move(to: p(-0.50, 0.14))
        path.addLine(to: p(-0.22, 0.02))
        path.addLine(to: p(0.46, -0.30))
        path.addLine(to: p(0.10, 0.06))
        path.addLine(to: p(0.18, 0.44))
        path.addLine(to: p(-0.02, 0.12))
        path.addLine(to: p(-0.28, 0.20))
        path.closeSubpath()
        return path
    }
}

struct StatusChip: View {
    enum Kind {
        case ready, offline, busy, checking

        var color: Color {
            switch self {
            case .ready: Brand.success
            case .offline: Brand.danger
            case .busy: Brand.accent
            case .checking: Color.secondary
            }
        }
    }

    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(kind.color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

struct SectionCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Brand.radiusCard, style: .continuous)
                .fill(Brand.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Brand.radiusCard, style: .continuous)
                .stroke(Brand.hairline, lineWidth: 1)
        }
    }
}
