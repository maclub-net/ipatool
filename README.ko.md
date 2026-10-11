# IPATool

[![License](https://img.shields.io/badge/license-Commercial-orange.svg)](LICENSE)
![macOS](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.9-orange)

**언어:** [English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

IPATool은 App Store의 앱을 검색하고 라이선스를 획득하여 IPA 패키지를 로컬로 다운로드하는 네이티브 macOS 데스크톱 앱입니다. 다중 지역 Apple ID 관리, 2단계 인증, 구매한 앱 목록 탐색, 이전 버전 다운로드, iOS / iPadOS / tvOS / visionOS / macOS 전 플랫폼 패키지 다운로드를 지원합니다.

## 다운로드

- [App Store](https://apps.apple.com/cn/app/ipatool/id6774012874)
- [GitHub Releases](https://github.com/maclub-net/ipatool/releases)

## 웹사이트

https://www.ipatool.cn

## 기능

- **앱 검색**: 키워드로 App Store를 검색합니다. iPhone, iPad, Apple TV, visionOS, macOS 플랫폼 필터를 지원하며 입력 후 자동으로 검색됩니다.
- **다중 계정 관리**: 여러 지역의 Apple ID를 추가하고 원클릭으로 전환할 수 있습니다. 계정 정보는 macOS Keychain에 암호화되어 저장됩니다.
- **2단계 인증**: 2FA가 필요한 경우 전용 6자리 코드 입력 화면이 나타나며, 모든 자리를 입력하면 자동으로 제출됩니다.
- **토큰 자동 갱신**: 비밀번호는 계정과 함께 암호화되어 저장되며, 인증 정보가 만료되면 자동으로 다시 로그인하여 토큰을 갱신합니다. 2FA가 필요한 경우 재로그인이 필요한 계정으로 표시됩니다.
- **구매한 앱**: 현재 계정의 구매한 앱 목록을 탐색하고 플랫폼으로 필터링하며, 앱을 클릭하면 세부 정보를 볼 수 있습니다.
- **앱 세부 정보**: 앱 아이콘, 개발자, 가격, 설명, 스크린샷, 다운로드 가능한 이전 버전 목록을 표시합니다.
- **다운로드 관리**: 비동기 다운로드 대기열, 실시간 진행률. 일시 정지, 취소, 제거, Finder에서 열기를 지원합니다.
- **macOS 패키지 복호화**: macOS 앱은 다운로드 후 StoreAgent 엔진으로 자동 복호화되어 설치 가능한 `.ipa` 패키지로 출력됩니다.
- **파일 명명**: 다운로드 파일은 `앱이름_버전(버전ID 대체)_계정.ipa` 규칙으로 명명됩니다.

## 시스템 요구 사항

- macOS 14.0 (Sonoma) 이상
- Xcode 15 이상 (소스에서 빌드할 때)

## 소스에서 빌드

```bash
git clone https://github.com/maclub-net/ipatool.git
cd ipatool
xcodebuild -project IPATool.xcodeproj -scheme IPATool -configuration Release build
```

빌드된 앱은 `DerivedData/IPATool/Build/Products/Release/IPATool.app`에 위치합니다.

## 프로젝트 구조

```
Sources/
├── CSAP/          # C 레이어 SAP/StoreAgent 엔진 (서명, macOS 패키지 복호화)
├── IPAToolCore/   # 핵심 로직: App Store API 클라이언트, SAP 서명기
├── IPAToolGUI/    # SwiftUI 인터페이스 및 앱 상태 관리
└── IPAToolCLI/    # 명령줄 진입점
```

## 커뮤니티

- [QQ 그룹](https://qm.qq.com/q/VPxUSjKUma)
- [QQ 채널](https://pd.qq.com/s/foo260n5q)
- [GitHub Issues](https://github.com/maclub-net/ipatool/issues)

## 크레딧

프로토콜 및 복호화 로직은 [ipatool](https://github.com/majd/ipatool)을 참고했습니다.

## 라이선스

이 프로젝트는 사용자 정의 라이선스 하에 제공됩니다. **개인 학습, 교육 및 비상업적 사용은 무료입니다.** **상업적 사용은 상업 라이선스 취득이 필수입니다.**

전체 조항은 [LICENSE](LICENSE)에서 확인할 수 있습니다.

상업 라이선스 신청은 https://www.ipatool.cn 또는 dustink@qq.com으로 문의하세요.
