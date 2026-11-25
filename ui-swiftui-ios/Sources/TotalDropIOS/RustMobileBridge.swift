// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CTotalDropAppleMobileFFI
import Foundation

/// Version metadata returned by `totaldrop_mobile_version_json`.
public struct RustMobileVersionInfo: Codable, Equatable, Sendable {
    public let ok: Bool
    public let appVersion: String
    public let coreVersion: String
    public let bundleVersion: String

    enum CodingKeys: String, CodingKey {
        case ok
        case appVersion = "app_version"
        case coreVersion = "core_version"
        case bundleVersion = "bundle_version"
    }
}

/// Negotiated 35-language localization bundle from `totaldrop-l10n`.
public struct RustMobileUIBundle: Codable, Equatable, Sendable {
    public let locale: String
    public let isRtl: Bool
    public let isDraft: Bool
    public let strings: [String: String]

    public init(locale: String, isRtl: Bool, isDraft: Bool, strings: [String: String]) {
        self.locale = locale
        self.isRtl = isRtl
        self.isDraft = isDraft
        self.strings = strings
    }

    public func text(_ key: String, fallback: String) -> String {
        if let value = strings[key], !value.isEmpty {
            return value
        }
        return fallback
    }
}

/// Result of routing an incoming Universal Link or `totaldrop://` URL through Rust.
public struct RustMobileHandleURLResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let outcome: String
    public let displayCode: String?
    public let canonicalCode: String?
    public let universalLink: String?
    public let voiceoverSpokenCode: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case outcome
        case displayCode = "display_code"
        case canonicalCode = "canonical_code"
        case universalLink = "universal_link"
        case voiceoverSpokenCode = "voiceover_spoken_code"
        case message
    }
}

/// Normalized transfer code extracted from clipboard or QR text by Rust.
public struct RustMobileExtractedCode: Codable, Equatable, Sendable {
    public let ok: Bool
    public let displayCode: String?
    public let canonicalCode: String?
    public let universalLink: String?
    public let voiceoverSpokenCode: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case displayCode = "display_code"
        case canonicalCode = "canonical_code"
        case universalLink = "universal_link"
        case voiceoverSpokenCode = "voiceover_spoken_code"
    }
}

/// VoiceOver spoken code returned by `totaldrop_mobile_voiceover_code_json`.
public struct RustMobileVoiceOverCode: Codable, Equatable, Sendable {
    public let ok: Bool
    public let spoken: String?
}

/// One validated staged file entry from an iOS Share Extension App Group manifest.
public struct RustMobileManifestEntry: Codable, Equatable, Sendable {
    public let stagedPath: String
    public let safeName: String
    public let collisionKey: String
    public let byteSize: UInt64
    public let chunks: UInt64

    enum CodingKeys: String, CodingKey {
        case stagedPath = "staged_path"
        case safeName = "safe_name"
        case collisionKey = "collision_key"
        case byteSize = "byte_size"
        case chunks
    }
}

/// One skipped entry recorded in an iOS Share Extension App Group manifest.
public struct RustMobileManifestSkipped: Codable, Equatable, Sendable {
    public let rawName: String
    public let reason: String

    enum CodingKeys: String, CodingKey {
        case rawName = "raw_name"
        case reason
    }
}

/// Validated App Group Share Extension manifest returned by Rust.
public struct RustMobileShareManifest: Codable, Equatable, Sendable {
    public let ok: Bool
    public let appGroup: String?
    public let entries: [RustMobileManifestEntry]?
    public let totalBytes: UInt64?
    public let skipped: [RustMobileManifestSkipped]?
    public let notice: String?
    public let rejectedBusy: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case appGroup = "app_group"
        case entries
        case totalBytes = "total_bytes"
        case skipped
        case notice
        case rejectedBusy = "rejected_busy"
    }
}

