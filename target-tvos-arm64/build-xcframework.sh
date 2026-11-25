#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Assembles `TotalDropAppleMobileFFI.xcframework` with the canonical C11 ABI
# header (`crates/totaldrop-apple-mobile-ffi/include/totaldrop_apple_mobile_ffi.h`),
# `module.modulemap`, and reproducible `SHA256SUMS`:
#   - iOS physical devices (`aarch64-apple-ios`)
#   - iOS universal simulator (`aarch64-apple-ios-sim` + `x86_64-apple-ios` via `lipo`)
#   - Optional (`--with-tvos`): tvOS device (`aarch64-apple-tvos`) + simulator (`aarch64-apple-tvos-sim`)
#
# Usage:
#   ./target-tvos-arm64/build-xcframework.sh --ios-only
#   ./target-tvos-arm64/build-xcframework.sh --with-tvos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
HEADERS_DIR="${DIST_DIR}/include"
XCFRAMEWORK_OUT="${DIST_DIR}/TotalDropAppleMobileFFI.xcframework"
LIB_NAME="libtotaldrop_apple_mobile_ffi.a"
HEADER_SRC="${ROOT_DIR}/crates/totaldrop-apple-mobile-ffi/include/totaldrop_apple_mobile_ffi.h"

INCLUDE_TVOS=1
SKIP_BUILD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --ios-only)
      INCLUDE_TVOS=0
      ;;
    --with-tvos)
      INCLUDE_TVOS=1
      ;;
    --skip-build)
      SKIP_BUILD=1
      ;;
    *)
      echo "usage: $0 [--ios-only|--with-tvos] [--skip-build]" >&2
      exit 2
      ;;
  esac
  shift
done

if [ ! -f "${HEADER_SRC}" ]; then
  echo "error: missing canonical C header ${HEADER_SRC}" >&2
  exit 1
fi

if [ "${SKIP_BUILD}" -eq 0 ]; then
  SKIP_SWIFT_BUILD=1 "${ROOT_DIR}/target-ios-arm64/build.sh"
  SKIP_SWIFT_BUILD=1 "${ROOT_DIR}/target-ios-sim-arm64/build.sh"
  SKIP_SWIFT_BUILD=1 "${ROOT_DIR}/target-ios-sim-x86_64/build.sh"
  if [ "${INCLUDE_TVOS}" -eq 1 ]; then
    SKIP_SWIFT_BUILD=1 "${ROOT_DIR}/target-tvos-arm64/build.sh"
  fi
fi

mkdir -p "${DIST_DIR}/ios-sim-universal" "${HEADERS_DIR}"

echo "==> Merging iOS simulator arm64 + x86_64 slices with lipo"
lipo -create \
  -output "${DIST_DIR}/ios-sim-universal/${LIB_NAME}" \
  "${ROOT_DIR}/target/aarch64-apple-ios-sim/release/${LIB_NAME}" \
  "${ROOT_DIR}/target/x86_64-apple-ios/release/${LIB_NAME}"

cp "${HEADER_SRC}" "${HEADERS_DIR}/totaldrop_apple_mobile_ffi.h"

# REUSE-IgnoreStart
cat > "${HEADERS_DIR}/module.modulemap" <<'EOF'
// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

module CTotalDropAppleMobileFFI {
    header "totaldrop_apple_mobile_ffi.h"
    export *
}
EOF
# REUSE-IgnoreEnd

rm -rf "${XCFRAMEWORK_OUT}"
XCF_ARGS=(
  -library "${ROOT_DIR}/target/aarch64-apple-ios/release/${LIB_NAME}"
  -headers "${HEADERS_DIR}"
  -library "${DIST_DIR}/ios-sim-universal/${LIB_NAME}"
  -headers "${HEADERS_DIR}"
)

if [ "${INCLUDE_TVOS}" -eq 1 ]; then
  XCF_ARGS+=(
    -library "${ROOT_DIR}/target/aarch64-apple-tvos/release/${LIB_NAME}"
    -headers "${HEADERS_DIR}"
    -library "${ROOT_DIR}/target/aarch64-apple-tvos-sim/release/${LIB_NAME}"
    -headers "${HEADERS_DIR}"
  )
fi

xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "${XCFRAMEWORK_OUT}"

(
  cd "${DIST_DIR}"
  find TotalDropAppleMobileFFI.xcframework -type f | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS
)

echo "==> Created ${XCFRAMEWORK_OUT} and ${DIST_DIR}/SHA256SUMS"
