# IPATool

[![License](https://img.shields.io/badge/license-Commercial-orange.svg)](LICENSE)
![macOS](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.9-orange)

**语言：** [English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

IPATool 是一款原生 macOS 桌面应用，用于搜索 App Store 中的应用、获取许可并下载 IPA 安装包到本地。支持多地区 Apple ID 管理、双重认证、已购应用浏览、历史版本下载，以及 iOS / iPadOS / tvOS / visionOS / macOS 全平台包下载。

## 下载

- [App Store](https://apps.apple.com/cn/app/ipatool/id6774012874)
- [GitHub Releases](https://github.com/maclub-net/ipatool/releases)

## 官网

https://www.ipatool.cn

## 功能特性

- **应用搜索**：按关键词搜索 App Store，支持 iPhone、iPad、Apple TV、visionOS、macOS 平台筛选，输入后自动搜索。
- **多账号管理**：支持添加多个不同地区的 Apple ID，一键切换；账号凭据加密存储于 macOS Keychain。
- **双重认证**：登录时若账号开启 2FA，弹出独立的 6 位验证码输入界面，输入完成自动提交。
- **Token 自动续期**：密码随账号加密保存，当登录凭据失效时自动用密码重新登录刷新 token；若触发 2FA 则标记账号需重新登录。
- **已购应用**：浏览当前账号的已购应用列表，支持平台筛选，点击查看应用详情。
- **应用详情**：展示应用图标、开发者、价格、简介、截图，以及可下载的历史版本列表。
- **下载管理**：异步下载队列，实时进度，支持暂停/取消/移除/在 Finder 中打开。
- **macOS 包解密**：macOS 应用下载后通过 StoreAgent 引擎自动解密，输出可直接安装的 `.ipa` 包。
- **文件命名**：下载文件按 `应用名_版本号(版本序号兜底)_下载账号.ipa` 规则命名。

## 系统要求

- macOS 14.0 (Sonoma) 及以上
- Xcode 15 及以上（自行构建时）

## 自行构建

```bash
git clone https://github.com/maclub-net/ipatool.git
cd ipatool
xcodebuild -project IPATool.xcodeproj -scheme IPATool -configuration Release build
```

构建产物位于 `DerivedData/IPATool/Build/Products/Release/IPATool.app`。

## 项目结构

```
Sources/
├── CSAP/          # C 层 SAP/StoreAgent 引擎（签名、macOS 包解密）
├── IPAToolCore/   # 核心逻辑：App Store API 客户端、SAP 签名器
├── IPAToolGUI/    # SwiftUI 界面与应用状态管理
└── IPAToolCLI/    # 命令行入口
```

## 社区

- [QQ 群](https://qm.qq.com/q/VPxUSjKUma)
- [QQ 频道](https://pd.qq.com/s/foo260n5q)
- [GitHub Issues](https://github.com/maclub-net/ipatool/issues)

## 致谢

本项目的协议与解密逻辑参考自 [ipatool](https://github.com/majd/ipatool)。

## 许可证

本项目采用自定义许可证。**个人学习、教育及非商业用途免费授权。** **商业使用必须取得商业授权。**

完整条款见 [LICENSE](LICENSE)。

申请商业授权请访问 https://www.ipatool.cn 或联系 dustink@qq.com。
