//
//  PrivacyPolicyView.swift
//  山西晋中理工学院 APP — 隐私协议 UI 页面
//
//  隐私主页 + 混合加载文档页（线上优先、失败自动切本地内置文本）
//  约束：禁止 @AppStorage + didSet；禁止 @Sendable Task 捕获 inout
//

import SwiftUI

// MARK: - 隐私协议列表页（隐私主页）

struct PrivacyPolicyHomeView: View {
    @ObservedObject private var privacyManager = PrivacyManager.shared
    @State private var selectedDocument: PrivacyDocumentType?
    @State private var navigationDocument: PrivacyDocumentType?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 顶部说明区
                headerSection
                // 文档卡片列表
                documentCards
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .background(GradientBackground())
        .navigationTitle("隐私与协议")
        .navigationBarTitleDisplayMode(.large)
        // 使用 sheet(item:) 模式确保状态更新安全
        .sheet(item: $navigationDocument) { docType in
            NavigationStack {
                PrivacyDocumentView(documentType: docType)
            }
            .sjzPresentationChrome()
        }
    }

    // MARK: - 顶部说明

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .displaySymbolFont(22)
                    .foregroundColor(.sjzPrimary)
                Text("您的隐私与权利")
                    .displayFont(20)
                    .fontWeight(.bold)
                    .foregroundColor(.sjzPrimary)
            }
            .padding(.top, 8)

            Text("我们重视您的隐私，请仔细阅读以下法律文件，了解您的权利与我们的承诺。")
                .displayFont(15)
                .foregroundColor(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 20)
    }

    // MARK: - 文档卡片

    private var documentCards: some View {
        VStack(spacing: 14) {
            ForEach(PrivacyDocumentType.allCases, id: \.self) { docType in
                documentCard(for: docType)
            }
        }
    }

    private func documentCard(for docType: PrivacyDocumentType) -> some View {
        Button {
            LogManager.shared.info("privacy", "点击隐私文档入口", context: ["type": docType.rawValue])
            navigationDocument = docType
        } label: {
            HStack(spacing: 16) {
                // 图标
                iconView(for: docType)

                // 文字内容
                VStack(alignment: .leading, spacing: 4) {
                    Text(docType.title)
                        .displayFont(17, weight: .semibold)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Text(docType == .terms ? "使用规则、免责声明、知识产权与争议解决" : "信息收集清单、权限说明、数据安全与您的权利")
                        .displayFont(12)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                // 箭头
                Image(systemName: "chevron.right")
                    .displaySymbolFont(12, weight: .semibold)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
                    .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(ScalingButtonStyle())
        .contentShape(Rectangle())
    }

    private func iconView(for docType: PrivacyDocumentType) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(iconBackgroundColor(for: docType))
                .frame(width: 44, height: 44)

            Image(systemName: docType.icon)
                .displaySymbolFont(18, weight: .medium)
                .foregroundColor(iconForegroundColor(for: docType))
        }
    }

    private func iconBackgroundColor(for docType: PrivacyDocumentType) -> Color {
        switch docType {
        case .terms:   return Color.sjzIndigo.opacity(0.12)
        case .privacy: return Color.sjzTeal.opacity(0.12)
        }
    }

    private func iconForegroundColor(for docType: PrivacyDocumentType) -> Color {
        switch docType {
        case .terms:   return .sjzIndigo
        case .privacy: return .sjzTeal
        }
    }
}

// MARK: - 隐私文档详情页

struct PrivacyDocumentView: View {
    let documentType: PrivacyDocumentType

    @ObservedObject private var privacyManager = PrivacyManager.shared
    @State private var document: PrivacyDocument?
    @State private var loadState: LoadState = .loading
    @Environment(\.dismiss) private var dismiss

