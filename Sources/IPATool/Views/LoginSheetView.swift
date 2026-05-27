import SwiftUI

struct LoginSheetView: View {
    @ObservedObject var service: AppStoreService
    @Binding var isPresented: Bool

    @State private var email = ""
    @State private var password = ""
    @State private var authCode = ""
    @State private var selectedRegion = "CN"
    @State private var needsAuthCode = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Sheet 标题
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("登录 Apple ID")
                        .font(.system(size: 18, weight: .bold))
                    Text("选择地区并输入 Apple ID 凭据，支持两步验证")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // 地区选择
                    FieldBlock(title: "地区", caption: "") {
                        InputSurface {
                            Menu {
                                ForEach(RegionOption.all) { region in
                                    Button {
                                        selectedRegion = region.code
                                    } label: {
                                        MenuOptionRow(
                                            title: service.accounts.contains(where: { $0.region == region.code })
                                                ? "\(region.displayName) (已配置)"
                                                : region.displayName,
                                            isSelected: selectedRegion == region.code
                                        )
                                    }
                                }
                            } label: {
                                HStack {
                                    if let region = RegionOption.all.first(where: { $0.code == selectedRegion }) {
                                        Text(region.displayName)
                                            .foregroundStyle(.primary)
                                    } else {
                                        Text("选择地区")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(service.isLoggingIn)
                        }
                    }
                    // 邮箱
                    FieldBlock(title: "Apple ID 邮箱", caption: "") {
                        AppTextField("example@icloud.com", text: $email)
                            .disabled(service.isLoggingIn)
                    }

                    // 密码
                    FieldBlock(title: "密码", caption: "") {
                        AppSecureField("App 专用密码", text: $password)
                            .disabled(service.isLoggingIn)
                    }

                    // 两步验证码（条件显示）
                    if needsAuthCode {
                        FieldBlock(title: "两步验证码", caption: "Apple 已发送验证码，请输入 6 位数字") {
                            HStack(spacing: 8) {
                                AppTextField("000000", text: $authCode)
                                    .frame(width: 120)
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(Color.appAccent)
                                    .font(.title2)
                            }
                        }
                    }

                    // 错误提示
                    if let error = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.red.opacity(0.08))
                        )
                    }
                }
                .padding(.horizontal, 24)
            }

            Divider()

            // 按钮区
            HStack {
                Button("取消") {
                    isPresented = false
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(service.isLoggingIn)

                Spacer()

                Button {
                    performLogin()
                } label: {
                    HStack(spacing: 6) {
                        if service.isLoggingIn {
                            ProgressView().scaleEffect(0.7)
                        }
                        Text(needsAuthCode ? "验证并登录" : "登录")
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(email.isEmpty || password.isEmpty || service.isLoggingIn || service.availableRegions.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 480)
    }

    private func performLogin() {
        errorMessage = nil
        Task {
            do {
                try await service.login(
                    email: email, password: password,
                    authCode: authCode, region: selectedRegion
                )
                isPresented = false
            } catch let error as AppStoreError {
                if case .authCodeRequired = error {
                    withAnimation { needsAuthCode = true }
                } else {
                    errorMessage = error.localizedDescription
                    service.log("登录失败: \(error.localizedDescription)", type: .error)
                }
            } catch {
                errorMessage = error.localizedDescription
                service.log("登录失败: \(error.localizedDescription)", type: .error)
            }
        }
    }
}