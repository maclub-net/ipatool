import SwiftUI
#if SWIFT_PACKAGE
import IPAToolKit
#endif

struct ContentView: View {
    @StateObject private var service: AppStoreService
    @State private var selectedSection: AppSection? = .search
    @State private var isAddAccountSheetPresented = false
    @State private var isLoginSheetPresented = false

    init() {
        let service = AppStoreService()
        service.onDirectorySelectionNeeded = { [weak service] in
            service?.selectDownloadDirectory()
        }
        _service = StateObject(wrappedValue: service)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                service: service,
                selection: $selectedSection,
                isAddAccountSheetPresented: $isAddAccountSheetPresented
            )
            .accentColor(.appAccent)
            .navigationSplitViewColumnWidth(min: 248, ideal: 280)
        } detail: {
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [Color.appAccent.opacity(0.06), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        selectedPage
                    }
                    .frame(maxWidth: 1180, alignment: .topLeading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .navigationTitle(selectedSection?.title ?? "IPATool")
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarActions
            }
        }
        .sheet(isPresented: $isAddAccountSheetPresented) {
            LoginSheetView(service: service, isPresented: $isAddAccountSheetPresented)
                .accentColor(.appAccent)
                .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 450)
        }
        .sheet(isPresented: $isLoginSheetPresented) {
            LoginSheetView(service: service, isPresented: $isLoginSheetPresented)
                .accentColor(.appAccent)
                .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 450)
        }
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selectedSection ?? .search {
        case .search:
            SearchView(service: service)
        case .downloads:
            DownloadHistoryView(service: service)
        case .purchases:
            PurchasedAppsView(service: service)
        case .accounts:
            AccountListView(service: service, isLoginSheetPresented: $isLoginSheetPresented)
        case .logs:
            LogView(service: service)
        case .cliMcp:
            CLIMCPGuideView()
        case .crackedIpa:
            EmptyView()
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        switch selectedSection ?? .search {
        case .search:
            EmptyView()
        case .downloads:
            Button {
                service.downloadQueue.removeAll()
                service.log("清空下载队列")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                    Text("清空队列")
                }
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .disabled(service.downloadQueue.isEmpty)
        case .accounts:
            Button {
                isLoginSheetPresented = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("添加账号")
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
        case .purchases:
            EmptyView()
        case .cliMcp:
            EmptyView()
        case .logs:
            Button {
                service.logMessages.removeAll()
                service.log("日志已清空")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                    Text("清空日志")
                }
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .disabled(service.logMessages.isEmpty)
        case .crackedIpa:
            EmptyView()
        }
    }
}