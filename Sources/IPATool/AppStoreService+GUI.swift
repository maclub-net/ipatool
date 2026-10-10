import AppKit
#if SWIFT_PACKAGE
import IPAToolKit
#endif

/// GUI 专属扩展：目录选择面板（AppKit NSOpenPanel），不进入 IPAToolKit
extension AppStoreService {
    func selectDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "选择下载目录"
        panel.message = "选择 IPA 文件的保存位置"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            setDownloadDirectory(url)
        }
    }
}
