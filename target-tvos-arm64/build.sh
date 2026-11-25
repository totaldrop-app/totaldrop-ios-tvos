#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Apple tvOS 4K device (aarch64-apple-tvos) and Apple Silicon tvOS Simulator
# (aarch64-apple-tvos-sim) build unit.
#
# Note: Apple tvOS targets are Tier 3 in upstream rustc, so `rust-src` +
# `-Z build-std=std,panic_abort` is used when prebuilt std components are absent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

export TVOS_DEPLOYMENT_TARGET="${TVOS_DEPLOYMENT_TARGET:-18.0}"

build_tvos_slice() {
  local target="$1"
  echo "==> [tvos] Building Rust C ABI FFI staticlib (${target})"
  if rustup target add "${target}" 2>/dev/null; then
    cargo build \
      --manifest-path "${ROOT_DIR}/Cargo.toml" \
      --package totaldrop-apple-mobile-ffi \
      --target "${target}" \
      --release \
      --locked
  else
    # Tier-3 fallback using rust-src for stdlib synthesis on tvOS.
    RUSTUP_TOOLCHAIN="${TVOS_BUILD_STD_TOOLCHAIN:-nightly}" cargo build \
      -Z build-std=std,panic_abort \
      --manifest-path "${ROOT_DIR}/Cargo.toml" \
      --package totaldrop-apple-mobile-ffi \
      --target "${target}" \
      --release \
      --locked
  fi
}

build_tvos_slice "aarch64-apple-tvos"
build_tvos_slice "aarch64-apple-tvos-sim"

if [ "${SKIP_SWIFT_BUILD:-0}" != "1" ]; then
  echo "==> [tvos] Building Swift 6 TotalDropTV for appletvos and appletvsimulator"
  (
    cd "${ROOT_DIR}/ui-swiftui-tvos"
    xcodebuild build \
      -scheme TotalDropTV \
      -destination "generic/platform=tvOS" \
      -configuration Release \
      CODE_SIGNING_ALLOWED=NO
    xcodebuild build \
      -scheme TotalDropTV \
      -destination "generic/platform=tvOS Simulator" \
      -configuration Release \
      CODE_SIGNING_ALLOWED=NO
  )
fi