/// Validated `BGContinuedProcessingTask` checkpoint parsed by Rust.
public struct RustMobileCheckpoint: Codable, Equatable, Sendable {
    public let ok: Bool
    public let taskIdentifier: String?
    public let direction: String?
    public let doneBytes: UInt64?
    public let totalBytes: UInt64?
    public let completedChunks: UInt64?
    public let totalChunks: UInt64?
    public let percent: Int?
    public let notificationTitle: String?
    public let notificationSubtitle: String?
    public let progressSummary: String?
    public let expiredBySystem: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case taskIdentifier = "task_identifier"
        case direction
        case doneBytes = "done_bytes"
        case totalBytes = "total_bytes"
        case completedChunks = "completed_chunks"
        case totalChunks = "total_chunks"
        case percent
        case notificationTitle = "notification_title"
        case notificationSubtitle = "notification_subtitle"
        case progressSummary = "progress_summary"
        case expiredBySystem = "expired_by_system"
    }
}

/// Sanitized filename returned by `totaldrop_mobile_sanitize_filename_json`.
public struct RustMobileSanitizedFilename: Codable, Equatable, Sendable {
    public let ok: Bool
    public let sanitized: String
    public let hasHiddenControls: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case sanitized
        case hasHiddenControls = "has_hidden_controls"
    }
}

/// Sanitized display text returned by `totaldrop_mobile_sanitize_text_json`.
public struct RustMobileSanitizedText: Codable, Equatable, Sendable {
    public let ok: Bool
    public let displayText: String
    public let shortened: Bool
    public let hadHiddenControls: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case displayText = "display_text"
        case shortened
        case hadHiddenControls = "had_hidden_controls"
    }
}

/// Regional floor-rounded progress returned by `totaldrop_mobile_format_progress_json`.
public struct RustMobileFormattedProgress: Codable, Equatable, Sendable {
    public let ok: Bool
    public let percentValue: Int
    public let percentText: String
    public let doneBytesText: String
    public let totalBytesText: String
    public let fractionText: String

    enum CodingKeys: String, CodingKey {
        case ok
        case percentValue = "percent_value"
        case percentText = "percent_text"
        case doneBytesText = "done_bytes_text"
        case totalBytesText = "total_bytes_text"
        case fractionText = "fraction_text"
    }
}

/// Network and privacy transfer configuration serialized to Rust.
public struct RustMobileTransferConfig: Codable, Equatable, Sendable {
    public let server: String
    public let relay: String
    public let stun: String
    public let privacyMode: Bool
    public let strongerCode: Bool

    public init(
        server: String = "wss://rendezvous.totaldrop.app",
        relay: String = "wss://relay.totaldrop.app",
        stun: String = "stun.cloudflare.com:3478",
        privacyMode: Bool = false,
        strongerCode: Bool = false
    ) {
        self.server = server
        self.relay = relay
        self.stun = stun
        self.privacyMode = privacyMode
        self.strongerCode = strongerCode
    }

    enum CodingKeys: String, CodingKey {
        case server
        case relay
        case stun
        case privacyMode = "privacy_mode"
        case strongerCode = "stronger_code"
    }
}

/// Structured NDJSON event emitted by an active Rust mobile transfer session.
public enum RustMobileSessionEvent: Equatable, Sendable {
    case codeReady(
        displayCode: String,
        canonicalCode: String,
        universalLink: String,
        voiceoverSpokenCode: String,
        shareMessage: String,
        entries: Int,
        totalBytes: UInt64,
        formattedTotal: String,
        skipped: Int,
        isText: Bool
    )
    case waiting(headline: String)
    case connected(verificationWords: [String], joinedWordsLtr: String)
    case offerReady(
        files: Int,
        dirs: Int,
        totalBytes: UInt64,
        formattedSize: String,
        isText: Bool,
        headline: String,
        summaryLine: String,
        topLevelNames: [String],
        remainingNames: Int,
        moreNamesLine: String?,
        hasHiddenControls: Bool,
        verificationWords: [String],
        joinedWordsLtr: String
    )
    case progress(
        doneBytes: UInt64,
        totalBytes: UInt64,
        percentValue: Int,
        percentText: String,
        doneBytesText: String,
        totalBytesText: String,
        fractionText: String
    )
    case done(
        filesOk: Int,
        filesFailed: Int,
        bytes: UInt64,
        formattedBytes: String,
        isText: Bool,
        savedTo: String?,
        placed: [String],
        receivedText: String?,
        sanitizedText: String?,
        textShortened: Bool,
        textHadHiddenControls: Bool
    )
    case declined(isText: Bool, headline: String)
    case failed(headline: String, cause: String?, technicalDetail: String)
}

