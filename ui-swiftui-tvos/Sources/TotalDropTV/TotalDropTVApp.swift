// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Primary tabs in the Apple tvOS 10-foot living-room interface.
public enum TvTab: String, CaseIterable, Identifiable, Sendable {
    case receive
    case send

    public var id: String { rawValue }
}

/// Focusable cards mirrored from `TvFocusCard` in `totaldrop-apple-mobile-bridge`.
public enum TvFocusSlot: Hashable, Sendable {
    case codeBanner
    case qrCard
    case verificationCard
    case primaryAction
    case cancelAction
}

/// Lifecycle state of a 10-foot Apple TV session driven live by `totaldrop-apple-mobile-ffi`.
public enum TvSessionPhase: Equatable, Sendable {
    case idle
    case waitingToPair(code: String, qrPayload: String)
    case connecting(code: String)
    case offerReady(
        files: Int,
        totalBytes: UInt64,
        formattedSize: String,
        isText: Bool,
        words: [String],
        names: [String],
        hasHiddenControls: Bool
    )
    case transferring(percent: Int, summary: String, words: [String])
    case completed(summary: String, receivedText: String?)
    case failed(headline: String, detail: String)

    public var keepsScreenAwake: Bool {
        switch self {
        case .idle, .completed, .failed:
            return false
        case .waitingToPair, .connecting, .offerReady, .transferring:
            return true
        }
    }
}

/// `@Observable` living-room session coordinator for Apple tvOS backed by live Rust FFI.
///
/// Staging files on tvOS uses `FileManager.default.urls(for: .cachesDirectory)`
/// (`NSCachesDirectory/TotalDrop`) because tvOS provides no persistent user Downloads
/// directory and may purge idle app caches when foregrounded apps need storage.
@Observable
@MainActor
public final class TvAppModel {
    public var selectedTab: TvTab = .receive
    public var codeInput: String = ""
    public var sendNoteText: String = "Shared from Apple TV via TotalDrop"
    public var strongerCode: Bool = false
    public var rendezvousServer: String = "wss://rendezvous.totaldrop.app"
    public var relayServer: String = "wss://relay.totaldrop.app"
    public var stunServer: String = "stun.cloudflare.com:3478"
    public var privacyMode: Bool = false

    public var phase: TvSessionPhase = .idle {
        didSet {
            updateIdleTimer()
        }
    }
    public var layoutDirection: LayoutDirection = .leftToRight
    public var uiBundle: RustMobileUIBundle
    public var versionInfo: RustMobileVersionInfo?

    private let bridge: any MobileBridgeProtocol
    private var activeSessionHandle: UInt64 = 0
    private var activeVerificationWords: [String] = []
    private var activeOfferIsText: Bool = false
    private var pollTask: Task<Void, Never>?

    public init(
        bridge: any MobileBridgeProtocol = LiveRustMobileBridge(),
        preferredLanguages: [String] = Locale.preferredLanguages,
        numericLocale: String? = Locale.current.identifier
    ) {
        self.bridge = bridge
        let langs = preferredLanguages.isEmpty ? ["en"] : preferredLanguages
        let bundle = bridge.loadUIBundle(preferredLanguages: langs, numericLocale: numericLocale)
        self.uiBundle = bundle
        self.versionInfo = bridge.versionInfo()
        self.layoutDirection = bundle.isRtl ? .rightToLeft : .leftToRight
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

    public var cachesStagingDirectory: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root.appendingPathComponent("TotalDrop", isDirectory: true)
    }

    public func startPairingSend() {
        let trimmed = sendNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let langs = Locale.preferredLanguages.isEmpty ? ["en"] : Locale.preferredLanguages
        let handle = bridge.startSendText(
            text: trimmed,
            config: currentTransferConfig,
            preferredLanguages: langs,
            numericLocale: Locale.current.identifier
        )
        guard handle != 0 else {
            phase = .failed(
                headline: "Could not start Apple TV pairing.",
                detail: "totaldrop_mobile_session_start_send_text returned 0"
            )
            return
        }
        phase = .connecting(code: "…")
        beginSession(handle: handle)
    }

