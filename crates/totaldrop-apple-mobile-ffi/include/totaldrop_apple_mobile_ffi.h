/* SPDX-FileCopyrightText: 2026 The TotalDrop Contributors */
/* SPDX-License-Identifier: GPL-3.0-or-later */

#ifndef TOTALDROP_APPLE_MOBILE_FFI_H
#define TOTALDROP_APPLE_MOBILE_FFI_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Releases a NUL-terminated UTF-8 string returned by any `totaldrop_mobile_*`
 * function returning `char *`. Safe to call with `NULL`.
 */
void totaldrop_mobile_string_free(char *ptr);

/**
 * Returns JSON containing `app_version`, `core_version`, and strictly numeric
 * Apple `bundle_version`.
 * Caller must free the returned pointer with `totaldrop_mobile_string_free`.
 */
char *totaldrop_mobile_version_json(void);

/**
 * Exports the negotiated 35-language localization bundle JSON
 * (`locale`, `isRtl`, `isDraft`, `strings`).
 * Caller must free the returned pointer with `totaldrop_mobile_string_free`.
 */
char *totaldrop_mobile_ui_bundle_json(
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Routes an incoming iOS/tvOS Universal Link (`https://totaldrop.app/r#...`)
 * or custom `totaldrop://r/...` URL through `parse_universal_link`.
 * `activity` accepts `"idle"`, `"active_send"`, `"active_receive"`, or
 * `"awaiting_user_decision"`.
 * Caller must free the returned pointer with `totaldrop_mobile_string_free`.
 */
char *totaldrop_mobile_handle_url_json(
    const char *raw_url,
    const char *activity,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Extracts a normalized transfer code from clipboard or QR text
 * (`display_code`, `canonical_code`, `universal_link`, `voiceover_spoken_code`).
 * Caller must free the returned pointer with `totaldrop_mobile_string_free`.
 */
char *totaldrop_mobile_extract_clipboard_code_json(const char *raw_text);

/**
 * Formats a hyphenated transfer code into a comma-paused VoiceOver string.
 * Caller must free the returned pointer with `totaldrop_mobile_string_free`.
 */
char *totaldrop_mobile_voiceover_code_json(const char *display_code);

/**
 * Validates and parses an iOS Share Extension `manifest.json` strictly inside
 * `app_group_root` (`group.app.totaldrop.ios`) via `parse_ios_share_manifest_json`.
 * Caller must free the returned pointer with `totaldrop_mobile_string_free`.
 */
char *totaldrop_mobile_parse_share_manifest_json(
    const char *manifest_json,
    const char *app_group_root
);

/**
 * Validates and parses a `BGContinuedProcessingTask` checkpoint JSON payload
 * via `parse_background_checkpoint_json`.
 * Caller must free the returned pointer with `totaldrop_mobile_string_free`.
 */
char *totaldrop_mobile_parse_checkpoint_json(const char *checkpoint_json);

/**
 * Sanitizes an untrusted peer filename by revealing hidden Bidi/control code
 * points (`<U+202E>`, etc.).
 * Caller must free the returned pointer with `totaldrop_mobile_string_free`.
 */
char *totaldrop_mobile_sanitize_filename_json(const char *raw_name);

/**
 * Sanitizes received text for inline display, revealing hidden controls and
 * capping inline display length to `MAX_INLINE_TEXT_CHARS`.
 * Caller must free the returned pointer with `totaldrop_mobile_string_free`.
 */
char *totaldrop_mobile_sanitize_text_json(const char *raw_text);

/**
 * Formats floor-rounded regional transfer progress strings.
 * Caller must free the returned pointer with `totaldrop_mobile_string_free`.
 */
char *totaldrop_mobile_format_progress_json(
    uint64_t done_bytes,
    uint64_t total_bytes,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Starts an asynchronous file/folder send session on the background Tokio
 * runtime. Returns a non-zero monotonic handle, or `0` on invalid input.
 */
uint64_t totaldrop_mobile_session_start_send_files(
    const char *paths_json,
    const char *config_json,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Starts an asynchronous inline text send session on the background Tokio
 * runtime. Returns a non-zero monotonic handle, or `0` on invalid input.
 */
uint64_t totaldrop_mobile_session_start_send_text(
    const char *text,
    const char *config_json,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Starts an asynchronous receive session for `code_or_link`.
 * Returns a non-zero monotonic handle, or `0` on invalid input.
 */
uint64_t totaldrop_mobile_session_start_receive(
    const char *code_or_link,
    const char *config_json,
    const char *preferred_langs_json,
    const char *numeric_locale
);

/**
 * Accepts a pending incoming offer for `handle`. For file offers, `dest_dir`
 * must be a non-empty writable directory path; for text offers, `dest_dir` may
 * be `NULL` or empty.
 * Returns `0` on success, or a negative `FFI_ERR_*` status code.
 */
int32_t totaldrop_mobile_session_accept_offer(
    uint64_t handle,
    const char *dest_dir
);

/**
 * Declines a pending incoming offer for `handle`.
 * Returns `0` on success, or a negative `FFI_ERR_*` status code.
 */
int32_t totaldrop_mobile_session_decline_offer(uint64_t handle);

/**
 * Signals cancellation for an active transfer session `handle` (e.g. user Stop,
 * iOS `BGTask.expirationHandler`, or tvOS Siri Remote Menu/Exit).
 * Returns `0` on success, or a negative `FFI_ERR_*` status code.
 */
int32_t totaldrop_mobile_session_stop(uint64_t handle);

/**
 * Drains pending NDJSON event lines for `handle` (empty string when idle).
 * Caller must free the returned pointer with `totaldrop_mobile_string_free`.
 */
char *totaldrop_mobile_session_poll_events_ndjson(uint64_t handle);

/**
 * Cancels (if active) and destroys `handle`.
 * Returns `0` on success, or a negative `FFI_ERR_*` status code.
 */
int32_t totaldrop_mobile_session_destroy(uint64_t handle);

#ifdef __cplusplus
}
#endif

#endif /* TOTALDROP_APPLE_MOBILE_FFI_H */