    enum LoadState {
        case loading
        case loaded(PrivacyDocument)
        case error(String)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                loadingView
            case .loaded(let doc):
                documentContentView(doc)
            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle(documentType.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") {
                    LogManager.shared.info("privacy", "关闭隐私文档页", context: ["type": documentType.rawValue])
                    dismiss()
                }
            }
        }
        .background(GradientBackground())
        .task {
            await loadDocument()
        }
    }

    // MARK: - 加载逻辑

    private func loadDocument() async {
        loadState = .loading
        LogManager.shared.info("privacy", "开始加载隐私文档", context: ["type": documentType.rawValue])

        let doc = await privacyManager.fetchDocument(type: documentType)
        document = doc
        loadState = .loaded(doc)

        LogManager.shared.info("privacy", "隐私文档加载完成", context: ["type": documentType.rawValue, "source": doc.source.rawValue])
    }

    // MARK: - 加载中视图

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.sjzPrimary)

            Text("正在加载...")
                .displayFont(15)
                .foregroundColor(.secondary)

            Text("优先从网络获取最新版本")
                .displayFont(12)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 文档内容视图

    private func documentContentView(_ doc: PrivacyDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 来源标识
                sourceIndicator(source: doc.source)

                // 更新日期
                if let updated = doc.lastUpdated {
                    updateDateLabel(updated)
                }

                // 分隔线
                divider

                // 文档正文
                Text(doc.content)
                    .displayText(size: 15, baseLineSpacing: 8)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 40)
        }
    }

    // MARK: - 来源标识

    private func sourceIndicator(source: PrivacyDocumentSource) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(source == .online ? Color.sjzGreen : Color.sjzOrange)
                .frame(width: 8, height: 8)

            Text(source == .online ? "联网最新版本" : "离线兜底版本")
                .displayFont(12)
                .fontWeight(.medium)
                .foregroundColor(source == .online ? .sjzGreen : .sjzOrange)

            Spacer()

            if source == .offline {
                Button {
                    Task {
                        await retry()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .displaySymbolFont(11)
                        Text("重试联网")
                            .displayFont(12)
                    }
                    .foregroundColor(.sjzPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.sjzPrimary.opacity(0.08))
                    )
                }
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
    }

    private func updateDateLabel(_ date: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .displaySymbolFont(11)
                .foregroundColor(.secondary)
            Text("更新日期：\(date)")
                .displayFont(12)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    // MARK: - 错误视图

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "wifi.slash")
                .displaySymbolFont(48)
                .foregroundColor(.sjzOrange)

            Text(message)
                .displayFont(15)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                Task {
                    await retry()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .displaySymbolFont(15)
                    Text("重新加载")
                        .displayFont(15)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.sjzPrimary)
                )
            }
            .contentShape(Rectangle())

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 重试

    private func retry() async {
        LogManager.shared.info("privacy", "用户手动重试加载隐私文档", context: ["type": documentType.rawValue])
        loadState = .loading
        let doc = await privacyManager.fetchDocument(type: documentType)
        document = doc
        loadState = .loaded(doc)
    }
}

// MARK: - 首次启动隐私同意弹窗

struct PrivacyConsentView: View {
    @Binding var showConsent: Bool
    @Binding var consentAccepted: Bool
    let onAccept: () -> Void
    let onReject: () -> Void
    var isFromRestrictedMode: Bool = false

    @State private var showTerms = false
    @State private var showPrivacy = false

    var body: some View {
        ZStack {
            // 半透明背景遮罩
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { /* 阻止点击穿透 */ }

            // 弹窗卡片
            VStack(spacing: 0) {
                // 顶部图标
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.sjzPrimary.opacity(0.1), Color.sjzAccent.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 64, height: 64)

                        Image(systemName: "shield.checkered")
                            .displaySymbolFont(28, weight: .medium)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.sjzPrimary, .sjzAccent],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }

                    Text("隐私保护指引")
                        .displayFont(20)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("欢迎使用山西晋中理工学院校园应用。\n为了更好地保障您的权益，请阅读并同意以下协议。")
                        .displayFont(15)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
                .padding(.top, 28)
                .padding(.bottom, 20)

