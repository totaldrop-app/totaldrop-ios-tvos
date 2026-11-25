// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import TotalDropIOS

@Suite("TotalDropIOS Live Rust FFI Bridge")
struct MobileBridgeTests {
    private let bridge = LiveRustMobileBridge()

    @Test("Reports 0.3.0-beta.6 app version and strictly numeric CFBundleVersion")
    func rustVersionInfo() throws {
        let info = try #require(bridge.versionInfo())
        #expect(info.ok)
        #expect(info.appVersion == "0.3.0-beta.6")
        #expect(info.coreVersion == "0.2.0-beta.5")
        #expect(info.bundleVersion == "6")
        let isNumericBuild = info.bundleVersion.allSatisfy(\.isNumber)
        #expect(isNumericBuild)
    }

    @Test("Negotiates 35-language UI bundles including Turkish and RTL Arabic")
    func localizationAndRTL() {
        let en = bridge.loadUIBundle(preferredLanguages: ["en-US"], numericLocale: "en_US")
        #expect(en.locale == "en")
        #expect(!en.isRtl)
        #expect(!en.strings.isEmpty)

        let tr = bridge.loadUIBundle(preferredLanguages: ["tr-TR"], numericLocale: "tr_TR")
        #expect(tr.locale == "tr")
        #expect(!tr.isRtl)

        let ar = bridge.loadUIBundle(preferredLanguages: ["ar-SA"], numericLocale: "ar_SA")
        #expect(ar.locale == "ar")
        #expect(ar.isRtl)
    }

    @Test("Routes Universal Links and rejects new links while busy")
    @MainActor
    func universalLinkFragmentAndBusyGuard() throws {
        let url = try #require(URL(string: "https://totaldrop.app/r#7-harbor-rocket"))
        #expect(IOSAppModel.parseLinkCode(url, bridge: bridge) == "7-harbor-rocket")

        let busy = try #require(
            bridge.handleURL(
                rawURL: "https://totaldrop.app/r#7-harbor-rocket",
                activity: "active_send",
                preferredLanguages: ["en"],
                numericLocale: "en_US"
            )
        )
        #expect(busy.ok)
        #expect(busy.outcome == "busy")
        #expect(busy.message != nil)
    }

    @Test("Extracts clipboard codes and formats VoiceOver pauses via Rust")
    @MainActor
    func clipboardAndVoiceOver() throws {
        let extracted = try #require(
            bridge.extractClipboardCode("Get my files: https://totaldrop.app/r#7-harbor-rocket")
        )
        #expect(extracted.ok)
        #expect(extracted.displayCode == "7-harbor-rocket")
        #expect(extracted.voiceoverSpokenCode == "7, harbor, rocket")
        #expect(IOSAppModel.spokenVoiceOverCode("7-harbor-rocket", bridge: bridge) == "7, harbor, rocket")
    }

    @Test("Enforces App Group path confinement for Share Extension manifests")
    func shareExtensionManifestConfinement() throws {
        let groupRoot = "/var/mobile/Containers/Shared/AppGroup/TD"
        let validJSON = """
        {
          "appGroup": "group.app.totaldrop.ios",
          "rejectedBusy": false,
          "totalBytes": 42,
          "entries": [{
            "stagedPath": "\(groupRoot)/SharedInbox/0/report.pdf",
            "safeName": "report.pdf",
            "collisionKey": "report.pdf",
            "byteSize": 42,
            "chunks": 1
          }],
          "skipped": []
        }
        """
        let valid = try #require(
            bridge.parseShareManifest(manifestJSON: validJSON, appGroupRoot: groupRoot)
        )
        #expect(valid.ok)
        #expect(valid.entries?.count == 1)

        let escapedJSON = """
        {
          "appGroup": "group.app.totaldrop.ios",
          "rejectedBusy": false,
          "totalBytes": 10,
          "entries": [{
            "stagedPath": "/etc/passwd",
            "safeName": "passwd",
            "collisionKey": "passwd",
            "byteSize": 10,
            "chunks": 1
          }],
          "skipped": []
        }
        """
        let escaped = try #require(
            bridge.parseShareManifest(manifestJSON: escapedJSON, appGroupRoot: groupRoot)
        )
        #expect(!escaped.ok)
    }

    @Test("Validates BGContinuedProcessingTask checkpoints via Rust")
    func backgroundCheckpointParsing() throws {
        let checkpointJSON = """
        {
          "taskIdentifier": "app.totaldrop.ios.transfer",
          "direction": "receiving",
          "doneBytes": 1048576,
          "totalBytes": 2097152,
          "completedChunks": 1,
          "totalChunks": 2,
          "percent": 50,
          "notificationTitle": "Receiving files",
          "notificationSubtitle": "Continuing in background",
          "progressSummary": "1 MB / 2 MB",
          "expiredBySystem": false
        }
        """
        let parsed = try #require(bridge.parseCheckpoint(checkpointJSON: checkpointJSON))
        #expect(parsed.ok)
        #expect(parsed.direction == "receiving")
        #expect(parsed.percent == 50)
        #expect(parsed.completedChunks == 1)
    }

    @Test("Reveals Bidi overrides in untrusted filenames and received text")
    func bidiSanitization() throws {
        let name = try #require(bridge.sanitizeFilename("photo\u{202E}gpj.app"))
        #expect(name.ok)
        #expect(name.hasHiddenControls)
        #expect(name.sanitized == "photo<U+202E>gpj.app")

        let text = try #require(bridge.sanitizeText("note\u{202E}1\r\n2"))
        #expect(text.ok)
        #expect(text.hadHiddenControls)
        #expect(text.displayText == "note<U+202E>1\n2")
    }

    @Test("Floor-rounds 99.9999% transfer progress to 99% with regional decimals")
    func progressFloorRounding() throws {
        let progress = try #require(
            bridge.formatProgress(
                doneBytes: 999_999,
                totalBytes: 1_000_000,
                preferredLanguages: ["de-DE"],
                numericLocale: "de_DE"
            )
        )
        #expect(progress.ok)
        #expect(progress.percentValue == 99)
        #expect(progress.doneBytesText.contains(","))
    }

    @Test("Rejects unknown session handles cleanly without panicking")
    func invalidSessionHandles() {
        #expect(bridge.stopSession(handle: 999_999) < 0)
        #expect(bridge.declineOffer(handle: 999_999) < 0)
        #expect(bridge.destroySession(handle: 999_999) < 0)
        #expect(bridge.pollEvents(handle: 999_999).isEmpty)
    }

    @Test("IOSAppModel loads live Rust RTL state and sanitizes untrusted names")
    @MainActor
    func appModelLiveIntegration() {
        let model = IOSAppModel(
            bridge: bridge,
            preferredLanguages: ["ar-SA"],
            numericLocale: "ar_SA",
            registerBackgroundTasks: false
        )
        #expect(model.layoutDirection == .rightToLeft)
        #expect(model.versionInfo?.appVersion == "0.3.0-beta.6")
        let badURL = URL(fileURLWithPath: "/tmp/invoice\u{202E}fdp.exe")
        #expect(model.displayFilename(for: badURL) == "invoice<U+202E>fdp.exe")
    }
}