private struct RawMobileSessionEventEnvelope: Decodable {
    let event: String
    let displayCode: String?
    let canonicalCode: String?
    let universalLink: String?
    let voiceoverSpokenCode: String?
    let shareMessage: String?
    let entries: Int?
    let totalBytes: UInt64?
    let formattedTotal: String?
    let skipped: Int?
    let isText: Bool?
    let headline: String?
    let verificationWords: [String]?
    let joinedWordsLtr: String?
    let files: Int?
    let dirs: Int?
    let formattedSize: String?
    let summaryLine: String?
    let topLevelNames: [String]?
    let remainingNames: Int?
    let moreNamesLine: String?
    let hasHiddenControls: Bool?
    let doneBytes: UInt64?
    let percentValue: Int?
    let percentText: String?
    let doneBytesText: String?
    let totalBytesText: String?
    let fractionText: String?
    let filesOk: Int?
    let filesFailed: Int?
    let bytes: UInt64?
    let formattedBytes: String?
    let savedTo: String?
    let placed: [String]?
    let receivedText: String?
    let sanitizedText: String?
    let textShortened: Bool?
    let textHadHiddenControls: Bool?
    let cause: String?
    let technicalDetail: String?

    enum CodingKeys: String, CodingKey {
        case event
        case displayCode = "display_code"
        case canonicalCode = "canonical_code"
        case universalLink = "universal_link"
        case voiceoverSpokenCode = "voiceover_spoken_code"
        case shareMessage = "share_message"
        case entries
        case totalBytes = "total_bytes"
        case formattedTotal = "formatted_total"
        case skipped
        case isText = "is_text"
        case headline
        case verificationWords = "verification_words"
        case joinedWordsLtr = "joined_words_ltr"
        case files
        case dirs
        case formattedSize = "formatted_size"
        case summaryLine = "summary_line"
        case topLevelNames = "top_level_names"
        case remainingNames = "remaining_names"
        case moreNamesLine = "more_names_line"
        case hasHiddenControls = "has_hidden_controls"
        case doneBytes = "done_bytes"
        case percentValue = "percent_value"
        case percentText = "percent_text"
        case doneBytesText = "done_bytes_text"
        case totalBytesText = "total_bytes_text"
        case fractionText = "fraction_text"
        case filesOk = "files_ok"
        case filesFailed = "files_failed"
        case bytes
        case formattedBytes = "formatted_bytes"
        case savedTo = "saved_to"
        case placed
        case receivedText = "received_text"
        case sanitizedText = "sanitized_text"
        case textShortened = "text_shortened"
        case textHadHiddenControls = "text_had_hidden_controls"
        case cause
        case technicalDetail = "technical_detail"
    }

