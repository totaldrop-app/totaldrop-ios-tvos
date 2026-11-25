#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later

"""Version, C header, Info.plist, and ADR 0009 runner-pin guard for totaldrop-ios-tvos.

Enforces single-source parity across:
  - crates/totaldrop-apple-mobile-ffi/Cargo.toml (`APP_VERSION`) and `src/lib.rs` (`BUNDLE_VERSION`)
  - 3-way exact byte parity of `totaldrop_apple_mobile_ffi.h`:
      * crates/totaldrop-apple-mobile-ffi/include/totaldrop_apple_mobile_ffi.h
      * ui-swiftui-ios/Sources/CTotalDropAppleMobileFFI/include/totaldrop_apple_mobile_ffi.h
      * ui-swiftui-tvos/Sources/CTotalDropAppleMobileFFI/include/totaldrop_apple_mobile_ffi.h
  - target-ios-arm64/Info.plist and target-tvos-arm64/Info.plist
    (`CFBundleShortVersionString` == APP_VERSION, numeric `CFBundleVersion` == BUILD_NUMBER)
  - target-ios-*/build.sh and target-tvos-arm64/{build.sh,build-xcframework.sh}
  - all 6 subplatforms/*/*/RECIPE.toml and .github/workflows/pkg-*.yml (pinned macos-15 + Node 24 actions)
  - .github/workflows/ci.yml (pinned macos-15, zero unpinned macos-latest)
"""

from __future__ import annotations

import plistlib
import re
import sys
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

EXPECTED_APP_VERSION = "0.3.0-beta.6"
EXPECTED_BUILD_NUMBER = "6"
EXPECTED_CORE_VERSION = "0.2.0-beta.5"
EXPECTED_MACOS_RUNNER = "macos-15"
EXPECTED_UPLOAD_ARTIFACT_PIN = "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9"
EXPECTED_ATTEST_PIN = "actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8"


def fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def check_contains(rel_path: str, needle: str, label: str) -> None:
    p = REPO_ROOT / rel_path
    if not p.is_file():
        fail(f"missing {rel_path}")
    text = p.read_text(encoding="utf-8")
    if needle not in text:
        fail(f"{rel_path}: expected {label} ({needle!r})")


