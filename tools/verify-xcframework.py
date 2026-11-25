#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later

"""Structural and native binary verifier for `TotalDropAppleMobileFFI.xcframework`.

Validates:
  - XCFramework `Info.plist` format (`CFBundlePackageType == XFWK`,
    `XCFrameworkFormatVersion == 1.0`)
  - Required library slices (`ios-arm64`, `ios-arm64_x86_64-simulator`, plus
    optional `tvos-arm64` / `tvos-arm64-simulator` when `--require-tvos` is set)
  - Exact byte parity of every slice's `Headers/totaldrop_apple_mobile_ffi.h`
    with `crates/totaldrop-apple-mobile-ffi/include/totaldrop_apple_mobile_ffi.h`
  - Presence of `Headers/module.modulemap` declaring `TotalDropAppleMobileFFI`
  - Optional `--check-native` (macOS): `lipo -archs` per slice and `nm -gU`
    symbol verification for core `totaldrop_mobile_*` C ABI exports
  - `--self-test` mode runnable on Linux and macOS CI runners

Usage:
  python3 tools/verify-xcframework.py --self-test
  python3 tools/verify-xcframework.py --xcframework dist/TotalDropAppleMobileFFI.xcframework --check-native
"""

from __future__ import annotations

import argparse
import plistlib
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CANONICAL_HEADER = (
    REPO_ROOT / "crates" / "totaldrop-apple-mobile-ffi" / "include" / "totaldrop_apple_mobile_ffi.h"
)
LIB_NAME = "libtotaldrop_apple_mobile_ffi.a"

REQUIRED_EXPORTED_SYMBOLS: tuple[str, ...] = (
    "totaldrop_mobile_string_free",
    "totaldrop_mobile_version_json",
    "totaldrop_mobile_ui_bundle_json",
    "totaldrop_mobile_handle_url_json",
    "totaldrop_mobile_extract_clipboard_code_json",
    "totaldrop_mobile_voiceover_code_json",
    "totaldrop_mobile_parse_share_manifest_json",
    "totaldrop_mobile_parse_checkpoint_json",
    "totaldrop_mobile_sanitize_filename_json",
    "totaldrop_mobile_sanitize_text_json",
    "totaldrop_mobile_format_progress_json",
    "totaldrop_mobile_session_start_send_files",
    "totaldrop_mobile_session_start_send_text",
    "totaldrop_mobile_session_start_receive",
    "totaldrop_mobile_session_accept_offer",
    "totaldrop_mobile_session_decline_offer",
    "totaldrop_mobile_session_stop",
    "totaldrop_mobile_session_poll_events_ndjson",
    "totaldrop_mobile_session_destroy",
)


def _normalize_darwin_symbol(raw: str) -> str:
    return raw[1:] if raw.startswith("_") else raw