                // 协议链接
                VStack(spacing: 10) {
                    agreementLink(
                        icon: "doc.text.fill",
                        color: .sjzIndigo,
                        title: "用户协议",
                        subtitle: "使用规则、免责声明与知识产权",
                        action: {
                            LogManager.shared.info("privacy", "首次启动弹窗点击查看用户协议")
                            showTerms = true
                        }
                    )

                    agreementLink(
                        icon: "hand.raised.fill",
                        color: .sjzTeal,
                        title: "隐私政策",
                        subtitle: "信息收集、权限说明与数据安全",
                        action: {
                            LogManager.shared.info("privacy", "首次启动弹窗点击查看隐私政策")
                            showPrivacy = true
                        }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)

                // 按钮区
                VStack(spacing: 12) {
                    Button {
                        LogManager.shared.info("privacy", "用户同意隐私协议", context: [
                            "action": "accept_consent"
                        ])
                        withAnimation(.easeInOut(duration: 0.3)) {
                            consentAccepted = true
                            showConsent = false
                        }
                        onAccept()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .displaySymbolFont(15)
                            Text("同意并继续")
                                .displayFont(15)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(
                                    LinearGradient(
                                        colors: [.sjzPrimary, .sjzAccent],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .shadow(color: .sjzPrimary.opacity(0.25), radius: 8, y: 4)
                        )
                    }
                    .contentShape(Rectangle())

                    Button {
                        LogManager.shared.warning("privacy", "用户拒绝隐私协议", context: [
                            "action": "reject_consent",
                            "next": "restricted_mode"
                        ])
                        withAnimation(.easeInOut(duration: 0.3)) {
                            consentAccepted = false
                            showConsent = false
                        }
                        onReject()
                    } label: {
                        Text("不同意")
                            .displayFont(15)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(.systemGray6))
                            )
                    }
                    .contentShape(Rectangle())
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(.systemBackground))
                    .shadow(color: Color.black.opacity(0.15), radius: 20, y: 10)
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 60)
        }
        // 协议详情 sheet
        .sheet(isPresented: $showTerms) {
            NavigationStack {
                PrivacyDocumentView(documentType: .terms)
            }
            .sjzPresentationChrome()
        }
        .onChange(of: showTerms) { _, newValue in
            if !newValue {
                LogManager.shared.info("privacy", "首次启动弹窗中用户关闭用户协议详情", context: [
                    "action": "dismiss_sheet",
                    "document": "terms"
                ])
            }
        }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack {
                PrivacyDocumentView(documentType: .privacy)
            }
            .sjzPresentationChrome()
        }
        .onChange(of: showPrivacy) { _, newValue in
            if !newValue {
                LogManager.shared.info("privacy", "首次启动弹窗中用户关闭隐私政策详情", context: [
                    "action": "dismiss_sheet",
                    "document": "privacy-policy"
                ])
            }
        }
        .onAppear {
            LogManager.shared.info("privacy", "隐私同意弹窗已展示", context: [
                "state": "consent_dialog",
                "source": isFromRestrictedMode ? "restricted_mode" : "first_launch"
            ])
        }
        .onDisappear {
            LogManager.shared.info("privacy", "隐私同意弹窗已关闭", context: [
                "result": consentAccepted ? "accepted" : "rejected",
                "source": isFromRestrictedMode ? "restricted_mode" : "first_launch"
            ])
        }
    }

    private func agreementLink(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .displaySymbolFont(14, weight: .medium)
                        .foregroundColor(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .displayFont(15)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .displayFont(12)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .displaySymbolFont(12)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
            )
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 按钮缩放动画

struct ScalingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - 受限模式视图（拒绝隐私协议后显示）

/// 用户拒绝隐私协议后进入受限模式。
/// 提供两个选项：查看协议并重新同意，或退出应用。
/// 符合 Apple 5.1.1 合规要求 —— 不强制同意，但限制核心功能使用。
struct RestrictedModeView: View {
    @Binding var showRestricted: Bool
    @Binding var showConsent: Bool

    var body: some View {
        ZStack {
            // 全屏背景
            GradientBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // 图标区 —— 盾牌锁定图标
                ZStack {
                    // 外圈光晕
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.sjzPrimary.opacity(0.12),
                                    Color.sjzPrimary.opacity(0.04),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 20,
                                endRadius: 80
                            )
                        )
                        .frame(width: 160, height: 160)

                    // 图标背景圆
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.sjzPrimary.opacity(0.1), Color.sjzAccent.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)

                    // 图标
                    Image(systemName: "lock.shield.fill")
                        .displaySymbolFont(36, weight: .medium)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.sjzPrimary, .sjzAccent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .padding(.bottom, 28)

                // 标题
                Text("需要您的同意")
                    .displayFont(22)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .padding(.bottom, 14)

                // 说明文字
                Text("您还未同意《用户协议》和《隐私政策》。\n为保障您的信息安全，应用需要获得您的同意\n后才能继续使用全部功能。")
                    .displayFont(15)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .padding(.horizontal, 36)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)

                // 隐私承诺
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .displaySymbolFont(12)
                        .foregroundColor(.sjzGreen)
                    Text("您的隐私权利受到严格保护")
                        .displayFont(12)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 36)

                // 按钮区
                VStack(spacing: 14) {
                    // 查看并同意按钮
                    Button {
                        LogManager.shared.info("privacy", "受限模式中用户点击查看并同意", context: [
                            "action": "reopen_consent",
                            "from": "restricted_mode"
                        ])
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showRestricted = false
                        }
                        // 受限模式关闭后延迟展示隐私协议
                        LogManager.shared.info("privacy", "受限模式关闭，转入隐私协议查看")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                showConsent = true
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.fill")
                                .displaySymbolFont(15)
                            Text("查看并同意")
                                .displayFont(15)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(
                                    LinearGradient(
                                        colors: [.sjzPrimary, .sjzAccent],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .shadow(color: .sjzPrimary.opacity(0.25), radius: 8, y: 4)
                        )
                    }
                    .contentShape(Rectangle())

                    // 退出应用按钮
                    Button {
                        LogManager.shared.warning("privacy", "受限模式中用户选择退出应用", context: [
                            "action": "exit_app",
                            "from": "restricted_mode"
                        ])
                        exit(0)
                    } label: {
                        Text("退出应用")
                            .displayFont(15)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(.systemGray6))
                            )
                    }
                    .contentShape(Rectangle())
                }
                .padding(.horizontal, 40)

                Spacer()
                Spacer()
            }
        }
        .onAppear {
            LogManager.shared.info("privacy", "受限模式视图已加载", context: [
                "state": "restricted",
                "reason": "隐私协议未同意"
            ])
        }
        .onDisappear {
            LogManager.shared.info("privacy", "受限模式视图已关闭", context: [
                "nextState": showConsent ? "consent_dialog" : "exit"
            ])
        }
    }
}