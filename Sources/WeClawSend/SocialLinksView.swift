import SwiftUI

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
