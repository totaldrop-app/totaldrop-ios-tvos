#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later

"""Deterministic pure-stdlib generator and verifier for TotalDrop iOS & tvOS Kose icons.

Renders the canonical Kose brand geometry (`M55 15H97V57A42 42 0 1 1 55 15Z`,
ADR 0012) over the full-bleed TotalDrop violet gradient into strictly opaque
RGB PNG assets (PNG color type 2, zero alpha channel — required by Apple App
Store Connect for iOS and tvOS icons):
  - ui-swiftui-ios/Resources/AppIcon-1024.png (1024x1024 opaque RGB)
  - ui-swiftui-tvos/Resources/AppIcon-tvOS-1280x768.png (1280x768 opaque RGB)

Zero third-party dependencies (runs identically on Linux and macOS CI runners).

Usage:
  python3 tools/render-apple-mobile-assets.py --write
  python3 tools/render-apple-mobile-assets.py --check
"""

from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
IOS_ICON_PATH = REPO_ROOT / "ui-swiftui-ios" / "Resources" / "AppIcon-1024.png"
TVOS_ICON_PATH = REPO_ROOT / "ui-swiftui-tvos" / "Resources" / "AppIcon-tvOS-1280x768.png"

# Canonical Kose SVG mark geometry (112x112 viewBox) and brand palette (ADR 0012).
VIEWBOX = 112.0
CIRCLE_CX = 55.0
CIRCLE_CY = 57.0
CIRCLE_R = 42.0
CORNER_X_MIN = 55.0
CORNER_X_MAX = 97.0
CORNER_Y_MIN = 15.0
CORNER_Y_MAX = 57.0

# Brand colors (sRGB)
VIOLET_TOP = (0x7B, 0x58, 0xEC)
VIOLET_BOT = (0x5D, 0x3B, 0xCE)
PAPER_RGB = (0xF4, 0xF2, 0xFB)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_COLOR_TYPE_RGB = 2


def png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)


def encode_rgb_png(width: int, height: int, rgb_rows: list[bytes]) -> bytes:
    """Encode a deterministic opaque 8-bit RGB PNG (color type 2, no alpha)."""
    ihdr = struct.pack(">IIBBBBB", width, height, 8, PNG_COLOR_TYPE_RGB, 0, 0, 0)
    raw = bytearray()
    for row in rgb_rows:
        raw.append(0)  # Filter type 0 (None)
        raw.extend(row)
    idat = zlib.compress(bytes(raw), level=9)
    return (
        PNG_SIGNATURE
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", idat)
        + png_chunk(b"IEND", b"")
    )


def render_kose_rgb_png(width: int, height: int, mark_fraction: float) -> bytes:
    """Analytically render the Kose mark onto a full-bleed opaque RGB gradient canvas.

    Uses fast bounding-box culling outside the mark footprint and 2x2 analytical
    supersampling only along the mark area so pure-Python rendering completes in
    under a second while remaining crisp and byte-deterministic.
    """
    ss = 2
    inv_ss = 1.0 / ss
    inv_samples = 1.0 / (ss * ss)

    cx = width * 0.5
    cy = height * 0.5
    mark_span = min(width, height) * mark_fraction
    scale_to_vb = VIEWBOX / mark_span
    vb_half = VIEWBOX * 0.5
    r_sq = CIRCLE_R * CIRCLE_R

    # Conservative pixel bounding box of the mark (with 2px margin for antialiasing).
    vb_min = min(CIRCLE_CX - CIRCLE_R, CORNER_X_MIN)
    vb_max = max(CIRCLE_CX + CIRCLE_R, CORNER_X_MAX)
    y_vb_min = min(CIRCLE_CY - CIRCLE_R, CORNER_Y_MIN)
    y_vb_max = max(CIRCLE_CY + CIRCLE_R, CORNER_Y_MAX)

    x_start = max(0, int(cx + (vb_min - vb_half) / scale_to_vb) - 2)
    x_end = min(width, int(cx + (vb_max - vb_half) / scale_to_vb) + 3)
    y_start = max(0, int(cy + (y_vb_min - vb_half) / scale_to_vb) - 2)
    y_end = min(height, int(cy + (y_vb_max - vb_half) / scale_to_vb) + 3)

    rows: list[bytes] = []
    inv_h = 1.0 / max(1, height - 1)

    for y in range(height):
        ty = y * inv_h
        bg_r = VIOLET_TOP[0] + (VIOLET_BOT[0] - VIOLET_TOP[0]) * ty
        bg_g = VIOLET_TOP[1] + (VIOLET_BOT[1] - VIOLET_TOP[1]) * ty
        bg_b = VIOLET_TOP[2] + (VIOLET_BOT[2] - VIOLET_TOP[2]) * ty

        br = min(255, max(0, int(round(bg_r))))
        bg = min(255, max(0, int(round(bg_g))))
        bb = min(255, max(0, int(round(bg_b))))

        bg_pixel = bytes((br, bg, bb))
        if y < y_start or y >= y_end:
            rows.append(bg_pixel * width)
            continue

        row = bytearray(bg_pixel * width)
        # Precompute y sub-samples for this scanline.
        sub_y = []
        for sy in range(ss):
            py = y + (sy + 0.5) * inv_ss
            vy = (py - cy) * scale_to_vb + vb_half
            dy = vy - CIRCLE_CY
            sub_y.append((dy * dy, CORNER_Y_MIN <= vy <= CORNER_Y_MAX))

        for x in range(x_start, x_end):
            mark_hits = 0
            for sx in range(ss):
                px = x + (sx + 0.5) * inv_ss
                vx = (px - cx) * scale_to_vb + vb_half
                dx = vx - CIRCLE_CX
                dx_sq = dx * dx
                in_corner_x = CORNER_X_MIN <= vx <= CORNER_X_MAX
                for dy_sq, in_corner_y in sub_y:
                    if (in_corner_x and in_corner_y) or (dx_sq + dy_sq <= r_sq):
                        mark_hits += 1

            if mark_hits == 0:
                continue

            if mark_hits == ss * ss:
                off = x * 3
                row[off] = PAPER_RGB[0]
                row[off + 1] = PAPER_RGB[1]
                row[off + 2] = PAPER_RGB[2]
            else:
                cov = mark_hits * inv_samples
                inv_cov = 1.0 - cov
                off = x * 3
                row[off] = min(255, max(0, int(round(bg_r * inv_cov + PAPER_RGB[0] * cov))))
                row[off + 1] = min(255, max(0, int(round(bg_g * inv_cov + PAPER_RGB[1] * cov))))
                row[off + 2] = min(255, max(0, int(round(bg_b * inv_cov + PAPER_RGB[2] * cov))))

        rows.append(bytes(row))

    return encode_rgb_png(width, height, rows)


