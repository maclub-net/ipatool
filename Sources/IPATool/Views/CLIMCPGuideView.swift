import SwiftUI
import AppKit

/// CLI 与 MCP Server 使用说明页面
struct CLIMCPGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // CLI 说明
            SectionCard(title: "命令行工具（CLI）", subtitle: "通过终端使用 ipatool 命令行工具，支持自动化操作") {
                VStack(alignment: .leading, spacing: 16) {
                    infoBanner(
                        icon: "info.circle.fill",
                        text: "CLI 与 GUI 共享同一份账号数据和核心功能，但运行在独立进程中，互不干扰。",
                        tint: .appAccent
                    )

                    commandBlock(title: "安装", command: "cd ~/code/maclub-net/ipatool && swift build -c release\ncp .build/release/ipatool-cli ~/.local/bin/ipatool")

                    commandList(title: "可用命令", commands: [
                        ("ipatool auth login", "登录 Apple ID（交互式，支持 2FA）"),
                        ("ipatool auth login --email user@example.com --password ******", "非交互式登录（CI/脚本用）"),
                        ("ipatool auth logout", "退出登录并删除凭据"),
                        ("ipatool auth info", "查看已登录账号"),
                        ("ipatool search 微信", "搜索应用"),
                        ("ipatool search 微信 --platform ios --limit 10", "按平台搜索"),
                        ("ipatool download -b com.tencent.xin", "下载 IPA（自动获取许可）"),
                        ("ipatool download -b com.tencent.xin --external-version-id 12345", "下载指定历史版本"),
                        ("ipatool download -b com.tencent.xin --platform macos -o ~/Downloads", "下载 macOS 版本到指定目录"),
                        ("ipatool purchase -b com.tencent.xin", "仅获取许可证，不下载"),
                        ("ipatool list-versions -b com.tencent.xin", "列出所有历史版本"),
                        ("ipatool get-version-metadata -b com.tencent.xin --external-version-id 12345", "获取指定版本元数据"),
                        ("ipatool list-purchases", "浏览已购应用"),
                        ("ipatool list-purchases --platform macos --limit 20", "按平台筛选已购应用"),
                    ])

                    commandList(title: "输出格式", commands: [
                        ("ipatool search 微信 --format json", "JSON 格式输出（脚本用）"),
                        ("ipatool search 微信 --format table", "表格格式输出（默认，人类可读）"),
                    ])

                    commandList(title: "多账号支持", commands: [
                        ("ipatool auth login --account work@example.com", "指定账号登录"),
                        ("ipatool search 微信 --account personal@example.com", "指定账号搜索"),
                        ("ipatool download -b com.tencent.xin --account work@example.com", "指定账号下载"),
                    ])
                }
            }

            // MCP 说明
            SectionCard(title: "MCP Server", subtitle: "将 ipatool 暴露为 MCP 工具，供 AI Agent（Claude/Cursor 等）调用") {
                VStack(alignment: .leading, spacing: 16) {
                    infoBanner(
                        icon: "sparkles",
                        text: "MCP Server 通过 stdio JSON-RPC 协议工作，零额外依赖。启动后可注册到任何 MCP 兼容客户端。",
                        tint: .purple
                    )

                    commandBlock(title: "启动 MCP Server", command: "ipatool mcp serve")

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Claude Desktop 配置")
                            .font(.system(size: 14, weight: .semibold))
                        Text("编辑 ~/Library/Application Support/Claude/claude_desktop_config.json：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        codeBlock("""
{
  "mcpServers": {
    "ipatool": {
      "command": "/Users/yourname/.local/bin/ipatool",
      "args": ["mcp", "serve"]
    }
  }
}
""")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Cursor 配置")
                            .font(.system(size: 14, weight: .semibold))
                        Text("在 Cursor Settings → MCP 中添加：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        codeBlock("""
{
  "mcpServers": {
    "ipatool": {
      "command": "/Users/yourname/.local/bin/ipatool",
      "args": ["mcp", "serve"]
    }
  }
}
""")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("可用 MCP 工具")
                            .font(.system(size: 14, weight: .semibold))
                        toolList
                    }
                }
            }

            // 架构说明
            SectionCard(title: "进程隔离", subtitle: "CLI/MCP 与 GUI 完全独立运行") {
                VStack(alignment: .leading, spacing: 12) {
                    architectureRow(icon: "apps.iphone", title: "GUI 应用", desc: "图形界面，管理下载队列、多账号切换、日志查看")
                    architectureRow(icon: "terminal", title: "CLI 工具", desc: "命令行，支持脚本自动化、JSON 输出、CI 集成")
                    architectureRow(icon: "server.rack", title: "MCP Server", desc: "stdio JSON-RPC，供 AI Agent 调用，支持进度通知")
                    Divider().padding(.vertical, 4)
                    architectureRow(icon: "key.fill", title: "共享 Keychain", desc: "三个进程读写同一份账号凭据，GUI 登录后 CLI 立即可用")
                    architectureRow(icon: "externaldrive.badge.checkmark", title: "独立日志", desc: "GUI 写日志文件，CLI/MCP 走 stdout/stderr，互不干扰")
                }
            }
        }
    }

    // MARK: - Components

    private func infoBanner(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.85))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.08)))
    }

    private func commandBlock(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            codeBlock(command)
        }
    }

    private func codeBlock(_ code: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("复制")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func commandList(title: String, commands: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            ForEach(commands, id: \.0) { cmd, desc in
                VStack(alignment: .leading, spacing: 3) {
                    codeBlock(cmd)
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var toolList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([
                ("search", "搜索应用（支持平台过滤）"),
                ("download", "下载 IPA（支持版本指定、平台选择，实时进度通知）"),
                ("purchase", "获取应用许可证"),
                ("list-versions", "列出应用的所有历史版本"),
                ("get-version-metadata", "获取指定版本的元数据"),
                ("list-purchases", "浏览已购应用列表"),
            ], id: \.0) { name, desc in
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 180, alignment: .leading)
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func architectureRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.appAccent.opacity(0.1))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
