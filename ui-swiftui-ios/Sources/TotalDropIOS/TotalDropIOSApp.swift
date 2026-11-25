// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import BackgroundTasks
import Foundation
import Observation
import SwiftUI

/// Primary tabs in the iOS and iPadOS SwiftUI interface.
public enum IOSTab: String, CaseIterable, Identifiable, Sendable {
    case send
    case receive
    case settings

    public var id: String { rawValue }
}

/// Transfer lifecycle state on iOS and iPadOS, driven live by `totaldrop-apple-mobile-ffi`.
public enum IOSTransferPhase: Equatable, Sendable {
    case idle
    case waitingForPeer(code: String, universalLink: String, spokenCode: String, shareMessage: String)
    case connecting(code: String)
    case incomingOffer(
        files: Int,
        totalBytes: UInt64,
        formattedSize: String,
        isText: Bool,
        words: [String],
        topLevelNames: [String],
        hasHiddenControls: Bool
    )
    case transferring(isSending: Bool, percent: Int, summaryText: String, words: [String])
    case finished(message: String, receivedText: String?)
    case failed(headline: String, cause: String?, technicalDetail: String)

    public var isBusy: Bool {
        switch self {
        case .idle, .finished, .failed:
            return false
        case .waitingForPeer, .connecting, .incomingOffer, .transferring:
            return true
        }
    }

    public var activitySlug: String {
        switch self {
        case .idle, .finished, .failed:
            return "idle"
        case .waitingForPeer:
            return "active_send"
        case .connecting:
            return "active_receive"
        case .incomingOffer:
            return "awaiting_user_decision"
        case .transferring(let isSending, _, _, _):
            return isSending ? "active_send" : "active_receive"
        }
    }
}

#if os(iOS)
private final class UncheckedBGTaskBox: @unchecked Sendable {
    let task: BGTask

    init(_ task: BGTask) {
        self.task = task
    }
}
#endif

/// Coordinates `BGContinuedProcessingTask` (iOS 26+) and `BGProcessingTask` fallback
/// so active transfers started by the user continue across app switches and screen lock.
@MainActor
public final class BackgroundTransferLifecycle {
    public static let taskIdentifier = "app.totaldrop.ios.transfer"
    private static var registeredIdentifiers: Set<String> = []

    private var activeStopCallback: (@MainActor () -> Void)?

    public init() {}

    private func invokeSystemExpiration() {
        activeStopCallback?()
    }

    public func register(onSystemExpiration: @escaping @MainActor () -> Void) {
        self.activeStopCallback = onSystemExpiration
        #if os(iOS)
        guard !Self.registeredIdentifiers.contains(Self.taskIdentifier) else {
            return
        }
        Self.registeredIdentifiers.insert(Self.taskIdentifier)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            let box = UncheckedBGTaskBox(task)
            let owner = self
            box.task.expirationHandler = {
                box.task.setTaskCompleted(success: false)
                Task { @MainActor in
                    owner?.invokeSystemExpiration()
                }
            }
        }
        #endif
    }

    public func submitContinuedTransferRequest(isSending: Bool) {
        #if os(iOS)
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
        #endif
        _ = isSending
    }

    public func cancelPendingRequests() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        #endif
    }
}

/// Main `@Observable` state model for iOS and iPadOS backed by live Rust FFI.
@Observable
@MainActor
public final class IOSAppModel {
    public static let appGroupID = "group.app.totaldrop.ios"

    public var selectedTab: IOSTab = .send
    public var selectedURLs: [URL] = []
    public var strongerCode: Bool = false
    public var receiveCodeInput: String = ""
    public var phase: IOSTransferPhase = .idle
    public var bannerMessage: String?

    public var rendezvousServer: String = "wss://rendezvous.totaldrop.app"
    public var relayServer: String = "wss://relay.totaldrop.app"
    public var stunServer: String = "stun.cloudflare.com:3478"
    public var privacyMode: Bool = false
    public var layoutDirection: LayoutDirection = .leftToRight
    public var uiBundle: RustMobileUIBundle
    public var versionInfo: RustMobileVersionInfo?

    private let bridge: any MobileBridgeProtocol
    private let bgLifecycle = BackgroundTransferLifecycle()
    private var activeSessionHandle: UInt64 = 0
    private var activeSessionIsSending: Bool = false
    private var activeVerificationWords: [String] = []
    private var activeOfferIsText: Bool = false
    private var pollTask: Task<Void, Never>?

