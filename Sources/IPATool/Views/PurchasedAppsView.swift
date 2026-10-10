import SwiftUI
#if SWIFT_PACKAGE
import IPAToolKit
#endif

/// S7: 已购应用浏览页面
struct PurchasedAppsView: View {
    @ObservedObject var service: AppStoreService
    @State private var isLoading = false
    @State private var searchFilter = ""
    @State private var selectedPlatform: Platform? = nil
    @State private var selectedApp: PurchasedApp? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionCard(title: "已购应用", subtitle: "浏览当前账号已购买的应用") {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        AppTextField("搜索已购应用...", text: $searchFilter)

                        platformSelector

                        Button {
                            Task { await loadPurchases() }
                        } label: {
                            HStack(spacing: 6) {
                                if isLoading {
                                    ProgressView().scaleEffect(0.7)
                                }
                                Text("刷新")
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(isLoading || service.selectedAccount == nil)
                    }
                }
            }

            if !service.purchases.isEmpty {
                SectionCard(
                    title: "购买记录",
                    subtitle: "共 \(service.purchases.count) 个应用"
                ) {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredPurchases) { app in
                            PurchasedAppCard(app: app, service: service, onTap: { selectedApp = app })
                        }
                    }
                }
            } else if !isLoading {
                SectionCard(title: "暂无数据", subtitle: "点击刷新获取已购应用列表") {
                    Text(service.selectedAccount == nil ? "请先登录账号" : "点击右上角刷新按钮获取已购列表")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(item: $selectedApp) { app in
            PurchasedAppDetailView(service: service, app: app)
                .accentColor(.appAccent)
                .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 400)
        }
    }

    private var filteredPurchases: [PurchasedApp] {
        let byPlatform = selectedPlatform.map { p in
            service.purchases.filter { $0.platforms.contains(p) }
        } ?? service.purchases

        if searchFilter.isEmpty { return byPlatform }
        return byPlatform.filter {
            $0.name.lowercased().contains(searchFilter.lowercased()) ||
            $0.bundleID.lowercased().contains(searchFilter.lowercased())
        }
    }

    private var platformSelector: some View {
        Menu {
            Button("全部平台") { selectedPlatform = nil }
            ForEach(Platform.allCases, id: \.self) { p in
                Button(p.displayName) { selectedPlatform = p }
            }
        } label: {
            HStack {
                Image(systemName: selectedPlatform?.systemImage ?? "square.grid.2x2")
                    .font(.caption)
                Text(selectedPlatform?.displayName ?? "全部平台")
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func loadPurchases() async {
        isLoading = true
        do {
            _ = try await service.listPurchases(limit: 100, platform: selectedPlatform)
        } catch {
            service.log("获取已购应用失败: \(error.localizedDescription)", type: .error)
        }
        isLoading = false
    }
}

// MARK: - 已购应用卡片

fileprivate struct PurchasedAppCard: View {
    let app: PurchasedApp
    let service: AppStoreService
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 48, height: 48)
                Image(systemName: "app.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(app.bundleID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    SectionBadge(text: "v\(app.version)", tint: .appAccent)
                    ForEach(app.platforms, id: \.self) { p in
                        SectionBadge(text: p.displayName, tint: .blue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                service.enqueueDownload(app: app.asAppInfo)
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("加入下载队列")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.05), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { onTap() }
    }
}

// MARK: - 已购应用详情

struct PurchasedAppDetailView: View {
    @ObservedObject var service: AppStoreService
    let app: PurchasedApp
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(width: 56, height: 56)
                    Image(systemName: "app.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 18, weight: .bold))
                    Text(app.bundleID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        SectionBadge(text: "v\(app.version)", tint: .appAccent)
                        ForEach(app.platforms, id: \.self) { p in
                            SectionBadge(text: p.displayName, tint: .blue)
                        }
                    }
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Divider().padding(.top, 16)

            VStack(alignment: .leading, spacing: 12) {
                InfoRow(label: "App ID", value: "\(app.appID)")
                InfoRow(label: "Bundle ID", value: app.bundleID)
                InfoRow(label: "版本", value: app.version)
                InfoRow(label: "平台", value: app.platforms.map(\.displayName).joined(separator: ", "))
                if let date = app.purchaseDate {
                    InfoRow(label: "购买日期", value: date.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            Divider()
            HStack {
                Spacer()
                Button {
                    service.enqueueDownload(app: app.asAppInfo)
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line")
                        Text("加入下载队列")
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }
}