    func toEvent() -> RustMobileSessionEvent? {
        switch event {
        case "code_ready":
            let vDisplayCode: String = displayCode ?? ""
            let vCanonicalCode: String = canonicalCode ?? ""
            let vUniversalLink: String = universalLink ?? ""
            let vVoiceover: String = voiceoverSpokenCode ?? ""
            let vShareMessage: String = shareMessage ?? ""
            let vEntries: Int = entries ?? 0
            let vTotalBytes: UInt64 = totalBytes ?? 0
            let vFormattedTotal: String = formattedTotal ?? ""
            let vSkipped: Int = skipped ?? 0
            let vIsText: Bool = isText ?? false
            return RustMobileSessionEvent.codeReady(
                displayCode: vDisplayCode,
                canonicalCode: vCanonicalCode,
                universalLink: vUniversalLink,
                voiceoverSpokenCode: vVoiceover,
                shareMessage: vShareMessage,
                entries: vEntries,
                totalBytes: vTotalBytes,
                formattedTotal: vFormattedTotal,
                skipped: vSkipped,
                isText: vIsText
            )
        case "waiting":
            let vHeadline: String = headline ?? ""
            return RustMobileSessionEvent.waiting(headline: vHeadline)
        case "connected":
            let vWords: [String] = verificationWords ?? []
            let vJoined: String = joinedWordsLtr ?? ""
            return RustMobileSessionEvent.connected(
                verificationWords: vWords,
                joinedWordsLtr: vJoined
            )
        case "offer_ready":
            let vFiles: Int = files ?? 0
            let vDirs: Int = dirs ?? 0
            let vTotalBytes: UInt64 = totalBytes ?? 0
            let vFormattedSize: String = formattedSize ?? ""
            let vIsText: Bool = isText ?? false
            let vHeadline: String = headline ?? ""
            let vSummaryLine: String = summaryLine ?? ""
            let vTopLevelNames: [String] = topLevelNames ?? []
            let vRemainingNames: Int = remainingNames ?? 0
            let vHasHiddenControls: Bool = hasHiddenControls ?? false
            let vWords: [String] = verificationWords ?? []
            let vJoined: String = joinedWordsLtr ?? ""
            return RustMobileSessionEvent.offerReady(
                files: vFiles,
                dirs: vDirs,
                totalBytes: vTotalBytes,
                formattedSize: vFormattedSize,
                isText: vIsText,
                headline: vHeadline,
                summaryLine: vSummaryLine,
                topLevelNames: vTopLevelNames,
                remainingNames: vRemainingNames,
                moreNamesLine: moreNamesLine,
                hasHiddenControls: vHasHiddenControls,
                verificationWords: vWords,
                joinedWordsLtr: vJoined
            )
        case "progress":
            let vDoneBytes: UInt64 = doneBytes ?? 0
            let vTotalBytes: UInt64 = totalBytes ?? 0
            let vPercentValue: Int = percentValue ?? 0
            let vPercentText: String = percentText ?? "0%"
            let vDoneBytesText: String = doneBytesText ?? ""
            let vTotalBytesText: String = totalBytesText ?? ""
            let vFractionText: String = fractionText ?? ""
            return RustMobileSessionEvent.progress(
                doneBytes: vDoneBytes,
                totalBytes: vTotalBytes,
                percentValue: vPercentValue,
                percentText: vPercentText,
                doneBytesText: vDoneBytesText,
                totalBytesText: vTotalBytesText,
                fractionText: vFractionText
            )
        case "done":
            let vFilesOk: Int = filesOk ?? 0
            let vFilesFailed: Int = filesFailed ?? 0
            let vBytes: UInt64 = bytes ?? 0
            let vFormattedBytes: String = formattedBytes ?? ""
            let vIsText: Bool = isText ?? false
            let vPlaced: [String] = placed ?? []
            let vTextShortened: Bool = textShortened ?? false
            let vTextHadHiddenControls: Bool = textHadHiddenControls ?? false
            return RustMobileSessionEvent.done(
                filesOk: vFilesOk,
                filesFailed: vFilesFailed,
                bytes: vBytes,
                formattedBytes: vFormattedBytes,
                isText: vIsText,
                savedTo: savedTo,
                placed: vPlaced,
                receivedText: receivedText,
                sanitizedText: sanitizedText,
                textShortened: vTextShortened,
                textHadHiddenControls: vTextHadHiddenControls
            )
        case "declined":
            let vIsText: Bool = isText ?? false
            let vHeadline: String = headline ?? ""
            return RustMobileSessionEvent.declined(isText: vIsText, headline: vHeadline)
        case "failed":
            let vHeadline: String = headline ?? "Transfer failed"
            let vTechnicalDetail: String = technicalDetail ?? ""
            return RustMobileSessionEvent.failed(
                headline: vHeadline,
                cause: cause,
                technicalDetail: vTechnicalDetail
            )
        default:
            return nil
        }
    }
}