    public init(
        bridge: any MobileBridgeProtocol = LiveRustMobileBridge(),
        preferredLanguages: [String] = Locale.preferredLanguages,
        numericLocale: String? = Locale.current.identifier,
        registerBackgroundTasks: Bool = false
    ) {
        self.bridge = bridge
        let langs = preferredLanguages.isEmpty ? ["en"] : preferredLanguages
        let bundle = bridge.loadUIBundle(preferredLanguages: langs, numericLocale: numericLocale)
        self.uiBundle = bundle
        self.versionInfo = bridge.versionInfo()
        self.layoutDirection = bundle.isRtl ? .rightToLeft : .leftToRight

        if registerBackgroundTasks {
            bgLifecycle.register { [weak self] in
                self?.stopTransfer(expiredBySystem: true)
            }
        }
    }

    public func l10n(_ key: String, fallback: String) -> String {
        uiBundle.text(key, fallback: fallback)
    }

    public var currentTransferConfig: RustMobileTransferConfig {
        RustMobileTransferConfig(
            server: rendezvousServer,
            relay: relayServer,
            stun: stunServer,
            privacyMode: privacyMode,
            strongerCode: strongerCode
        )
    }

    public var defaultReceiveDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return docs.appendingPathComponent("TotalDrop", isDirectory: true)
    }

    /// Parses an incoming Universal Link (`https://totaldrop.app/r#<code>`) or `totaldrop://r/<code>`
    /// through the live Rust protocol validator.
    public func handleUniversalLink(_ url: URL) {
        if url.host == "share-extension" {
            ingestShareExtensionManifest()
            return
        }
        let langs = Locale.preferredLanguages.isEmpty ? ["en"] : Locale.preferredLanguages
        let routed = bridge.handleURL(
            rawURL: url.absoluteString,
            activity: phase.activitySlug,
            preferredLanguages: langs,
            numericLocale: Locale.current.identifier
        )
        guard let routed, routed.ok else {
            bannerMessage = l10n("errorBadCode", fallback: "That link does not hold a valid TotalDrop code.")
            return
        }
        switch routed.outcome {
        case "connect_receive":
            guard let code = routed.displayCode, !code.isEmpty else {
                bannerMessage = l10n("errorBadCode", fallback: "That link does not hold a valid TotalDrop code.")
                return
            }
            selectedTab = .receive
            receiveCodeInput = code
            connectToSender()
        case "busy":
            bannerMessage = routed.message
                ?? l10n("linkBusy", fallback: "Finish or stop what is on the screen, then open the link again.")
        default:
            bannerMessage = l10n("errorBadCode", fallback: "That link does not hold a valid TotalDrop code.")
        }
    }

    public static func parseLinkCode(
        _ url: URL,
        bridge: any MobileBridgeProtocol = LiveRustMobileBridge()
    ) -> String? {
        guard let routed = bridge.handleURL(
            rawURL: url.absoluteString,
            activity: "idle",
            preferredLanguages: ["en"],
            numericLocale: "en_US"
        ),
            routed.ok,
            routed.outcome == "connect_receive",
            let code = routed.displayCode,
            !code.isEmpty
        else {
            return nil
        }
        return code
    }

    public static func spokenVoiceOverCode(
        _ code: String,
        bridge: any MobileBridgeProtocol = LiveRustMobileBridge()
    ) -> String {
        if let res = bridge.voiceoverCode(code), res.ok, let spoken = res.spoken, !spoken.isEmpty {
            return spoken
        }
        return code.split(separator: "-").joined(separator: ", ")
    }

    public func extractClipboardCode(_ rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let extracted = bridge.extractClipboardCode(trimmed),
           extracted.ok,
           let code = extracted.displayCode,
           !code.isEmpty
        {
            return code
        }
        return trimmed
    }

    public func displayFilename(for url: URL) -> String {
        let raw = url.lastPathComponent.precomposedStringWithCanonicalMapping
        if let res = bridge.sanitizeFilename(raw), res.ok {
            return res.sanitized
        }
        return raw
    }

    /// Reads and path-confinement validates staged files written to `group.app.totaldrop.ios`
    /// by `ShareExtension` using `totaldrop_mobile_parse_share_manifest_json`.
    public func ingestShareExtensionManifest() {
        guard !phase.isBusy else {
            bannerMessage = l10n(
                "shareBusy",
                fallback: "A transfer is still running. Wait for it to finish or stop it, then share again."
            )
            return
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            return
        }
        let manifestURL = container.appendingPathComponent("SharedInbox/manifest.json")
        guard let rawJSON = try? String(contentsOf: manifestURL, encoding: .utf8),
              let parsed = bridge.parseShareManifest(
                  manifestJSON: rawJSON,
                  appGroupRoot: container.path
              ),
              parsed.ok
        else {
            return
        }
        let entries = parsed.entries ?? []
        selectedURLs = entries.map { URL(fileURLWithPath: $0.stagedPath) }
        if let notice = parsed.notice, !notice.isEmpty {
            bannerMessage = notice
        }
        selectedTab = .send
    }

    public func startSend() {
        guard !phase.isBusy, !selectedURLs.isEmpty else { return }
        let paths = selectedURLs.map(\.path)
        let langs = Locale.preferredLanguages.isEmpty ? ["en"] : Locale.preferredLanguages
        let handle = bridge.startSendFiles(
            paths: paths,
            config: currentTransferConfig,
            preferredLanguages: langs,
            numericLocale: Locale.current.identifier
        )
        guard handle != 0 else {
            phase = .failed(
                headline: l10n("errorOther", fallback: "Could not start sending."),
                cause: nil,
                technicalDetail: "totaldrop_mobile_session_start_send_files returned 0"
            )
            return
        }
        beginSession(handle: handle, isSending: true)
        bgLifecycle.submitContinuedTransferRequest(isSending: true)
    }

    public func startSendText(_ text: String) {
        guard !phase.isBusy, !text.isEmpty else { return }
        let langs = Locale.preferredLanguages.isEmpty ? ["en"] : Locale.preferredLanguages
        let handle = bridge.startSendText(
            text: text,
            config: currentTransferConfig,
            preferredLanguages: langs,
            numericLocale: Locale.current.identifier
        )
        guard handle != 0 else {
            phase = .failed(
                headline: l10n("errorOther", fallback: "Could not start sending text."),
                cause: nil,
                technicalDetail: "totaldrop_mobile_session_start_send_text returned 0"
            )
            return
        }
        beginSession(handle: handle, isSending: true)
        bgLifecycle.submitContinuedTransferRequest(isSending: true)
    }

    public func connectToSender() {
        let code = receiveCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !phase.isBusy else { return }
        let langs = Locale.preferredLanguages.isEmpty ? ["en"] : Locale.preferredLanguages
        let handle = bridge.startReceive(
            codeOrLink: code,
            config: currentTransferConfig,
            preferredLanguages: langs,
            numericLocale: Locale.current.identifier
        )
        guard handle != 0 else {
            phase = .failed(
                headline: l10n("errorBadCode", fallback: "That code is not valid."),
                cause: nil,
                technicalDetail: "totaldrop_mobile_session_start_receive returned 0"
            )
            return
        }
        phase = .connecting(code: code)
        beginSession(handle: handle, isSending: false)
        bgLifecycle.submitContinuedTransferRequest(isSending: false)
    }

    public func acceptOffer(destination: URL? = nil) {
        guard activeSessionHandle != 0 else { return }
        let destPath: String?
        if activeOfferIsText {
            destPath = nil
        } else {
            let dir = destination ?? defaultReceiveDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            destPath = dir.path
        }
        let status = bridge.acceptOffer(handle: activeSessionHandle, destDir: destPath)
        if status != 0 {
            phase = .failed(
                headline: l10n("errorOther", fallback: "Could not accept the incoming transfer."),
                cause: nil,
                technicalDetail: "totaldrop_mobile_session_accept_offer returned \(status)"
            )
            teardownActiveSession()
        }
    }

    public func declineOffer() {
        if activeSessionHandle != 0 {
            _ = bridge.declineOffer(handle: activeSessionHandle)
        }
        bgLifecycle.cancelPendingRequests()
        teardownActiveSession()
        phase = .idle
    }

    public func stopTransfer(expiredBySystem: Bool = false) {
        if activeSessionHandle != 0 {
            _ = bridge.stopSession(handle: activeSessionHandle)
        }
        bgLifecycle.cancelPendingRequests()
        teardownActiveSession()
        if expiredBySystem {
            phase = .failed(
                headline: "Transfer paused in the background.",
                cause: "iOS reclaimed background execution time before completion.",
                technicalDetail: "BGContinuedProcessingTask expirationHandler invoked"
            )
        } else {
            phase = .idle
        }
    }

    private func beginSession(handle: UInt64, isSending: Bool) {
        teardownActiveSession()
        activeSessionHandle = handle
        activeSessionIsSending = isSending
        activeVerificationWords = []
        activeOfferIsText = false
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeSessionHandle == handle else { return }
                let events = self.bridge.pollEvents(handle: handle)
                for ev in events {
                    self.apply(event: ev)
                    if self.activeSessionHandle != handle {
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func apply(event: RustMobileSessionEvent) {
        switch event {
        case .codeReady(
            let displayCode,
            _,
            let universalLink,
            let voiceoverSpokenCode,
            let shareMessage,
            _,
            _,
            _,
            _,
            _
        ):
            phase = .waitingForPeer(
                code: displayCode,
                universalLink: universalLink,
                spokenCode: voiceoverSpokenCode,
                shareMessage: shareMessage
            )
        case .waiting:
            break
        case .connected(let words, _):
            activeVerificationWords = words
            phase = .transferring(
                isSending: activeSessionIsSending,
                percent: 0,
                summaryText: "",
                words: words
            )
        case .offerReady(
            let files,
            _,
            let totalBytes,
            let formattedSize,
            let isText,
            _,
            _,
            let topLevelNames,
            _,
            _,
            let hasHiddenControls,
            let words,
            _
        ):
            activeVerificationWords = words
            activeOfferIsText = isText
            phase = .incomingOffer(
                files: files,
                totalBytes: totalBytes,
                formattedSize: formattedSize,
                isText: isText,
                words: words,
                topLevelNames: topLevelNames,
                hasHiddenControls: hasHiddenControls
            )
        case .progress(_, _, let percentValue, _, _, _, let fractionText):
            phase = .transferring(
                isSending: activeSessionIsSending,
                percent: percentValue,
                summaryText: fractionText,
                words: activeVerificationWords
            )
        case .done(
            let filesOk,
            _,
            _,
            let formattedBytes,
            let isText,
            let savedTo,
            _,
            _,
            let sanitizedText,
            _,
            _
        ):
            bgLifecycle.cancelPendingRequests()
            let summary: String
            if isText {
                summary = activeSessionIsSending
                    ? "Text sent and verified (\(formattedBytes))."
                    : "Text received and verified (\(formattedBytes))."
            } else if let savedTo, !savedTo.isEmpty {
                summary = "Received \(filesOk) file(s) (\(formattedBytes)) in \(savedTo)."
            } else {
                summary = "Sent \(filesOk) file(s) (\(formattedBytes)) and verified."
            }
            phase = .finished(message: summary, receivedText: sanitizedText)
            teardownActiveSession()
        case .declined(_, let headline):
            bgLifecycle.cancelPendingRequests()
            phase = .failed(headline: headline, cause: nil, technicalDetail: "Offer declined by peer")
            teardownActiveSession()
        case .failed(let headline, let cause, let technicalDetail):
            bgLifecycle.cancelPendingRequests()
            phase = .failed(headline: headline, cause: cause, technicalDetail: technicalDetail)
            teardownActiveSession()
        }
    }

    private func teardownActiveSession() {
        pollTask?.cancel()
        pollTask = nil
        if activeSessionHandle != 0 {
            let handle = activeSessionHandle
            activeSessionHandle = 0
            _ = bridge.destroySession(handle: handle)
        }
    }
}

#if TOTALDROP_APP_ENTRY
@main
#endif
public struct TotalDropIOSApp: App {
    @State private var model = IOSAppModel(registerBackgroundTasks: true)

    public init() {}

    public var body: some Scene {
        WindowGroup {
            IOSRootTabView(model: model)
                .environment(\.layoutDirection, model.layoutDirection)
                .onOpenURL { url in
                    model.handleUniversalLink(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        model.handleUniversalLink(url)
                    }
                }
        }
    }
}

struct IOSRootTabView: View {
    @Bindable var model: IOSAppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack {
                SendView(model: model)
            }
            .tabItem {
                Label("Send", systemImage: "arrow.up.circle")
            }
            .tag(IOSTab.send)

            NavigationStack {
                ReceiveView(model: model)
            }
            .tabItem {
                Label("Receive", systemImage: "arrow.down.circle")
            }
            .tag(IOSTab.receive)

            NavigationStack {
                IOSSettingsView(model: model)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(IOSTab.settings)
        }
        .safeAreaInset(edge: .top) {
            if let banner = model.bannerMessage {
                AdaptiveAccessibilityStack(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                    Text(banner)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss") {
                        model.bannerMessage = nil
                    }
                    .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 56 : 44)
                }
                .padding(12)
                .background(.regularMaterial)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Switches automatically from `HStack` to `VStack` at `accessibility1`…`accessibility5`
/// so controls never clip or overlap under extreme Dynamic Type scales.
struct AdaptiveAccessibilityStack<Content: View>: View {
    let isAccessibilitySize: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12, content: content)
        } else {
            HStack(alignment: .center, spacing: 12, content: content)
        }
    }
}

struct IOSSettingsView: View {
    @Bindable var model: IOSAppModel

    var body: some View {
        Form {
            Section("Rendezvous Server") {
                TextField("wss://rendezvous.totaldrop.app", text: $model.rendezvousServer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Relay Server") {
                TextField("wss://relay.totaldrop.app", text: $model.relayServer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Privacy") {
                Toggle("Hide my address from the other device", isOn: $model.privacyMode)
                Text("Everything goes through the relay so the other device never sees your IP address. Files stay end-to-end encrypted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let version = model.versionInfo {
                Section("About") {
                    LabeledContent("Version", value: "\(version.appVersion) (\(version.bundleVersion))")
                    LabeledContent("Core", value: version.coreVersion)
                }
            }
        }
        .navigationTitle("Settings")
    }
}
