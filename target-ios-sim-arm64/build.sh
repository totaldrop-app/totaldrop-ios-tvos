#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Apple Silicon iOS Simulator (aarch64-apple-ios-sim) build unit
# for account-free GitHub macOS ARM runners (`macos-15`, ADR 0009).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUST_TARGET="aarch64-apple-ios-sim"

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"

echo "==> [ios-sim-arm64] Building Rust C ABI FFI staticlib (${RUST_TARGET})"
rustup target add "${RUST_TARGET}"
cargo build \
  --manifest-path "${ROOT_DIR}/Cargo.toml" \
  --package totaldrop-apple-mobile-ffi \
  --target "${RUST_TARGET}" \
  --release \
  --locked

if [ "${SKIP_SWIFT_BUILD:-0}" != "1" ]; then
  echo "==> [ios-sim-arm64] Building Swift 6 TotalDropIOS for iOS Simulator (arm64)"
  (
    cd "${ROOT_DIR}/ui-swiftui-ios"
    xcodebuild build \
      -scheme TotalDropIOS \
      -destination "generic/platform=iOS Simulator" \
      ARCHS=arm64 \
      ONLY_ACTIVE_ARCH=NO \
      -configuration Release \
      CODE_SIGNING_ALLOWED=NO
  )
fi

echo "==> [ios-sim-arm64] Ready at ${ROOT_DIR}/target/${RUST_TARGET}/release/libtotaldrop_apple_mobile_ffi.a"
