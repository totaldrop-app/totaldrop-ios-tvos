#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Intel iOS Simulator (x86_64-apple-ios) build unit for universal simulator XCFrameworks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUST_TARGET="x86_64-apple-ios"

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"

echo "==> [ios-sim-x86_64] Building Rust C ABI FFI staticlib (${RUST_TARGET})"
rustup target add "${RUST_TARGET}"
cargo build \
  --manifest-path "${ROOT_DIR}/Cargo.toml" \
  --package totaldrop-apple-mobile-ffi \
  --target "${RUST_TARGET}" \
  --release \
  --locked

if [ "${SKIP_SWIFT_BUILD:-0}" != "1" ]; then
  echo "==> [ios-sim-x86_64] Building Swift 6 TotalDropIOS for iOS Simulator (x86_64)"
  (
    cd "${ROOT_DIR}/ui-swiftui-ios"
    xcodebuild build \
      -scheme TotalDropIOS \
      -destination "generic/platform=iOS Simulator" \
      ARCHS=x86_64 \
      ONLY_ACTIVE_ARCH=NO \
      -configuration Release \
      CODE_SIGNING_ALLOWED=NO
  )
fi

echo "==> [ios-sim-x86_64] Ready at ${ROOT_DIR}/target/${RUST_TARGET}/release/libtotaldrop_apple_mobile_ffi.a"
