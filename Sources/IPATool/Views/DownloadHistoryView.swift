import SwiftUI

struct DownloadHistoryView: View {
    @ObservedObject var service: AppStoreService

    private var activeCount: Int {
        service.downloadQueue.filter { $0.status == .waiting || $0.status == .purchasing || $0.status == .downloading || $0.status == .processing || $0.status == .failed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 下载目录设置
            SectionCard(title: "下载目录", subtitle: "IPA 文件将保存在此目录") {
                HStack(spacing: 10) {
                    Text(service.downloadDirectory.path)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )

                    Button("选择目录") {
                        selectDownloadDirectory()
                    }
                    .buttonStyle(SecondaryActionButtonStyle())

                    Button("重置") {
                        service.downloadDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("IPATool/downloads")
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }
            }
            
            // 下载队列
            SectionCard(
                title: "下载队列",
                subtitle: "待处理的下载任务。进行中 \(activeCount) 项。"
            ) {
                if service.downloadQueue.isEmpty {
                    ContentUnavailableView("暂无下载任务", systemImage: "tray", description: Text("在搜索结果页点击「加入下载队列」即可添加下载任务"))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 120)
                } else {
                    VStack(spacing: 2) {
                        ForEach(service.downloadQueue) { item in
                            QueueItemRow(service: service, item: item)
                        }
                    }
                }
            }

            // 已完成下载记录
            SectionCard(
                title: "已完成下载",
                subtitle: "已成功下载的 IPA 文件。共 \(service.downloadResults.count) 个。"
            ) {
                if service.downloadResults.isEmpty {
                    ContentUnavailableView("暂无下载记录", systemImage: "arrow.down.doc", description: Text("下载完成的应用将显示在这里"))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 120)
                } else {
                    VStack(spacing: 2) {
                        ForEach(service.downloadResults.reversed()) { result in
                            CompletedRow(service: service, result: result)
                        }
                    }
                }
            }
        }
    }

    private func selectDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "选择下载目录"
        panel.message = "选择 IPA 文件的保存位置"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            service.downloadDirectory = url
            service.log("下载目录已切换: \(url.path)", type: .info)
        }
    }
}

// MARK: - 队列任务行

private struct QueueItemRow: View {
    @ObservedObject var service: AppStoreService
    let item: DownloadQueueItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // 状态图标
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 34, height: 34)

                    if item.status == .downloading || item.status == .processing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(statusColor)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: 14))
                            .foregroundStyle(statusColor)
                    }
                }

                // 应用信息
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.app.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        SectionBadge(text: item.statusText, tint: statusColor)
                    }

                    HStack(spacing: 8) {
                        Text(item.account.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(item.account.regionDisplayName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if item.status == .downloading || item.status == .processing {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(height: 4)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.appAccent)
                                    .frame(width: geo.size.width * item.progress, height: 4)
                            }
                        }
                        .frame(height: 4)
                        .padding(.top, 2)
                    }

                    if let error = item.error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 操作按钮
                HStack(spacing: 4) {
                    if item.status == .waiting || item.status == .purchasing || item.status == .downloading || item.status == .processing {
                        Button {
                            service.cancelDownload(item)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("取消任务")
                    }

                    if item.status == .failed {
                        Button {
                            service.retryDownload(item)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("重试")

                        Button {
                            service.cancelDownload(item)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("取消任务")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var statusIcon: String {
        switch item.status {
        case .waiting: "clock"
        case .purchasing: "key"
        case .downloading: "arrow.down"
        case .processing: "gearshape"
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle"
        case .cancelled: "nosign"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .waiting: .secondary
        case .purchasing: .orange
        case .downloading, .processing: .accentColor
        case .completed: .green
        case .failed: .red
        case .cancelled: .gray
        }
    }
}

// MARK: - 已完成下载行

private struct CompletedRow: View {
    @ObservedObject var service: AppStoreService
    let result: DownloadResult

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            }

            // 信息
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(result.app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text("v\(result.version)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(result.regionDisplayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(result.destinationPath.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 时间和操作
            HStack(spacing: 8) {
                Text(result.completedAt, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(result.completedAt, style: .time)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([result.destinationPath])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")

                Button {
                    service.removeDownloadResult(result)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("删除文件")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}