/// Abstract bridge boundary allowing both live Rust FFI execution and
/// deterministic Swift unit tests.
public protocol MobileBridgeProtocol: Sendable {
    func versionInfo() -> RustMobileVersionInfo?
    func loadUIBundle(preferredLanguages: [String], numericLocale: String?) -> RustMobileUIBundle
    func handleURL(
        rawURL: String,
        activity: String,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustMobileHandleURLResult?
    func extractClipboardCode(_ rawText: String) -> RustMobileExtractedCode?
    func voiceoverCode(_ displayCode: String) -> RustMobileVoiceOverCode?
    func parseShareManifest(manifestJSON: String, appGroupRoot: String) -> RustMobileShareManifest?
    func parseCheckpoint(checkpointJSON: String) -> RustMobileCheckpoint?
    func sanitizeFilename(_ rawName: String) -> RustMobileSanitizedFilename?
    func sanitizeText(_ rawText: String) -> RustMobileSanitizedText?
    func formatProgress(
        doneBytes: UInt64,
        totalBytes: UInt64,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustMobileFormattedProgress?
    func startSendFiles(
        paths: [String],
        config: RustMobileTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64
    func startSendText(
        text: String,
        config: RustMobileTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64
    func startReceive(
        codeOrLink: String,
        config: RustMobileTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64
    func acceptOffer(handle: UInt64, destDir: String?) -> Int32
    func declineOffer(handle: UInt64) -> Int32
    func stopSession(handle: UInt64) -> Int32
    func pollEvents(handle: UInt64) -> [RustMobileSessionEvent]
    func destroySession(handle: UInt64) -> Int32
}

/// Production Swift 6 bridge backed directly by `libtotaldrop_apple_mobile_ffi.a`.
public struct LiveRustMobileBridge: MobileBridgeProtocol, Sendable {
    public init() {}

    public func versionInfo() -> RustMobileVersionInfo? {
        decodeJSON(takeRustString(totaldrop_mobile_version_json()))
    }

    public func loadUIBundle(
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustMobileUIBundle {
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        let raw = withOptionalCString(langsJSON) { langsPtr in
            withOptionalCString(numericLocale) { numPtr in
                takeRustString(totaldrop_mobile_ui_bundle_json(langsPtr, numPtr))
            }
        }
        if let decoded: RustMobileUIBundle = decodeJSON(raw) {
            return decoded
        }
        return RustMobileUIBundle(locale: "en", isRtl: false, isDraft: false, strings: [:])
    }

    public func handleURL(
        rawURL: String,
        activity: String,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustMobileHandleURLResult? {
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        let raw = rawURL.withCString { urlPtr in
            activity.withCString { actPtr in
                langsJSON.withCString { langsPtr in
                    withOptionalCString(numericLocale) { numPtr in
                        takeRustString(
                            totaldrop_mobile_handle_url_json(urlPtr, actPtr, langsPtr, numPtr)
                        )
                    }
                }
            }
        }
        return decodeJSON(raw)
    }

    public func extractClipboardCode(_ rawText: String) -> RustMobileExtractedCode? {
        let raw = rawText.withCString { ptr in
            takeRustString(totaldrop_mobile_extract_clipboard_code_json(ptr))
        }
        return decodeJSON(raw)
    }

    public func voiceoverCode(_ displayCode: String) -> RustMobileVoiceOverCode? {
        let raw = displayCode.withCString { ptr in
            takeRustString(totaldrop_mobile_voiceover_code_json(ptr))
        }
        return decodeJSON(raw)
    }

    public func parseShareManifest(
        manifestJSON: String,
        appGroupRoot: String
    ) -> RustMobileShareManifest? {
        let raw = manifestJSON.withCString { jsonPtr in
            appGroupRoot.withCString { rootPtr in
                takeRustString(totaldrop_mobile_parse_share_manifest_json(jsonPtr, rootPtr))
            }
        }
        return decodeJSON(raw)
    }

    public func parseCheckpoint(checkpointJSON: String) -> RustMobileCheckpoint? {
        let raw = checkpointJSON.withCString { jsonPtr in
            takeRustString(totaldrop_mobile_parse_checkpoint_json(jsonPtr))
        }
        return decodeJSON(raw)
    }

    public func sanitizeFilename(_ rawName: String) -> RustMobileSanitizedFilename? {
        let raw = rawName.withCString { ptr in
            takeRustString(totaldrop_mobile_sanitize_filename_json(ptr))
        }
        return decodeJSON(raw)
    }

    public func sanitizeText(_ rawText: String) -> RustMobileSanitizedText? {
        let raw = rawText.withCString { ptr in
            takeRustString(totaldrop_mobile_sanitize_text_json(ptr))
        }
        return decodeJSON(raw)
    }

    public func formatProgress(
        doneBytes: UInt64,
        totalBytes: UInt64,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> RustMobileFormattedProgress? {
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        let raw = langsJSON.withCString { langsPtr in
            withOptionalCString(numericLocale) { numPtr in
                takeRustString(
                    totaldrop_mobile_format_progress_json(doneBytes, totalBytes, langsPtr, numPtr)
                )
            }
        }
        return decodeJSON(raw)
    }

    public func startSendFiles(
        paths: [String],
        config: RustMobileTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64 {
        guard let pathsJSON = encodeJSONString(paths) else { return 0 }
        let cfgJSON = encodeJSONString(config)
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        return pathsJSON.withCString { pathsPtr in
            withOptionalCString(cfgJSON) { cfgPtr in
                langsJSON.withCString { langsPtr in
                    withOptionalCString(numericLocale) { numPtr in
                        totaldrop_mobile_session_start_send_files(
                            pathsPtr,
                            cfgPtr,
                            langsPtr,
                            numPtr
                        )
                    }
                }
            }
        }
    }

    public func startSendText(
        text: String,
        config: RustMobileTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64 {
        let cfgJSON = encodeJSONString(config)
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        return text.withCString { textPtr in
            withOptionalCString(cfgJSON) { cfgPtr in
                langsJSON.withCString { langsPtr in
                    withOptionalCString(numericLocale) { numPtr in
                        totaldrop_mobile_session_start_send_text(
                            textPtr,
                            cfgPtr,
                            langsPtr,
                            numPtr
                        )
                    }
                }
            }
        }
    }

    public func startReceive(
        codeOrLink: String,
        config: RustMobileTransferConfig,
        preferredLanguages: [String],
        numericLocale: String?
    ) -> UInt64 {
        let cfgJSON = encodeJSONString(config)
        let langsJSON = encodeJSONString(preferredLanguages) ?? "[\"en\"]"
        return codeOrLink.withCString { codePtr in
            withOptionalCString(cfgJSON) { cfgPtr in
                langsJSON.withCString { langsPtr in
                    withOptionalCString(numericLocale) { numPtr in
                        totaldrop_mobile_session_start_receive(
                            codePtr,
                            cfgPtr,
                            langsPtr,
                            numPtr
                        )
                    }
                }
            }
        }
    }

    public func acceptOffer(handle: UInt64, destDir: String?) -> Int32 {
        withOptionalCString(destDir) { dirPtr in
            totaldrop_mobile_session_accept_offer(handle, dirPtr)
        }
    }

    public func declineOffer(handle: UInt64) -> Int32 {
        totaldrop_mobile_session_decline_offer(handle)
    }

    public func stopSession(handle: UInt64) -> Int32 {
        totaldrop_mobile_session_stop(handle)
    }

    public func pollEvents(handle: UInt64) -> [RustMobileSessionEvent] {
        guard let ndjson = takeRustString(totaldrop_mobile_session_poll_events_ndjson(handle)),
              !ndjson.isEmpty
        else {
            return []
        }
        let decoder = JSONDecoder()
        var events: [RustMobileSessionEvent] = []
        for line in ndjson.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let raw = try? decoder.decode(RawMobileSessionEventEnvelope.self, from: data),
               let ev = raw.toEvent()
            {
                events.append(ev)
            }
        }
        return events
    }

    public func destroySession(handle: UInt64) -> Int32 {
        totaldrop_mobile_session_destroy(handle)
    }

    private func takeRustString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { totaldrop_mobile_string_free(ptr) }
        return String(cString: ptr)
    }

    private func withOptionalCString<R>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let value else {
            return body(nil)
        }
        return value.withCString { ptr in
            body(ptr)
        }
    }

    private func encodeJSONString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeJSON<T: Decodable>(_ raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
