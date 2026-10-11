# IPATool

[![GPLv3 License](https://img.shields.io/badge/license-GPLv3-orange.svg)](https://www.gnu.org/licenses/gpl-3.0.html)
![macOS](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.9-orange)

**Languages:** [English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

IPATool is a native macOS desktop app for searching apps on the App Store, obtaining licenses, and downloading IPA packages locally. It supports multi-region Apple ID management, two-factor authentication, purchased app browsing, historical version downloads, and package downloads for iOS / iPadOS / tvOS / visionOS / macOS.

## Download

- [App Store](https://apps.apple.com/cn/app/ipatool/id6774012874)
- [GitHub Releases](https://github.com/maclub-net/ipatool/releases)

## Website

https://www.ipatool.cn

## Features

- **App Search**: Search the App Store by keyword, with platform filters for iPhone, iPad, Apple TV, visionOS, and macOS. Search runs automatically after you stop typing.
- **Multi-Account Management**: Add multiple Apple IDs from different regions and switch between them with one click. Account credentials are encrypted and stored in the macOS Keychain.
- **Two-Factor Authentication**: When 2FA is required, a dedicated 6-digit code input screen appears; submission is automatic once all digits are entered.
- **Automatic Token Renewal**: Your password is stored encrypted alongside the account. When credentials expire, the app automatically re-logs in to refresh the token. If 2FA is triggered, the account is marked as requiring re-login.
- **Purchased Apps**: Browse the purchased app list of the current account, filter by platform, and tap an app to view its details.
- **App Details**: View app icon, developer, price, description, screenshots, and a list of downloadable historical versions.
- **Download Manager**: Asynchronous download queue with real-time progress. Pause, cancel, remove, or reveal in Finder.
- **macOS Package Decryption**: macOS apps are automatically decrypted via the StoreAgent engine after download, producing an installable `.ipa` package.
- **File Naming**: Downloaded files follow the `AppName_Version(VersionID fallback)_Account.ipa` convention.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15 or later (for building from source)

## Building from Source

```bash
git clone https://github.com/maclub-net/ipatool.git
cd ipatool
xcodebuild -project IPATool.xcodeproj -scheme IPATool -configuration Release build
```

The built app is located at `DerivedData/IPATool/Build/Products/Release/IPATool.app`.

## Project Structure

```
Sources/
├── CSAP/          # C-layer SAP/StoreAgent engine (signing, macOS package decryption)
├── IPAToolCore/   # Core logic: App Store API client, SAP signer
├── IPAToolGUI/    # SwiftUI interface and app state management
└── IPAToolCLI/    # Command-line entry point
```

## Community

- [QQ Group](https://qm.qq.com/q/VPxUSjKUma)
- [QQ Channel](https://pd.qq.com/s/foo260n5q)
- [GitHub Issues](https://github.com/maclub-net/ipatool/issues)

## Credits

The protocol and decryption logic are based on [ipatool](https://github.com/majd/ipatool).

## License

[GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html)
