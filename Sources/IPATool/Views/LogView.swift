import SwiftUI
#if SWIFT_PACKAGE
import IPAToolKit
#endif

struct LogView: View {
    @ObservedObject var service: AppStoreService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionCard(title: "操作日志", subtitle: "查看最近的操作记录。共 \(service.logMessages.count) 条。") {
                if service.logMessages.isEmpty {
                    ContentUnavailableView("暂无日志", systemImage: "doc.text", description: Text("执行搜索或下载操作后，日志将显示在这里"))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 260)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(service.logMessages) { entry in
                                    LogRowView(entry: entry)
                                }
                            }
                            .padding(4)
                        }
                        .frame(maxHeight: .infinity)
                        .onAppear {
                            if let last = service.logMessages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: service.logMessages.count) { _, _ in
                            if let last = service.logMessages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
}