def main() -> int:
    # 1. Rust FFI crate version & monotonic numeric CFBundleVersion
    ffi_toml = tomllib.loads(
        (REPO_ROOT / "crates/totaldrop-apple-mobile-ffi/Cargo.toml").read_text(encoding="utf-8")
    )
    if ffi_toml["package"]["version"] != EXPECTED_APP_VERSION:
        fail(
            f"crates/totaldrop-apple-mobile-ffi/Cargo.toml version "
            f"{ffi_toml['package']['version']!r} != {EXPECTED_APP_VERSION!r}"
        )

    ws_toml = tomllib.loads((REPO_ROOT / "Cargo.toml").read_text(encoding="utf-8"))
    if ws_toml["workspace"]["package"]["version"] != EXPECTED_CORE_VERSION:
        fail(
            f"Cargo.toml workspace version {ws_toml['workspace']['package']['version']!r} "
            f"!= {EXPECTED_CORE_VERSION!r}"
        )

    lib_rs = (REPO_ROOT / "crates/totaldrop-apple-mobile-ffi/src/lib.rs").read_text(encoding="utf-8")
    m_bundle = re.search(r'pub const BUNDLE_VERSION: &str = "([^"]+)";', lib_rs)
    if not m_bundle or m_bundle.group(1) != EXPECTED_BUILD_NUMBER:
        fail(
            f"crates/totaldrop-apple-mobile-ffi/src/lib.rs BUNDLE_VERSION != {EXPECTED_BUILD_NUMBER!r}"
        )
    if not m_bundle.group(1).isdigit():
        fail("BUNDLE_VERSION must be strictly numeric for Apple CFBundleVersion")

    m_core = re.search(r'pub const CORE_VERSION: &str = "([^"]+)";', lib_rs)
    if not m_core or m_core.group(1) != EXPECTED_CORE_VERSION:
        fail(
            f"crates/totaldrop-apple-mobile-ffi/src/lib.rs CORE_VERSION != {EXPECTED_CORE_VERSION!r}"
        )

    # 2. 3-way C ABI header parity between Rust FFI crate, iOS SwiftPM C module, and tvOS SwiftPM C module
    rust_hdr = REPO_ROOT / "crates/totaldrop-apple-mobile-ffi/include/totaldrop_apple_mobile_ffi.h"
    ios_hdr = (
        REPO_ROOT
        / "ui-swiftui-ios/Sources/CTotalDropAppleMobileFFI/include/totaldrop_apple_mobile_ffi.h"
    )
    tvos_hdr = (
        REPO_ROOT
        / "ui-swiftui-tvos/Sources/CTotalDropAppleMobileFFI/include/totaldrop_apple_mobile_ffi.h"
    )
    for p in (rust_hdr, ios_hdr, tvos_hdr):
        if not p.is_file():
            fail(f"missing {p.relative_to(REPO_ROOT)}")
    rust_hdr_bytes = rust_hdr.read_bytes()
    if ios_hdr.read_bytes() != rust_hdr_bytes:
        fail("totaldrop_apple_mobile_ffi.h drifted between Rust FFI crate and ui-swiftui-ios")
    if tvos_hdr.read_bytes() != rust_hdr_bytes:
        fail("totaldrop_apple_mobile_ffi.h drifted between Rust FFI crate and ui-swiftui-tvos")

    # 3. Info.plist versions (CFBundleShortVersionString vs strictly numeric CFBundleVersion)
    for plist_rel in ("target-ios-arm64/Info.plist", "target-tvos-arm64/Info.plist"):
        plist_path = REPO_ROOT / plist_rel
        if not plist_path.is_file():
            fail(f"missing {plist_rel}")
        with plist_path.open("rb") as fh:
            plist_data = plistlib.load(fh)
        short_ver = str(plist_data.get("CFBundleShortVersionString", ""))
        bundle_ver = str(plist_data.get("CFBundleVersion", ""))
        if short_ver != EXPECTED_APP_VERSION:
            fail(f"{plist_rel}: CFBundleShortVersionString {short_ver!r} != {EXPECTED_APP_VERSION!r}")
        if bundle_ver != EXPECTED_BUILD_NUMBER or not bundle_ver.isdigit():
            fail(
                f"{plist_rel}: CFBundleVersion {bundle_ver!r} must equal strictly numeric "
                f"{EXPECTED_BUILD_NUMBER!r}"
            )

    # 4. Target build & XCFramework scripts reference totaldrop-apple-mobile-ffi
    for script_rel in (
        "target-ios-arm64/build.sh",
        "target-ios-sim-arm64/build.sh",
        "target-ios-sim-x86_64/build.sh",
        "target-tvos-arm64/build.sh",
        "target-tvos-arm64/build-xcframework.sh",
    ):
        check_contains(script_rel, "totaldrop-apple-mobile-ffi", "Rust FFI staticlib crate")

    # 5. All 6 subplatform units & workflows pinned to EXPECTED_APP_VERSION, macos-15, and Node 24 actions
    recipes = sorted((REPO_ROOT / "subplatforms").glob("*/*/RECIPE.toml"))
    if len(recipes) != 6:
        fail(f"expected 6 subplatform recipes, found {len(recipes)}")
    for recipe in recipes:
        data = tomllib.loads(recipe.read_text(encoding="utf-8"))
        if data["version"] != EXPECTED_APP_VERSION:
            fail(
                f"{recipe.relative_to(REPO_ROOT)}: version {data['version']!r} != {EXPECTED_APP_VERSION!r}"
            )
        if data["runner"] != EXPECTED_MACOS_RUNNER:
            fail(
                f"{recipe.relative_to(REPO_ROOT)}: runner {data['runner']!r} != {EXPECTED_MACOS_RUNNER!r}"
            )
        if EXPECTED_APP_VERSION not in data["artifact_name"]:
            fail(f"{recipe.relative_to(REPO_ROOT)}: artifact_name missing {EXPECTED_APP_VERSION}")

        wf_rel = data["workflow"]
        check_contains(wf_rel, f"runs-on: {EXPECTED_MACOS_RUNNER}", f"pinned {EXPECTED_MACOS_RUNNER}")
        check_contains(wf_rel, EXPECTED_APP_VERSION, f"artifact version {EXPECTED_APP_VERSION}")
        check_contains(wf_rel, EXPECTED_UPLOAD_ARTIFACT_PIN, "Node 24 upload-artifact v7.0.2 pin")
        check_contains(wf_rel, EXPECTED_ATTEST_PIN, "Node 24 attest-build-provenance v4.2.2 pin")
        wf_text = (REPO_ROOT / wf_rel).read_text(encoding="utf-8")
        if "macos-latest" in wf_text:
            fail(f"{wf_rel}: unpinned macos-latest violates ADR 0009")

    # 6. Main CI workflow pinned to macos-15 (ADR 0009)
    ci_text = (REPO_ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    if "macos-latest" in ci_text:
        fail(".github/workflows/ci.yml: unpinned macos-latest violates ADR 0009")
    if EXPECTED_MACOS_RUNNER not in ci_text:
        fail(f".github/workflows/ci.yml: missing pinned {EXPECTED_MACOS_RUNNER} runner")

    print(
        f"ios-tvos versions & parity OK: app={EXPECTED_APP_VERSION} "
        f"(CFBundleVersion={EXPECTED_BUILD_NUMBER}), core={EXPECTED_CORE_VERSION}, "
        f"runner={EXPECTED_MACOS_RUNNER}, 3-way header parity=exact, 6 subplatform units aligned."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