def parse_nm_exported_symbols(nm_stdout: str) -> set[str]:
    """Extract defined external C symbol names (stripping Darwin leading `_`) from `nm -g` output."""
    symbols: set[str] = set()
    for raw_line in nm_stdout.splitlines():
        line = raw_line.strip()
        if not line or line.endswith(":"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        sym_type = parts[-2]
        if len(sym_type) != 1 or not sym_type.isupper() or sym_type == "U":
            continue
        symbols.add(_normalize_darwin_symbol(parts[-1]))
    return symbols


def parse_darwin_archive_symdef(archive_bytes: bytes) -> set[str]:
    """Read exported external symbols from a single-arch Darwin BSD `__.SYMDEF` archive table."""
    if not archive_bytes.startswith(b"!<arch>\n"):
        return set()
    offset = 8
    while offset + 60 <= len(archive_bytes):
        header = archive_bytes[offset : offset + 60]
        if header[58:60] != b"`\n":
            break
        raw_name = header[0:16].decode("ascii", errors="replace").rstrip(" ")
        size_str = header[48:58].decode("ascii", errors="replace").strip()
        try:
            member_size = int(size_str)
        except ValueError:
            break
        data_start = offset + 60
        data_end = data_start + member_size
        if data_end > len(archive_bytes):
            break
        member_data = archive_bytes[data_start:data_end]
        member_name = raw_name
        if raw_name.startswith("#1/"):
            try:
                ext_len = int(raw_name[3:])
            except ValueError:
                ext_len = 0
            if 0 < ext_len <= len(member_data):
                member_name = (
                    member_data[:ext_len].split(b"\x00", 1)[0].decode("ascii", errors="replace")
                )
                member_data = member_data[ext_len:]
        if member_name in ("__.SYMDEF", "__.SYMDEF SORTED", "__.SYMDEF_64", "__.SYMDEF_64 SORTED"):
            is_64 = "_64" in member_name
            fmt = "<Q" if is_64 else "<I"
            word = 8 if is_64 else 4
            if len(member_data) < word:
                return set()
            ranlib_bytes = struct.unpack_from(fmt, member_data, 0)[0]
            strtab_len_off = word + ranlib_bytes
            if strtab_len_off + word > len(member_data):
                return set()
            strtab_size = struct.unpack_from(fmt, member_data, strtab_len_off)[0]
            strtab_start = strtab_len_off + word
            strtab = member_data[strtab_start : strtab_start + strtab_size]
            symbols: set[str] = set()
            for entry in strtab.split(b"\x00"):
                if not entry:
                    continue
                symbols.add(_normalize_darwin_symbol(entry.decode("utf-8", errors="replace")))
            return symbols
        offset = data_end + (data_end & 1)
    return set()


def _extract_native_slice_symbols(
    lib_path: Path, arch: str, is_fat: bool
) -> tuple[set[str], str]:
    with tempfile.TemporaryDirectory() as tmp:
        inspect_path = lib_path
        if is_fat:
            inspect_path = Path(tmp) / f"{arch}-{lib_path.name}"
            subprocess.check_call(
                ["lipo", "-thin", arch, str(lib_path), "-output", str(inspect_path)]
            )

        symdef_syms = parse_darwin_archive_symdef(inspect_path.read_bytes())
        nm_proc = subprocess.run(
            ["xcrun", "nm", "-g", str(inspect_path)],
            text=True,
            capture_output=True,
            check=False,
        )
        nm_syms = parse_nm_exported_symbols(nm_proc.stdout)
        exported = symdef_syms | nm_syms
        diag = (
            f"symdef={len(symdef_syms)}, nm={len(nm_syms)}, "
            f"nm_rc={nm_proc.returncode}, nm_stderr={nm_proc.stderr.strip()[:240]!r}"
        )
        return exported, diag


def verify_xcframework(
    xcframework_path: Path,
    *,
    require_tvos: bool = False,
    check_native: bool = False,
) -> list[str]:
    if not xcframework_path.is_dir():
        raise ValueError(f"missing XCFramework directory: {xcframework_path}")
    info_plist = xcframework_path / "Info.plist"
    if not info_plist.is_file():
        raise ValueError(f"missing Info.plist inside {xcframework_path}")
    if not CANONICAL_HEADER.is_file():
        raise ValueError(f"missing canonical C header at {CANONICAL_HEADER}")
    canonical_header_bytes = CANONICAL_HEADER.read_bytes()

    with info_plist.open("rb") as fh:
        plist = plistlib.load(fh)

    if plist.get("CFBundlePackageType") != "XFWK":
        raise ValueError(f"Info.plist CFBundlePackageType {plist.get('CFBundlePackageType')!r} != 'XFWK'")
    if str(plist.get("XCFrameworkFormatVersion", "")) != "1.0":
        raise ValueError(
            f"Info.plist XCFrameworkFormatVersion {plist.get('XCFrameworkFormatVersion')!r} != '1.0'"
        )

    available = plist.get("AvailableLibraries")
    if not isinstance(available, list) or not available:
        raise ValueError("Info.plist AvailableLibraries must be a non-empty list")

    by_id: dict[str, dict] = {}
    for entry in available:
        if not isinstance(entry, dict):
            raise ValueError("AvailableLibraries entry must be a dict")
        lib_id = str(entry.get("LibraryIdentifier", ""))
        if not lib_id:
            raise ValueError("AvailableLibraries entry missing LibraryIdentifier")
        by_id[lib_id] = entry

    expected_slices: dict[str, set[str]] = {
        "ios-arm64": {"arm64"},
        "ios-arm64_x86_64-simulator": {"arm64", "x86_64"},
    }
    if require_tvos:
        expected_slices["tvos-arm64"] = {"arm64"}
        expected_slices["tvos-arm64-simulator"] = {"arm64"}

    verified_slices: list[str] = []
    for slice_id, expected_archs in expected_slices.items():
        if slice_id not in by_id:
            raise ValueError(f"missing required XCFramework slice {slice_id!r}")
        entry = by_id[slice_id]
        declared_archs = set(entry.get("SupportedArchitectures") or [])
        if declared_archs != expected_archs:
            raise ValueError(
                f"slice {slice_id}: SupportedArchitectures {sorted(declared_archs)} != {sorted(expected_archs)}"
            )

        lib_rel = entry.get("LibraryPath")
        headers_rel = entry.get("HeadersPath")
        if not lib_rel or not headers_rel:
            raise ValueError(f"slice {slice_id}: missing LibraryPath or HeadersPath")

        slice_dir = xcframework_path / slice_id
        lib_path = slice_dir / lib_rel
        headers_dir = slice_dir / headers_rel
        if not lib_path.is_file() or lib_path.stat().st_size == 0:
            raise ValueError(f"slice {slice_id}: missing or empty static library {lib_path}")
        if lib_path.name != LIB_NAME:
            raise ValueError(f"slice {slice_id}: library name {lib_path.name!r} != {LIB_NAME!r}")

        hdr_path = headers_dir / "totaldrop_apple_mobile_ffi.h"
        if not hdr_path.is_file():
            raise ValueError(f"slice {slice_id}: missing header {hdr_path}")
        if hdr_path.read_bytes() != canonical_header_bytes:
            raise ValueError(f"slice {slice_id}: totaldrop_apple_mobile_ffi.h drifted from Rust crate")

        modulemap_path = headers_dir / "module.modulemap"
        if not modulemap_path.is_file():
            raise ValueError(f"slice {slice_id}: missing module.modulemap")
        mm_text = modulemap_path.read_text(encoding="utf-8")
        if "totaldrop_apple_mobile_ffi.h" not in mm_text:
            raise ValueError(f"slice {slice_id}: module.modulemap does not reference totaldrop_apple_mobile_ffi.h")

        if check_native:
            lipo_out = subprocess.check_output(
                ["lipo", "-archs", str(lib_path)], text=True
            ).strip()
            actual_archs = set(lipo_out.split())
            if actual_archs != expected_archs:
                raise ValueError(
                    f"slice {slice_id}: lipo -archs {sorted(actual_archs)} != {sorted(expected_archs)}"
                )

            is_fat = len(expected_archs) > 1
            for arch in sorted(expected_archs):
                exported, diag = _extract_native_slice_symbols(lib_path, arch, is_fat)
                if not exported:
                    raise ValueError(
                        f"slice {slice_id} ({arch}): no exported symbols found ({diag})"
                    )
                missing_syms = [s for s in REQUIRED_EXPORTED_SYMBOLS if s not in exported]
                if missing_syms:
                    raise ValueError(
                        f"slice {slice_id} ({arch}): missing exported C ABI symbols: "
                        f"{', '.join(missing_syms)} ({diag})"
                    )

        verified_slices.append(f"{slice_id}({','.join(sorted(expected_archs))})")

    return verified_slices


def write_synthetic_xcframework(root: Path) -> Path:
    xf = root / "TotalDropAppleMobileFFI.xcframework"
    header_bytes = CANONICAL_HEADER.read_bytes()
    modulemap_text = (
        "module CTotalDropAppleMobileFFI {\n"
        '    header "totaldrop_apple_mobile_ffi.h"\n'
        "    export *\n"
        "}\n"
    )
    libraries = [
        {
            "BinaryPath": LIB_NAME,
            "HeadersPath": "Headers",
            "LibraryIdentifier": "ios-arm64",
            "LibraryPath": LIB_NAME,
            "SupportedArchitectures": ["arm64"],
            "SupportedPlatform": "ios",
        },
        {
            "BinaryPath": LIB_NAME,
            "HeadersPath": "Headers",
            "LibraryIdentifier": "ios-arm64_x86_64-simulator",
            "LibraryPath": LIB_NAME,
            "SupportedArchitectures": ["arm64", "x86_64"],
            "SupportedPlatform": "ios",
            "SupportedPlatformVariant": "simulator",
        },
    ]
    for entry in libraries:
        sdir = xf / entry["LibraryIdentifier"]
        hdir = sdir / "Headers"
        hdir.mkdir(parents=True, exist_ok=True)
        (sdir / LIB_NAME).write_bytes(b"!<arch>\nsynthetic-test-staticlib\n")
        (hdir / "totaldrop_apple_mobile_ffi.h").write_bytes(header_bytes)
        (hdir / "module.modulemap").write_text(modulemap_text, encoding="utf-8")

    with (xf / "Info.plist").open("wb") as fh:
        plistlib.dump(
            {
                "AvailableLibraries": libraries,
                "CFBundlePackageType": "XFWK",
                "XCFrameworkFormatVersion": "1.0",
            },
            fh,
        )
    return xf


def _build_synthetic_darwin_symdef_archive(symbols: list[str], *, use_64: bool = False) -> bytes:
    member_name = b"__.SYMDEF_64 SORTED\x00" if use_64 else b"__.SYMDEF SORTED\x00\x00\x00\x00"
    strtab = b"".join(s.encode("utf-8") + b"\x00" for s in symbols)
    while len(strtab) % 4 != 0:
        strtab += b"\x00"
    fmt = "<Q" if use_64 else "<I"
    ranlib = struct.pack(fmt, 0)
    payload = member_name + ranlib + struct.pack(fmt, len(strtab)) + strtab
    name_field = f"#1/{len(member_name)}".ljust(16).encode("ascii")
    header = (
        name_field
        + b"0           0     0     100644  "
        + f"{len(payload):<10}".encode("ascii")
        + b"`\n"
    )
    return b"!<arch>\n" + header + payload


def run_self_test() -> int:
    # 1. Test nm -g symbol parser (filtering undefined U and local lowercase symbols).
    sample_nm = (
        "\nlibtotaldrop_apple_mobile_ffi.a(ffi.o) (for architecture arm64):\n"
        "                 U _malloc\n"
        "0000000000000050 t _private_helper\n"
        "0000000000000100 T _totaldrop_mobile_version_json\n"
        "0000000000000200 T _totaldrop_mobile_string_free\n"
        "\nlibtotaldrop_apple_mobile_ffi.a(ffi.o) (for architecture x86_64):\n"
        "0000000000000100 T _totaldrop_mobile_session_destroy\n"
    )
    parsed = parse_nm_exported_symbols(sample_nm)
    assert "totaldrop_mobile_version_json" in parsed
    assert "totaldrop_mobile_string_free" in parsed
    assert "totaldrop_mobile_session_destroy" in parsed
    assert "malloc" not in parsed
    assert "private_helper" not in parsed

    # 2. Test Darwin __.SYMDEF and __.SYMDEF_64 archive index parsers.
    for use_64 in (False, True):
        archive = _build_synthetic_darwin_symdef_archive(
            ["_totaldrop_mobile_version_json", "_totaldrop_mobile_string_free"],
            use_64=use_64,
        )
        symdef = parse_darwin_archive_symdef(archive)
        assert symdef == {"totaldrop_mobile_version_json", "totaldrop_mobile_string_free"}, (
            f"unexpected symdef (64={use_64}): {symdef}"
        )

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        xf = write_synthetic_xcframework(tmp_path)
        slices = verify_xcframework(xf, require_tvos=False, check_native=False)
        assert len(slices) == 2

        # 3. Tamper header -> must fail.
        bad_hdr = xf / "ios-arm64" / "Headers" / "totaldrop_apple_mobile_ffi.h"
        orig_hdr = bad_hdr.read_bytes()
        bad_hdr.write_bytes(orig_hdr + b"\n/* drifted */\n")
        try:
            verify_xcframework(xf, require_tvos=False, check_native=False)
            raise AssertionError("expected drifted header to fail")
        except ValueError as err:
            assert "drifted" in str(err)
        bad_hdr.write_bytes(orig_hdr)

        # 4. Require tvOS when only iOS slices exist -> must fail.
        try:
            verify_xcframework(xf, require_tvos=True, check_native=False)
            raise AssertionError("expected missing tvos slice to fail")
        except ValueError as err:
            assert "tvos-arm64" in str(err)

    print("verify-xcframework.py --self-test OK (structural, header parity, tvOS gate, nm & __.SYMDEF parsers).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="Run built-in unit self-test")
    parser.add_argument("--xcframework", type=Path, help="Path to TotalDropAppleMobileFFI.xcframework")
    parser.add_argument(
        "--require-tvos",
        action="store_true",
        help="Also require tvos-arm64 and tvos-arm64-simulator slices",
    )
    parser.add_argument(
        "--check-native",
        action="store_true",
        help="Run macOS lipo -archs and nm -gU symbol verification on static libraries",
    )
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    if not args.xcframework:
        parser.error("either --self-test or --xcframework is required")

    try:
        slices = verify_xcframework(
            args.xcframework,
            require_tvos=args.require_tvos,
            check_native=args.check_native,
        )
    except ValueError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1

    native_note = " + native lipo/nm verified" if args.check_native else ""
    print(f"XCFramework OK ({args.xcframework}): slices={', '.join(slices)}{native_note}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
