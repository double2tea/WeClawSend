import SwiftUI

struct DataSafetyHint: View {
    static let detail = """
    本应用不设服务器，文件和账号都不会经过开发者。
    发送走微信官方通道，到达后的保存与传输由微信负责。
    登录、设置和发送记录只留在本机。
    """

    @Binding var isHovered: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10, weight: .medium))
            Text("数据安全")
                .font(.system(size: 11))
        }
        .foregroundStyle(isHovered ? Color.secondary : Color.primary.opacity(0.38))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("数据安全")
        .accessibilityHint(Self.detail)
    }

    static var card: some View {
        Text(detail)
            .font(.system(size: 11.5))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 248, alignment: .leading)
            .padding(10)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

struct SocialLinksView: View {
    let appVersion: String

    @Environment(\.openURL) private var openURL
    @AppStorage(AppSettings.portfolioSeenVersionKey) private var portfolioSeenVersion = ""

    var body: some View {
        HStack(spacing: 4) {
            Link(destination: Brand.githubURL) {
                Image(nsImage: Brand.githubMarkImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("在 GitHub 查看项目")
            .accessibilityLabel("GitHub")

            Button {
                portfolioSeenVersion = appVersion
                openURL(Brand.portfolioURL)
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "person.crop.square")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                    if portfolioSeenVersion != appVersion {
                        Circle()
                            .fill(Brand.danger)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    }
                }
            }
            .buttonStyle(.plain)
            .help("查看 Zeezhi 作品集")
            .accessibilityLabel(
                portfolioSeenVersion == appVersion
                    ? "Zeezhi 作品集"
                    : "Zeezhi 作品集，有新内容"
            )

            Link(destination: Brand.supportEmailURL) {
                Image(systemName: "envelope")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("发送邮件至 double_tea@foxmail.com")
            .accessibilityLabel("邮件联系")
        }
    }
}