def verify_opaque_rgb_png(data: bytes, expected_w: int, expected_h: int, label: str) -> None:
    """Verify PNG signature, IHDR dimensions, 8-bit depth, and opaque RGB color type."""
    if not data.startswith(PNG_SIGNATURE) or len(data) < 33:
        raise ValueError(f"{label}: invalid or truncated PNG header")
    ihdr_len = struct.unpack(">I", data[8:12])[0]
    ihdr_type = data[12:16]
    if ihdr_type != b"IHDR" or ihdr_len != 13:
        raise ValueError(f"{label}: missing valid IHDR chunk")
    w, h, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(
        ">IIBBBBB", data[16:29]
    )
    if (w, h) != (expected_w, expected_h):
        raise ValueError(f"{label}: dimensions {(w, h)} != {(expected_w, expected_h)}")
    if bit_depth != 8:
        raise ValueError(f"{label}: bit depth {bit_depth} != 8")
    if color_type != PNG_COLOR_TYPE_RGB:
        raise ValueError(
            f"{label}: PNG color type {color_type} != 2 (opaque RGB required by App Store Connect; no alpha channel)"
        )
    if (compression, filter_method, interlace) != (0, 0, 0):
        raise ValueError(f"{label}: unexpected PNG compression/filter/interlace settings")


ASSETS: tuple[tuple[Path, int, int, float], ...] = (
    (IOS_ICON_PATH, 1024, 1024, 0.64),
    (TVOS_ICON_PATH, 1280, 768, 0.56),
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="Generate iOS and tvOS opaque RGB icons")
    mode.add_argument("--check", action="store_true", help="Verify icons match deterministically")
    args = parser.parse_args()

    summaries: list[str] = []
    for path, width, height, mark_fraction in ASSETS:
        rel = path.relative_to(REPO_ROOT).as_posix()
        expected = render_kose_rgb_png(width, height, mark_fraction)
        verify_opaque_rgb_png(expected, width, height, rel)

        if args.write:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(expected)
            summaries.append(f"{rel} ({width}x{height} opaque RGB, {len(expected)} bytes)")
        else:
            if not path.is_file():
                print(f"error: missing {rel}", file=sys.stderr)
                return 1
            actual = path.read_bytes()
            verify_opaque_rgb_png(actual, width, height, rel)
            if actual != expected:
                print(
                    f"error: {rel} drifted from deterministic generator "
                    f"(run `python3 tools/render-apple-mobile-assets.py --write`)",
                    file=sys.stderr,
                )
                return 1
            summaries.append(f"{rel} ({width}x{height} opaque RGB, {len(actual)} bytes)")

    verb = "wrote" if args.write else "apple-mobile Kose assets OK:"
    print(f"{verb} " + "; ".join(summaries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
