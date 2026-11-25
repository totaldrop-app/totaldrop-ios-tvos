// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Native iOS/iPadOS SwiftUI Receive screen with VoiceOver labels and Dynamic Type
/// layout scaling up to `.accessibility5`.
public struct ReceiveView: View {
    @Bindable var model: IOSAppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(model: IOSAppModel) {
        self.model = model
    }

    private var minTapHeight: CGFloat {
        dynamicTypeSize >= .accessibility3 ? 68 : (dynamicTypeSize.isAccessibilitySize ? 56 : 44)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch model.phase {
                case .connecting(let code):
                    connectingSection(code: code)
                case .incomingOffer(
                    let files,
                    let totalBytes,
                    let formattedSize,
                    let isText,
                    let words,
                    let names,
                    let hasHiddenControls
                ):
                    offerSection(
                        files: files,
                        totalBytes: totalBytes,
                        formattedSize: formattedSize,
                        isText: isText,
                        words: words,
                        names: names,
                        hasHiddenControls: hasHiddenControls
                    )
                case .transferring(let isSending, let percent, let summary, let words) where !isSending:
                    receivingProgressSection(percent: percent, summary: summary, words: words)
                case .finished(let message, let receivedText):
                    finishedSection(message: message, receivedText: receivedText)
                case .failed(let headline, let cause, let detail):
                    failedSection(headline: headline, cause: cause, detail: detail)
                default:
                    codeInputSection
                }
            }
            .padding()
        }
        .navigationTitle("Receive files")
    }

    private var codeInputSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ask the sender for their code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("7-harbor-rocket", text: $model.receiveCodeInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .frame(minHeight: minTapHeight)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Transfer code")
                .accessibilityHint("Starts with a number followed by two or three words")

            AdaptiveAccessibilityStack(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                Button {
                    #if canImport(UIKit)
                    if let pasted = UIPasteboard.general.string {
                        model.receiveCodeInput = model.extractClipboardCode(pasted)
                    }
                    #endif
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity, minHeight: minTapHeight)
                }
                .buttonStyle(.bordered)

                Button {
                    model.connectToSender()
                } label: {
                    Text("Connect")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: minTapHeight)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.receiveCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func connectingSection(code: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView("Connecting securely…")
            Text(code)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Connecting with code \(IOSAppModel.spokenVoiceOverCode(code))")
            Button(role: .destructive) {
                model.stopTransfer()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity, minHeight: minTapHeight)
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func offerSection(
        files: Int,
        totalBytes: UInt64,
        formattedSize: String,
        isText: Bool,
        words: [String],
        names: [String],
        hasHiddenControls: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isText ? "Incoming text" : "Incoming files")
                .font(.title3.weight(.semibold))
            let sizeText = formattedSize.isEmpty
                ? ByteCountFormatter.string(fromByteCount: Int64(clamping: totalBytes), countStyle: .file)
                : formattedSize
            Text(isText ? sizeText : "\(files) file(s) · \(sizeText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if hasHiddenControls {
                Label(
                    "Hidden formatting characters were revealed in filenames.",
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Verification words")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(words.joined(separator: " · "))
                    .font(.headline.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Verification words: \(words.joined(separator: ", "))")
                Text("The other person sees the same four words. If they differ, stop.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            ForEach(names.prefix(10), id: \.self) { name in
                Text("• \(name)")
                    .font(.callout.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
            }

            AdaptiveAccessibilityStack(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                Button(role: .destructive) {
                    model.declineOffer()
                } label: {
                    Text("Decline")
                        .frame(maxWidth: .infinity, minHeight: minTapHeight)
                }
                .buttonStyle(.bordered)

                Button {
                    model.acceptOffer()
                } label: {
                    Text("Accept")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: minTapHeight)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func receivingProgressSection(percent: Int, summary: String, words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !words.isEmpty {
                Text(words.joined(separator: " · "))
                    .font(.subheadline.monospaced())
                    .accessibilityLabel("Verification words: \(words.joined(separator: ", "))")
            }
            ProgressView(value: Double(percent), total: 100.0) {
                Text("Receiving (\(percent)%)")
            } currentValueLabel: {
                Text(summary)
                    .font(.footnote.monospacedDigit())
            }
            Button(role: .destructive) {
                model.stopTransfer()
            } label: {
                Text("Stop")
                    .frame(maxWidth: .infinity, minHeight: minTapHeight)
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func finishedSection(message: String, receivedText: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Received and verified", systemImage: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            if let receivedText, !receivedText.isEmpty {
                Text(receivedText)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            Button {
                model.receiveCodeInput = ""
                model.phase = .idle
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity, minHeight: minTapHeight)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func failedSection(headline: String, cause: String?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(headline, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            if let cause {
                Text(cause)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Details") {
                Text(detail)
                    .font(.caption.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.phase = .idle
            } label: {
                Text("Try again")
                    .frame(maxWidth: .infinity, minHeight: minTapHeight)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
