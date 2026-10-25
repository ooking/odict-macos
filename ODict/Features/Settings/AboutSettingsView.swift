import AppKit
import SwiftUI

/// Public-facing copy lives here so the developer profile can be updated together.
/// No personal information is inferred from the machine, signing identity or Git.
enum AppAboutInformation {
    static let summary = "一款轻量的原生 macOS 词典，让查词与翻译随手可用。"
    static let developerName = "oKing"
    static let email = "chenwenj@gmail.com"
    static let contact = URL(string: "mailto:\(email)")
    static let repository = URL(string: "https://github.com/ooking/odict-macos")
    static let feedback = URL(string: "https://github.com/ooking/odict-macos/issues")

    static let versionLabel: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (Build \(build))"
    }()
}

struct AboutSettingsView: View {
    @State private var notice: AboutNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("ODict").font(.system(size: 26, weight: .semibold))
                    Text(AppAboutInformation.versionLabel)
                        .font(AppTypography.caption).foregroundColor(.secondary)
                    Text(AppAboutInformation.summary)
                        .font(AppTypography.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            group {
                Text("开发者").font(AppTypography.section)
                Text(AppAboutInformation.developerName).font(AppTypography.body)
                linkRow("联系开发者", destination: AppAboutInformation.contact, label: AppAboutInformation.email)
            }
            group {
                Text("开源与致谢").font(AppTypography.section)
                Text("采用 MIT 许可证，允许使用、修改和分发；再分发时请保留版权与许可声明。")
                    .font(AppTypography.secondary).fixedSize(horizontal: false, vertical: true)
                linkRow("项目源码", destination: AppAboutInformation.repository)
                linkRow("问题反馈", destination: AppAboutInformation.feedback)
                Divider()
                HStack(spacing: 16) {
                    Button("MIT 许可证") { notice = AboutNotice.load(.license) }
                    Button("第三方致谢") { notice = AboutNotice.load(.thirdParty) }
                }
                .controlSize(.small)
                Text("Copyright © 2026 ODict contributors")
                    .font(AppTypography.caption).foregroundColor(.secondary)
            }
        }
        .sheet(item: $notice) { AboutNoticeView(notice: $0) }
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func linkRow(_ title: String, destination: URL?, label: String = "打开") -> some View {
        HStack {
            Text(title)
            Spacer()
            if let destination {
                Link(destination: destination) {
                    Label(label, systemImage: "arrow.up.right")
                }
                .accessibilityLabel("打开\(title)")
            } else {
                Text("待补充").foregroundColor(.secondary)
            }
        }
        .font(AppTypography.secondary)
    }
}

/// Bundled notices are loaded only on demand and released with the sheet.
private struct AboutNotice: Identifiable {
    enum Kind: String {
        case license, thirdParty
        var title: String { self == .license ? "MIT 许可证" : "第三方致谢" }
        var resource: String { self == .license ? "LICENSE" : "THIRD_PARTY_NOTICES" }
        var fileExtension: String? { self == .license ? nil : "md" }
    }
    let id: Kind
    let text: String

    static func load(_ kind: Kind) -> Self {
        let limit = 64 * 1024
        guard let url = Bundle.main.url(forResource: kind.resource, withExtension: kind.fileExtension),
              let file = try? FileHandle(forReadingFrom: url) else {
            return Self(id: kind, text: "暂时无法读取许可文件，请查看项目源码中的对应声明。")
        }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: limit + 1), data.count <= limit,
              let text = String(data: data, encoding: .utf8) else {
            return Self(id: kind, text: "许可文件无法显示，请查看项目源码中的对应声明。")
        }
        return Self(id: kind, text: text)
    }
}

private struct AboutNoticeView: View {
    let notice: AboutNotice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(notice.id.title).font(AppTypography.section)
            ScrollView {
                Text(notice.text).font(AppTypography.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520, height: 420)
    }
}