    public func connectWithCode() {
        let trimmed = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let langs = Locale.preferredLanguages.isEmpty ? ["en"] : Locale.preferredLanguages
        let handle = bridge.startReceive(
            codeOrLink: trimmed,
            config: currentTransferConfig,
            preferredLanguages: langs,
            numericLocale: Locale.current.identifier
        )
        guard handle != 0 else {
            phase = .failed(
                headline: "That code is not valid.",
                detail: "totaldrop_mobile_session_start_receive returned 0"
            )
            return
        }
        phase = .connecting(code: trimmed)
        beginSession(handle: handle)
    }

    public func acceptOffer() {
        guard activeSessionHandle != 0 else { return }
        let destPath: String?
        if activeOfferIsText {
            destPath = nil
        } else {
            let dir = cachesStagingDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            destPath = dir.path
        }
        let status = bridge.acceptOffer(handle: activeSessionHandle, destDir: destPath)
        if status != 0 {
            phase = .failed(
                headline: "Could not accept transfer on Apple TV.",
                detail: "totaldrop_mobile_session_accept_offer returned \(status)"
            )
            teardownActiveSession()
        }
    }

    public func declineOffer() {
        if activeSessionHandle != 0 {
            _ = bridge.declineOffer(handle: activeSessionHandle)
        }
        teardownActiveSession()
        phase = .idle
    }

    public func cancelOrReset() {
        if activeSessionHandle != 0 {
            _ = bridge.stopSession(handle: activeSessionHandle)
        }
        teardownActiveSession()
        phase = .idle
    }

    private func beginSession(handle: UInt64) {
        teardownActiveSession()
        activeSessionHandle = handle
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
        case .codeReady(let displayCode, _, let universalLink, _, _, _, _, _, _, _):
            phase = .waitingToPair(code: displayCode, qrPayload: universalLink)
        case .waiting:
            break
        case .connected(let words, _):
            activeVerificationWords = words
            phase = .transferring(percent: 0, summary: "", words: words)
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
            phase = .offerReady(
                files: files,
                totalBytes: totalBytes,
                formattedSize: formattedSize,
                isText: isText,
                words: words,
                names: topLevelNames,
                hasHiddenControls: hasHiddenControls
            )
        case .progress(_, _, let percentValue, _, _, _, let fractionText):
            phase = .transferring(
                percent: percentValue,
                summary: fractionText,
                words: activeVerificationWords
            )
        case .done(let filesOk, _, _, let formattedBytes, let isText, let savedTo, _, _, let sanitizedText, _, _):
            let summary: String
            if isText {
                summary = "Verified text (\(formattedBytes))."
            } else if let savedTo, !savedTo.isEmpty {
                summary = "Verified \(filesOk) file(s) (\(formattedBytes)) in \(savedTo)."
            } else {
                summary = "Sent and verified (\(formattedBytes))."
            }
            phase = .completed(summary: summary, receivedText: sanitizedText)
            teardownActiveSession()
        case .declined(_, let headline):
            phase = .failed(headline: headline, detail: "Offer declined by peer")
            teardownActiveSession()
        case .failed(let headline, _, let technicalDetail):
            phase = .failed(headline: headline, detail: technicalDetail)
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

    private func updateIdleTimer() {
        #if os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = phase.keepsScreenAwake
        #endif
    }
}

#if TOTALDROP_APP_ENTRY
@main
#endif
public struct TotalDropTVApp: App {
    @State private var model = TvAppModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            TabView(selection: $model.selectedTab) {
                TvReceiveView(model: model)
                    .tabItem {
                        Label("Receive", systemImage: "arrow.down.to.line.circle")
                    }
                    .tag(TvTab.receive)

                TvSendView(model: model)
                    .tabItem {
                        Label("Send", systemImage: "qrcode")
                    }
                    .tag(TvTab.send)
            }
            .environment(\.layoutDirection, model.layoutDirection)
        }
    }
}
