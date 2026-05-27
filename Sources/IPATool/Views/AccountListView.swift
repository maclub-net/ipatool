import SwiftUI

struct AccountListView: View {
    @ObservedObject var service: AppStoreService
    @Binding var isLoginSheetPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionCard(title: "添加新账号", subtitle: "支持多地区 Apple ID，每个地区一个账号") {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        isLoginSheetPresented = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("添加 Apple ID")
                        }
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                }
            }

            SectionCard(title: "已配置账号", subtitle: "管理各地区 Apple ID，选择当前使用的账号。共 \(service.accounts.count) 个账号。") {
                if service.accounts.isEmpty {
                    ContentUnavailableView("暂无账号", systemImage: "person.2", description: Text("请先添加 Apple ID"))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 120)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(service.accounts) { account in
                            AccountRowCard(
                                account: account,
                                isSelected: account.id == service.selectedAccount?.id,
                                onSelect: { service.selectedAccount = account },
                                onDelete: {
                                    do {
                                        try service.deleteAccount(account)
                                    } catch {
                                        service.log("删除失败: \(error.localizedDescription)", type: .error)
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Account Row Card

struct AccountRowCard: View {
    let account: Account
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.appAccent.opacity(0.12) : Color.secondary.opacity(0.08))
                Image(systemName: "person.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.appAccent : .secondary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(account.name)
                        .font(.system(size: 14, weight: .semibold))
                    SectionBadge(text: account.regionDisplayName, tint: .purple)
                }
                Text(account.email)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                InfoRow(label: "StoreFront", value: account.storeFront)
            }

            Spacer(minLength: 8)

            VStack(spacing: 8) {
                if isSelected {
                    SectionBadge(text: "当前使用", tint: .green)
                } else {
                    Button("使用") { onSelect() }
                        .buttonStyle(SecondaryActionButtonStyle())
                }

                Button(role: .destructive) { onDelete() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "trash")
                        Text("删除")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.7))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.appAccent.opacity(0.25) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}