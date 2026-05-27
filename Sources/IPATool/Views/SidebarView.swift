import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var service: AppStoreService
    @Binding var selection: AppSection?
    @Binding var isAddAccountSheetPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sidebarHeader

            VStack(alignment: .leading, spacing: 6) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        if section.isExternalLink {
                            if let url = URL(string: "https://www.maclub.net") {
                                NSWorkspace.shared.open(url)
                            }
                        } else {
                            selection = section
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selection == section ? Color.appAccent.opacity(0.16) : Color.secondary.opacity(0.08))
                                Image(systemName: section.systemImage)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(selection == section ? Color.appAccent : .secondary)
                            }
                            .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(section.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)

                            if section.isExternalLink {
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(selection == section && !section.isExternalLink ? Color.appAccent.opacity(0.10) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(selection == section && !section.isExternalLink ? Color.appAccent.opacity(0.18) : Color.clear, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }.padding(.top, 12)

            Spacer(minLength: 0)

            if let acc = service.selectedAccount {
                currentAccountCard(acc)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image("SidebarLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    Text("IPATool")
                        .font(.system(size: 24, weight: .bold))
                    Text("App Store IPA 下载工具")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    @ViewBuilder
    private func currentAccountCard(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("当前账号", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                Spacer()
                SectionBadge(text: account.regionDisplayName, tint: .appAccent)
            }

            Text(account.email)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}