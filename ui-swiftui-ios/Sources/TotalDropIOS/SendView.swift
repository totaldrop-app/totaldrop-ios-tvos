// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Native iOS/iPadOS SwiftUI Send screen with full VoiceOver hints and Dynamic Type
/// layout scaling up to `.accessibility5`.
public struct SendView: View {
    @Bindable var model: IOSAppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingFilePicker = false

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
                case .waitingForPeer(let code, let link, let spokenCode, let shareMessage):
                    waitingCodeCard(
                        code: code,
                        universalLink: link,
                        spokenCode: spokenCode,
                        shareMessage: shareMessage
                    )
                case .transferring(let isSending, let percent, let summary, let words) where isSending:
                    progressCard(percent: percent, summary: summary, words: words)
                case .finished(let message, _):
                    doneCard(message: message)
                case .failed(let headline, let cause, let detail):
                    errorCard(headline: headline, cause: cause, detail: detail)
                default:
                    selectionSection
                }
            }
            .padding()
        }
        .navigationTitle("Send files")
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.selectedURLs.append(contentsOf: urls)
            }
        }
    }

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.selectedURLs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.up.doc")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Nothing selected yet")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Add the files you want to send. The receiver gets exactly these, nothing else.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else {
                ForEach(model.selectedURLs, id: \.self) { url in
                    let safeName = model.displayFilename(for: url)
                    AdaptiveAccessibilityStack(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                        Text(safeName)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            model.selectedURLs.removeAll { $0 == url }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .frame(minHeight: minTapHeight)
                        .accessibilityLabel("Remove \(safeName)")
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }

            Toggle(isOn: $model.strongerCode) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stronger code")
                        .font(.body)
                    Text("Three words instead of two: much harder to guess")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: minTapHeight)

            Button {
                showingFilePicker = true
            } label: {
                Label("Add files", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: minTapHeight)
            }
            .buttonStyle(.bordered)

            Button {
                model.startSend()
            } label: {
                Text("Create code")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: minTapHeight)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedURLs.isEmpty)
            .accessibilityHint("Generates an encrypted one-time code for the selected files")
        }
    }

    private func waitingCodeCard(
        code: String,
        universalLink: String,
        spokenCode: String,
        shareMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your code")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(code)
                .font(.system(.title, design: .monospaced).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Transfer code: \(spokenCode)")

            Text("On the other device, open TotalDrop, tap Receive and enter this code.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            #if canImport(UIKit)
            if let qr = Self.generateQRImage(payload: universalLink) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 240 : 180)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("QR code for transfer code \(spokenCode)")
            }
            #endif

            AdaptiveAccessibilityStack(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
                if let url = URL(string: universalLink) {
                    ShareLink(
                        item: url,
                        message: Text(shareMessage.isEmpty ? "Get my files with TotalDrop. Code: \(code)" : shareMessage)
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: minTapHeight)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(role: .destructive) {
                    model.stopTransfer()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity, minHeight: minTapHeight)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func progressCard(percent: Int, summary: String, words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !words.isEmpty {
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
            }

            ProgressView(value: Double(percent), total: 100.0) {
                Text("Sending (\(percent)%)")
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

    private func doneCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Sent and verified", systemImage: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.selectedURLs.removeAll()
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

    private func errorCard(headline: String, cause: String?, detail: String) -> some View {
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

    #if canImport(UIKit)
    static func generateQRImage(payload: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 7, y: 7))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    #endif
}
