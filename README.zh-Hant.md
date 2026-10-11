# IPATool

[![License](https://img.shields.io/badge/license-Commercial-orange.svg)](LICENSE)
![macOS](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.9-orange)

**語言：** [English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

IPATool 是一款原生 macOS 桌面應用，用於搜尋 App Store 中的應用、取得授權並下載 IPA 安裝包到本機。支援多地區 Apple ID 管理、雙重認證、已購應用瀏覽、歷史版本下載，以及 iOS / iPadOS / tvOS / visionOS / macOS 全平台包下載。

## 下載

- [App Store](https://apps.apple.com/cn/app/ipatool/id6774012874)
- [GitHub Releases](https://github.com/maclub-net/ipatool/releases)

## 官網

https://www.ipatool.cn

## 功能特色

- **應用搜尋**：依關鍵字搜尋 App Store，支援 iPhone、iPad、Apple TV、visionOS、macOS 平台篩選，輸入後自動搜尋。
- **多帳號管理**：支援新增多個不同地區的 Apple ID，一鍵切換；帳號憑證加密儲存於 macOS Keychain。
- **雙重認證**：登入時若帳號開啟 2FA，彈出獨立的 6 位驗證碼輸入介面，輸入完成自動提交。
- **Token 自動續期**：密碼隨帳號加密儲存，當登入憑證失效時自動用密碼重新登入更新 token；若觸發 2FA 則標記帳號需重新登入。
- **已購應用**：瀏覽目前帳號的已購應用列表，支援平台篩選，點擊查看應用詳情。
- **應用詳情**：展示應用圖示、開發者、價格、簡介、截圖，以及可下載的歷史版本清單。
- **下載管理**：非同步下載佇列，即時進度，支援暫停/取消/移除/在 Finder 中開啟。
- **macOS 包解密**：macOS 應用下載後透過 StoreAgent 引擎自動解密，輸出可直接安裝的 `.ipa` 包。
- **檔案命名**：下載檔案依 `應用名_版本號(版本序號兜底)_下載帳號.ipa` 規則命名。

## 系統需求

- macOS 14.0 (Sonoma) 以上
- Xcode 15 以上（自行建置時）

## 自行建置

```bash
git clone https://github.com/maclub-net/ipatool.git
cd ipatool
xcodebuild -project IPATool.xcodeproj -scheme IPATool -configuration Release build
```

建置產物位於 `DerivedData/IPATool/Build/Products/Release/IPATool.app`。

## 專案結構

```
Sources/
├── CSAP/          # C 層 SAP/StoreAgent 引擎（簽章、macOS 包解密）
├── IPAToolCore/   # 核心邏輯：App Store API 客戶端、SAP 簽章器
├── IPAToolGUI/    # SwiftUI 介面與應用狀態管理
└── IPAToolCLI/    # 命令列入口
```

## 社群

- [QQ 群](https://qm.qq.com/q/VPxUSjKUma)
- [QQ 頻道](https://pd.qq.com/s/foo260n5q)
- [GitHub Issues](https://github.com/maclub-net/ipatool/issues)

## 致謝

本專案的協定與解密邏輯參考自 [ipatool](https://github.com/majd/ipatool)。

## 授權

本專案採用自訂授權。**個人學習、教育及非商業用途免費授權。** **商業使用必須取得商業授權。**

完整條款見 [LICENSE](LICENSE)。

申請商業授權請造訪 https://www.ipatool.cn 或聯絡 dustink@qq.com。
