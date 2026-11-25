# TotalDrop — Native iOS, iPadOS & Apple tvOS Module (`08-ios-and-tvos`)

Native **Swift 6 strict-concurrency** SwiftUI applications for **iOS / iPadOS** and **Apple tvOS** over the shared Rust protocol engine (`totaldrop-core`, `totaldrop-proto`, `totaldrop-crypto`, and `totaldrop-l10n`), linked through an audited C11 FFI static library & `TotalDropAppleMobileFFI.xcframework` for account-free CI compilation and live iPhone Simulator testing on pinned `macos-15` GitHub runners (**ADR 0009**, **ADR 0019**, **ADR 0020**).

## Architecture

| Component | Path | Responsibility |
| --- | --- | --- |
| Protocol, Crypto & Core | `crates/totaldrop-{proto,crypto,core,l10n}` | `#![forbid(unsafe_code)]` CPace PAKE, QUIC + Noise `XXpsk3` + ML-KEM-768 hybrid handshake, STREAM AEAD chunk framing, BLAKE3 verification, and 35-language ICU localization |
| Safe Apple Mobile Bridge | `crates/totaldrop-apple-mobile-bridge` | `#![forbid(unsafe_code)]` Rust bridge implementing Universal Links `/r#<code>` routing, iOS Share Extension security-scoped App Group manifests (`group.app.totaldrop.ios`), `BGContinuedProcessingTask` checkpoint metadata, tvOS 10-foot Siri Remote focus state, and Dynamic Type `accessibility5` strings |
| Audited C11 FFI Staticlib | `crates/totaldrop-apple-mobile-ffi` | Thin panic-guarded `extern "C"` boundary (`libtotaldrop_apple_mobile_ffi.a`, `totaldrop_apple_mobile_ffi.h`) running a 2-thread background Tokio runtime and monotonic `u64` NDJSON session streams (`unsafe_op_in_unsafe_fn = "deny"`, `undocumented_unsafe_blocks = "deny"`) |
| iOS & iPadOS SwiftUI | `ui-swiftui-ios/` | Swift 6 `TotalDropIOS` (`CTotalDropAppleMobileFFI`, live `RustMobileBridge`, `SendView`, `ReceiveView`, `BGTaskScheduler` background lifecycle, VoiceOver phonetic cues, Dynamic Type `.accessibility5`, opaque RGB `AppIcon-1024.png`), `ShareExtension`, and live iOS Simulator `TotalDropIOSTests` |
| Apple tvOS SwiftUI | `ui-swiftui-tvos/` | Swift 6 `TotalDropTV` (`CTotalDropAppleMobileFFI`, live `RustMobileBridge`, `TvReceiveView`, `TvSendView`, SwiftUI Focus Engine `@FocusState`, Siri Remote `.buttonStyle(.card)` directional cards, 10-foot QR pairing, `NSCachesDirectory` staging, and opaque RGB `AppIcon-tvOS-1280x768.png`) |
| Physical iOS Target | `target-ios-arm64/` | `aarch64-apple-ios` build script, `Info.plist` (`0.3.0-beta.6`, numeric `CFBundleVersion = 6`), and Associated Domains / App Group `entitlements.plist` |
| ARM64 iOS Simulator | `target-ios-sim-arm64/` | `aarch64-apple-ios-sim` build unit for pinned GitHub `macos-15` Apple Silicon runners |
| x86_64 iOS Simulator | `target-ios-sim-x86_64/` | `x86_64-apple-ios` simulator slice for Intel Macs and universal simulator XCFrameworks |
| Apple tvOS & XCFramework | `target-tvos-arm64/` | `Info.plist` (`0.3.0-beta.6`, numeric `CFBundleVersion = 6`), `aarch64-apple-tvos` + `aarch64-apple-tvos-sim` build unit, and `build-xcframework.sh` (`TotalDropAppleMobileFFI.xcframework` + `SHA256SUMS`) |

## Accessibility & Background Lifecycle

- **VoiceOver & Dynamic Type (`accessibility5`):** `AdaptiveAccessibilityStack` switches horizontal controls to full-width vertical stacks at `>= .accessibility1`, enforces `44pt`–`68pt` minimum tap targets, disables line truncation (`fixedSize(horizontal: false, vertical: true)`), and formats transfer codes (`7, harbor, rocket`) and 4-word verification phrases for clear VoiceOver speech via Rust.
- **Background Transfers:** Registers `app.totaldrop.ios.transfer` under `BGTaskSchedulerPermittedIdentifiers` and wires system expiration callbacks directly to `totaldrop_mobile_session_stop` (`totaldrop_core::Stop`).
- **tvOS 10-Foot Experience:** Uses native tvOS card focus, `onExitCommand` Menu button handling, `isIdleTimerDisabled` while pairing or transferring, and stages received files under `NSCachesDirectory/TotalDrop`.
- **App Store Kose Brand Assets:** `tools/render-apple-mobile-assets.py` deterministically generates strictly opaque RGB (PNG color type `2`, zero alpha channel) `AppIcon-1024.png` (1024×1024) and `AppIcon-tvOS-1280x768.png` (1280×768).

## Verification

Run the full Rust workspace lint, loopback C ABI E2E tests, and static asset/parity checks:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
python3 tools/check-versions.py
python3 tools/render-apple-mobile-assets.py --check
python3 tools/verify-xcframework.py --self-test
python3 tools/verify-subplatforms.py
./tools/check-spdx.sh
```

Assemble and natively verify `TotalDropAppleMobileFFI.xcframework` on macOS 15+:

```bash
./target-tvos-arm64/build-xcframework.sh --ios-only
python3 tools/verify-xcframework.py --xcframework dist/TotalDropAppleMobileFFI.xcframework --check-native
```

## License

- Application, SwiftUI packages, mobile bridge, and C ABI FFI crate (`crates/totaldrop-apple-mobile-{bridge,ffi}`, `ui-swiftui-*`, `target-*`): `GPL-3.0-or-later`
- Core protocol and localization libraries (`crates/totaldrop-{core,crypto,proto,l10n}`): `MIT OR Apache-2.0`
