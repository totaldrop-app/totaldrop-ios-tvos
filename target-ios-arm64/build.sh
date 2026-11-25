#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Physical iPhone & iPad (aarch64-apple-ios) build unit for TotalDrop on iOS/iPadOS.
# Produces libtotaldrop_apple_mobile_ffi.a and builds Swift 6 device targets via xcodebuild.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUST_TARGET="aarch64-apple-ios"

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"

echo "==> [ios-arm64] Building Rust C ABI FFI staticlib (${RUST_TARGET})"
rustup target add "${RUST_TARGET}"
cargo build \
  --manifest-path "${ROOT_DIR}/Cargo.toml" \
  --package totaldrop-apple-mobile-ffi \
  --target "${RUST_TARGET}" \
  --release \
  --locked

if [ "${SKIP_SWIFT_BUILD:-0}" != "1" ]; then
  echo "==> [ios-arm64] Building Swift 6 TotalDropIOS & ShareExtension against iphoneos SDK"
  (
    cd "${ROOT_DIR}/ui-swiftui-ios"
    xcodebuild build \
      -scheme TotalDropIOS \
      -destination "generic/platform=iOS" \
      -configuration Release \
      CODE_SIGNING_ALLOWED=NO
    xcodebuild build \
      -scheme ShareExtension \
      -destination "generic/platform=iOS" \
      -configuration Release \
      CODE_SIGNING_ALLOWED=NO
  )
fi

echo "==> [ios-arm64] Static library ready at ${ROOT_DIR}/target/${RUST_TARGET}/release/libtotaldrop_apple_mobile_ffi.a"
