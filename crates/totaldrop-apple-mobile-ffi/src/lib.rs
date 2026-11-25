// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Thin audited C ABI FFI boundary for TotalDrop on iOS, iPadOS, and tvOS (ADR 0009).
//!
//! This crate isolates all `extern "C"` FFI exports into a minimal
//! `staticlib` + `rlib` boundary (`libtotaldrop_apple_mobile_ffi.a`) so that
//! `totaldrop-crypto`, `totaldrop-proto`, `totaldrop-core`, `totaldrop-l10n`,
//! and `totaldrop-apple-mobile-bridge` remain strictly `#![forbid(unsafe_code)]`.

mod sessions;

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::ptr;

use serde::Serialize;
use serde_json::json;
use totaldrop_apple_mobile_bridge::{
    AppleMobileL10n, BackgroundDirection, MobileActivityState, MobileTransferConfig,
    ShareExtensionSkipReason, UNIVERSAL_LINK_PREFIX, UniversalLinkRoute, format_voiceover_code,
    parse_background_checkpoint_json, parse_ios_share_manifest_json, parse_universal_link,
};
use totaldrop_l10n::{Arg, Domain, Strings};
use totaldrop_proto::TransferCode;

use crate::sessions::FfiMobileConfig;

/// Independent SemVer of the TotalDrop iOS/iPadOS/tvOS application (`CFBundleShortVersionString`).
pub const APP_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Version of the synced pure-Rust TotalDrop core workspace crates.
pub const CORE_VERSION: &str = "0.2.0-beta.5";

/// Monotonic numeric Apple bundle build version (`CFBundleVersion`).
pub const BUNDLE_VERSION: &str = "6";

/// Standardized `i32` status code: operation succeeded.
pub const FFI_OK: i32 = 0;

/// Standardized `i32` status code: required pointer argument was null.
pub const FFI_ERR_NULL_POINTER: i32 = -1;

/// Standardized `i32` status code: C string argument was not valid UTF-8.
pub const FFI_ERR_INVALID_UTF8: i32 = -2;

/// Standardized `i32` status code: session handle was `0`, unknown, or destroyed.
pub const FFI_ERR_INVALID_HANDLE: i32 = -3;

/// Standardized `i32` status code: operation invalid for current session state.
pub const FFI_ERR_INVALID_STATE: i32 = -4;

/// Standardized `i32` status code: argument failed domain validation.
pub const FFI_ERR_INVALID_ARG: i32 = -5;

/// Standardized `i32` status code: internal panic or poisoned lock caught at boundary.
pub const FFI_ERR_INTERNAL: i32 = -99;

const FALLBACK_PANIC_JSON: &str = r#"{"ok":false,"error":{"kind":"internal","l10n_key":"errorOther","message":"internal FFI panic"}}"#;
const FALLBACK_SERIALIZE_JSON: &str = r#"{"ok":false,"error":{"kind":"internal","l10n_key":"errorOther","message":"internal JSON serialization failure"}}"#;

#[derive(Serialize)]
struct VersionInfo {
    ok: bool,
    app_version: &'static str,
    core_version: &'static str,
    bundle_version: &'static str,
}

#[derive(Serialize)]
struct FfiErrorEnvelope<'a> {
    ok: bool,
    error: FfiErrorBody<'a>,
}

#[derive(Serialize)]
struct FfiErrorBody<'a> {
    kind: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    l10n_key: Option<&'a str>,
    message: String,
}

#[derive(Serialize)]
struct HandleUrlDto {
    ok: bool,
    outcome: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    display_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    canonical_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    universal_link: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    voiceover_spoken_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

#[derive(Serialize)]
struct ExtractedCodeDto {
    ok: bool,
    display_code: String,
    canonical_code: String,
    universal_link: String,
    voiceover_spoken_code: String,
}

#[derive(Serialize)]
struct VoiceOverCodeDto {
    ok: bool,
    spoken: String,
}

#[derive(Serialize)]
struct ManifestEntryDto {
    staged_path: String,
    safe_name: String,
    collision_key: String,
    byte_size: u64,
    chunks: u64,
}

#[derive(Serialize)]
struct ManifestSkippedDto {
    raw_name: String,
    reason: &'static str,
}

#[derive(Serialize)]
struct ShareManifestDto {
    ok: bool,
    app_group: String,
    entries: Vec<ManifestEntryDto>,
    total_bytes: u64,
    skipped: Vec<ManifestSkippedDto>,
    #[serde(skip_serializing_if = "Option::is_none")]
    notice: Option<String>,
    rejected_busy: bool,
}

#[derive(Serialize)]
struct CheckpointDto {
    ok: bool,
    task_identifier: String,
    direction: &'static str,
    done_bytes: u64,
    total_bytes: u64,
    completed_chunks: u64,
    total_chunks: u64,
    percent: u8,
    notification_title: String,
    notification_subtitle: String,
    progress_summary: String,
    expired_by_system: bool,
}

#[derive(Serialize)]
struct SanitizedFilenameDto {
    ok: bool,
    sanitized: String,
    has_hidden_controls: bool,
}

#[derive(Serialize)]
struct SanitizedTextDto {
    ok: bool,
    display_text: String,
    shortened: bool,
    had_hidden_controls: bool,
}

#[derive(Serialize)]
pub(crate) struct ProgressParts {
    pub(crate) ok: bool,
    pub(crate) percent_value: u8,
    pub(crate) percent_text: String,
    pub(crate) done_bytes_text: String,
    pub(crate) total_bytes_text: String,
    pub(crate) fraction_text: String,
}

pub(crate) fn compute_progress_parts(done: u64, total: u64, strings: &Strings) -> ProgressParts {
    let clamped_done = if total > 0 { done.min(total) } else { done };
    let percent_u64 = if total == 0 {
        if done == 0 { 0 } else { 100 }
    } else {
        u128::from(clamped_done)
            .saturating_mul(100)
            .checked_div(u128::from(total))
            .and_then(|v| u64::try_from(v).ok())
            .unwrap_or(100)
            .min(100)
    };
    let percent_value = u8::try_from(percent_u64).unwrap_or(100);
    let percent_text = strings.get("progressPercent", &[("percent", Arg::Count(percent_u64))]);
    let done_bytes_text = strings.bytes(clamped_done);
    let total_bytes_text = strings.bytes(total);
    let fraction_text = format!("{done_bytes_text} / {total_bytes_text}");
    ProgressParts {
        ok: true,
        percent_value,
        percent_text,
        done_bytes_text,
        total_bytes_text,
        fraction_text,
    }
}

fn into_c_string_ptr(mut text: String) -> *mut c_char {
    if text.as_bytes().contains(&0) {
        text.retain(|ch| ch != '\0');
    }
    match CString::new(text) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

fn serialize_or_error<T: Serialize>(value: &T) -> *mut c_char {
    match serde_json::to_string(value) {
        Ok(json) => into_c_string_ptr(json),
        Err(_) => into_c_string_ptr(FALLBACK_SERIALIZE_JSON.to_owned()),
    }
}

fn error_json(kind: &str, l10n_key: Option<&str>, message: impl Into<String>) -> *mut c_char {
    let raw = message.into();
    let sanitized = totaldrop_l10n::reveal_controls(&raw);
    let envelope = FfiErrorEnvelope {
        ok: false,
        error: FfiErrorBody {
            kind,
            l10n_key,
            message: sanitized,
        },
    };
    serialize_or_error(&envelope)
}

fn guard_ffi_json<F>(f: F) -> *mut c_char
where
    F: FnOnce() -> *mut c_char,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(ptr) => ptr,
        Err(_) => into_c_string_ptr(FALLBACK_PANIC_JSON.to_owned()),
    }
}

fn guard_ffi_u64<F>(f: F) -> u64
where
    F: FnOnce() -> u64,
{
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(0)
}

fn guard_ffi_i32<F>(f: F) -> i32
where
    F: FnOnce() -> i32,
{
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(FFI_ERR_INTERNAL)
}

/// Reads an optional NUL-terminated UTF-8 C string pointer.
///
/// # Safety
///
/// If `ptr` is non-null, it must point to a valid, readable NUL-terminated C
/// string that remains alive for `'a`.
unsafe fn read_optional_c_str<'a>(ptr: *const c_char) -> Result<Option<&'a str>, &'static str> {
    if ptr.is_null() {
        return Ok(None);
    }
    // SAFETY: Caller guarantees non-null `ptr` points to a readable
    // NUL-terminated C string valid for lifetime `'a`.
    let cstr = unsafe { CStr::from_ptr(ptr) };
    match cstr.to_str() {
        Ok(valid) => Ok(Some(valid)),
        Err(_) => Err("input string is not valid UTF-8"),
    }
}

fn clean_apple_locale_tag(raw: &str) -> String {
    let without_calendar = raw.split('@').next().unwrap_or(raw);
    without_calendar.trim().replace('_', "-")
}

fn parse_preferred_languages(raw: Option<&str>) -> Vec<String> {
    let Some(text) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return vec!["en".to_owned()];
    };
    if text.starts_with('[')
        && let Ok(parsed) = serde_json::from_str::<Vec<String>>(text)
    {
        let filtered: Vec<String> = parsed
            .into_iter()
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty())
            .collect();
        if !filtered.is_empty() {
            return filtered;
        }
    }
    let split: Vec<String> = text
        .split([',', ';'])
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    if split.is_empty() {
        vec!["en".to_owned()]
    } else {
        split
    }
}

fn build_l10n(
    preferred_langs: Option<&str>,
    numeric_locale: Option<&str>,
) -> (AppleMobileL10n, Strings) {
    let langs = parse_preferred_languages(preferred_langs);
    let numeric = numeric_locale.map(str::trim).filter(|s| !s.is_empty());
    let l10n = AppleMobileL10n::from_apple_preferences(&langs, numeric);
    let prefs: Vec<_> = langs
        .iter()
        .filter_map(|t| totaldrop_l10n::locale::parse(&clean_apple_locale_tag(t)))
        .collect();
    let num_loc = numeric
        .map(clean_apple_locale_tag)
        .and_then(|t| totaldrop_l10n::locale::parse(&t));
    let strings = Strings::new(Domain::App, &prefs, num_loc.as_ref());
    (l10n, strings)
}

fn parse_activity(raw: Option<&str>) -> MobileActivityState {
    match raw.map(str::trim) {
        Some("active_send" | "activeSend") => MobileActivityState::ActiveSend,
        Some("active_receive" | "activeReceive") => MobileActivityState::ActiveReceive,
        Some("awaiting_user_decision" | "awaitingUserDecision") => {
            MobileActivityState::AwaitingUserDecision
        }
        _ => MobileActivityState::Idle,
    }
}

fn skip_reason_str(reason: &ShareExtensionSkipReason) -> &'static str {
    match reason {
        ShareExtensionSkipReason::SecurityScopeDenied => "security_scope_denied",
        ShareExtensionSkipReason::OutsideAppGroupContainer => "outside_app_group_container",
        ShareExtensionSkipReason::UnsafeName => "unsafe_name",
        ShareExtensionSkipReason::DuplicateNameCollision => "duplicate_name_collision",
        ShareExtensionSkipReason::EntryLimitReached => "entry_limit_reached",
    }
}

fn parse_config(raw: Option<&str>) -> Result<MobileTransferConfig, &'static str> {
    let Some(text) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return Ok(MobileTransferConfig::default());
    };
    let dto: FfiMobileConfig =
        serde_json::from_str(text).map_err(|_| "invalid transfer configuration JSON")?;
    Ok(dto.into_mobile_config())
}

/// Releases a NUL-terminated UTF-8 string previously allocated by this crate.
///
/// # Safety
///
/// `ptr` must either be null or be a pointer previously returned by a
/// `totaldrop_mobile_*` function that has not already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_string_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: Caller guarantees `ptr` came from `CString::into_raw` in this
        // crate and has not been freed before.
        let _ = unsafe { CString::from_raw(ptr) };
    }));
}

/// Returns JSON containing `app_version`, `core_version`, and numeric `bundle_version`.
#[unsafe(no_mangle)]
pub extern "C" fn totaldrop_mobile_version_json() -> *mut c_char {
    guard_ffi_json(|| {
        let info = VersionInfo {
            ok: true,
            app_version: APP_VERSION,
            core_version: CORE_VERSION,
            bundle_version: BUNDLE_VERSION,
        };
        serialize_or_error(&info)
    })
}

/// Exports the negotiated 35-language Apple mobile localization bundle JSON.
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_ui_bundle_json(
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let langs = match unsafe { read_optional_c_str(preferred_langs_json) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let numeric = match unsafe { read_optional_c_str(numeric_locale) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let (l10n, strings) = build_l10n(langs, numeric);
        let mut entries = serde_json::Map::new();
        for key in strings.keys() {
            entries.insert(
                key.to_owned(),
                serde_json::Value::String(strings.get(key, &[])),
            );
        }
        let is_draft = strings.is_draft() || totaldrop_l10n::has_drafts(strings.tag());
        let payload = json!({
            "locale": l10n.tag(),
            "isRtl": l10n.is_rtl(),
            "isDraft": is_draft,
            "strings": entries,
        })
        .to_string();
        into_c_string_ptr(payload)
    })
}

/// Routes an incoming Universal Link or `totaldrop://r/...` URL via [`parse_universal_link`].
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_handle_url_json(
    raw_url: *const c_char,
    activity: *const c_char,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let url_opt = match unsafe { read_optional_c_str(raw_url) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorInvalidCode"), msg),
        };
        let Some(url) = url_opt else {
            return error_json(
                "null_pointer",
                Some("errorInvalidCode"),
                "raw_url must not be null",
            );
        };
        // SAFETY: Forwarded from this function's safety contract.
        let act = match unsafe { read_optional_c_str(activity) } {
            Ok(v) => parse_activity(v),
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let langs = match unsafe { read_optional_c_str(preferred_langs_json) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let numeric = match unsafe { read_optional_c_str(numeric_locale) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let (l10n, _) = build_l10n(langs, numeric);
        let dto = match parse_universal_link(url, act, &l10n) {
            UniversalLinkRoute::ConnectReceive {
                display_code,
                canonical_code,
                universal_link,
                voiceover_spoken_code,
            } => HandleUrlDto {
                ok: true,
                outcome: "connect_receive",
                display_code: Some(display_code),
                canonical_code: Some(canonical_code),
                universal_link: Some(universal_link),
                voiceover_spoken_code: Some(voiceover_spoken_code),
                message: None,
            },
            UniversalLinkRoute::Busy { message } => HandleUrlDto {
                ok: true,
                outcome: "busy",
                display_code: None,
                canonical_code: None,
                universal_link: None,
                voiceover_spoken_code: None,
                message: Some(message),
            },
            UniversalLinkRoute::Invalid => HandleUrlDto {
                ok: false,
                outcome: "invalid",
                display_code: None,
                canonical_code: None,
                universal_link: None,
                voiceover_spoken_code: None,
                message: Some(l10n.text("errorInvalidCode")),
            },
        };
        serialize_or_error(&dto)
    })
}

/// Extracts a normalized transfer code from clipboard or QR text.
///
/// # Safety
///
/// `raw_text` must either be null or point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_extract_clipboard_code_json(
    raw_text: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let text_opt = match unsafe { read_optional_c_str(raw_text) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorInvalidCode"), msg),
        };
        let Some(text) = text_opt else {
            return error_json(
                "null_pointer",
                Some("errorInvalidCode"),
                "raw_text must not be null",
            );
        };
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return error_json(
                "empty",
                Some("receiveCodeInvalid"),
                "clipboard text is empty",
            );
        }
        let found = TransferCode::from_link(trimmed)
            .or_else(|| TransferCode::parse(trimmed).ok())
            .or_else(|| TransferCode::find(trimmed));
        let Some(code) = found else {
            return error_json(
                "no_code_found",
                Some("errorInvalidCode"),
                "no valid TotalDrop transfer code found",
            );
        };
        let display_code = code.to_english();
        let dto = ExtractedCodeDto {
            ok: true,
            canonical_code: code.canonical(),
            universal_link: format!("{UNIVERSAL_LINK_PREFIX}{display_code}"),
            voiceover_spoken_code: format_voiceover_code(&display_code),
            display_code,
        };
        serialize_or_error(&dto)
    })
}

/// Formats a hyphenated transfer code for VoiceOver pronunciation.
///
/// # Safety
///
/// `display_code` must either be null or point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_voiceover_code_json(
    display_code: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let code_opt = match unsafe { read_optional_c_str(display_code) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let Some(code) = code_opt else {
            return error_json(
                "null_pointer",
                Some("errorOther"),
                "display_code must not be null",
            );
        };
        let dto = VoiceOverCodeDto {
            ok: true,
            spoken: format_voiceover_code(code),
        };
        serialize_or_error(&dto)
    })
}

/// Validates and parses an iOS Share Extension `manifest.json` confined to `app_group_root`.
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_parse_share_manifest_json(
    manifest_json: *const c_char,
    app_group_root: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let json_opt = match unsafe { read_optional_c_str(manifest_json) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let root_opt = match unsafe { read_optional_c_str(app_group_root) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let (Some(raw_json), Some(root_str)) = (json_opt, root_opt) else {
            return error_json(
                "null_pointer",
                Some("errorOther"),
                "manifest_json and app_group_root must not be null",
            );
        };
        match parse_ios_share_manifest_json(raw_json, Path::new(root_str)) {
            Ok(manifest) => {
                let dto = ShareManifestDto {
                    ok: true,
                    app_group: manifest.app_group,
                    entries: manifest
                        .entries
                        .into_iter()
                        .map(|e| ManifestEntryDto {
                            staged_path: e.staged_path.to_string_lossy().into_owned(),
                            safe_name: e.safe_name,
                            collision_key: e.collision_key,
                            byte_size: e.byte_size,
                            chunks: e.chunks,
                        })
                        .collect(),
                    total_bytes: manifest.total_bytes,
                    skipped: manifest
                        .skipped
                        .into_iter()
                        .map(|(raw_name, reason)| ManifestSkippedDto {
                            raw_name: totaldrop_l10n::reveal_controls(&raw_name),
                            reason: skip_reason_str(&reason),
                        })
                        .collect(),
                    notice: manifest.localized_notice,
                    rejected_busy: manifest.rejected_busy,
                };
                serialize_or_error(&dto)
            }
            Err(err) => error_json("invalid_manifest", Some("errorOther"), err.to_string()),
        }
    })
}

/// Validates and parses a `BGContinuedProcessingTask` checkpoint JSON payload.
///
/// # Safety
///
/// `checkpoint_json` must either be null or point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_parse_checkpoint_json(
    checkpoint_json: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let json_opt = match unsafe { read_optional_c_str(checkpoint_json) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let Some(raw_json) = json_opt else {
            return error_json(
                "null_pointer",
                Some("errorOther"),
                "checkpoint_json must not be null",
            );
        };
        match parse_background_checkpoint_json(raw_json) {
            Ok(cp) => {
                let direction = match cp.direction {
                    BackgroundDirection::Sending => "sending",
                    BackgroundDirection::Receiving => "receiving",
                };
                let dto = CheckpointDto {
                    ok: true,
                    task_identifier: cp.task_identifier,
                    direction,
                    done_bytes: cp.done_bytes,
                    total_bytes: cp.total_bytes,
                    completed_chunks: cp.completed_chunks,
                    total_chunks: cp.total_chunks,
                    percent: cp.percent,
                    notification_title: cp.notification_title,
                    notification_subtitle: cp.notification_subtitle,
                    progress_summary: cp.progress_summary,
                    expired_by_system: cp.expired_by_system,
                };
                serialize_or_error(&dto)
            }
            Err(err) => error_json("invalid_checkpoint", Some("errorOther"), err.to_string()),
        }
    })
}

/// Sanitizes an untrusted filename by revealing hidden Bidi/control code points.
///
/// # Safety
///
/// `raw_name` must either be null or point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_sanitize_filename_json(
    raw_name: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let name_opt = match unsafe { read_optional_c_str(raw_name) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let Some(name) = name_opt else {
            return error_json(
                "null_pointer",
                Some("errorOther"),
                "raw_name must not be null",
            );
        };
        let sanitized = totaldrop_l10n::reveal_controls(name);
        let has_hidden_controls = sanitized != name;
        let dto = SanitizedFilenameDto {
            ok: true,
            sanitized,
            has_hidden_controls,
        };
        serialize_or_error(&dto)
    })
}

/// Sanitizes received inline text for display on iOS/tvOS.
///
/// # Safety
///
/// `raw_text` must either be null or point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_sanitize_text_json(
    raw_text: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let text_opt = match unsafe { read_optional_c_str(raw_text) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let Some(text) = text_opt else {
            return error_json(
                "null_pointer",
                Some("errorOther"),
                "raw_text must not be null",
            );
        };
        let (l10n, _) = build_l10n(None, None);
        let (display_text, shortened, had_hidden_controls) = l10n.sanitize_received_text(text);
        let dto = SanitizedTextDto {
            ok: true,
            display_text,
            shortened,
            had_hidden_controls,
        };
        serialize_or_error(&dto)
    })
}

/// Formats floor-rounded regional transfer progress strings.
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_format_progress_json(
    done_bytes: u64,
    total_bytes: u64,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> *mut c_char {
    guard_ffi_json(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let langs = match unsafe { read_optional_c_str(preferred_langs_json) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        // SAFETY: Forwarded from this function's safety contract.
        let numeric = match unsafe { read_optional_c_str(numeric_locale) } {
            Ok(v) => v,
            Err(msg) => return error_json("invalid_utf8", Some("errorOther"), msg),
        };
        let (_, strings) = build_l10n(langs, numeric);
        let parts = compute_progress_parts(done_bytes, total_bytes, &strings);
        serialize_or_error(&parts)
    })
}

/// Starts an asynchronous file/folder send session.
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_session_start_send_files(
    paths_json: *const c_char,
    config_json: *const c_char,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> u64 {
    guard_ffi_u64(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(Some(paths_str)) = (unsafe { read_optional_c_str(paths_json) }) else {
            return 0;
        };
        let Ok(raw_paths) = serde_json::from_str::<Vec<String>>(paths_str) else {
            return 0;
        };
        let paths: Vec<PathBuf> = raw_paths
            .into_iter()
            .filter(|p| !p.trim().is_empty())
            .map(PathBuf::from)
            .collect();
        if paths.is_empty() {
            return 0;
        }
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(cfg_str) = (unsafe { read_optional_c_str(config_json) }) else {
            return 0;
        };
        let Ok(config) = parse_config(cfg_str) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(langs) = (unsafe { read_optional_c_str(preferred_langs_json) }) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(numeric) = (unsafe { read_optional_c_str(numeric_locale) }) else {
            return 0;
        };
        let (l10n, strings) = build_l10n(langs, numeric);
        sessions::start_send_files(paths, config, l10n, strings)
    })
}

/// Starts an asynchronous inline text send session.
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_session_start_send_text(
    text: *const c_char,
    config_json: *const c_char,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> u64 {
    guard_ffi_u64(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(Some(raw_text)) = (unsafe { read_optional_c_str(text) }) else {
            return 0;
        };
        if raw_text.is_empty() {
            return 0;
        }
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(cfg_str) = (unsafe { read_optional_c_str(config_json) }) else {
            return 0;
        };
        let Ok(config) = parse_config(cfg_str) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(langs) = (unsafe { read_optional_c_str(preferred_langs_json) }) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(numeric) = (unsafe { read_optional_c_str(numeric_locale) }) else {
            return 0;
        };
        let (l10n, strings) = build_l10n(langs, numeric);
        sessions::start_send_text(raw_text.to_owned(), config, l10n, strings)
    })
}

/// Starts an asynchronous receive session for `code_or_link`.
///
/// # Safety
///
/// Each non-null pointer must point to a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_session_start_receive(
    code_or_link: *const c_char,
    config_json: *const c_char,
    preferred_langs_json: *const c_char,
    numeric_locale: *const c_char,
) -> u64 {
    guard_ffi_u64(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(Some(raw_code)) = (unsafe { read_optional_c_str(code_or_link) }) else {
            return 0;
        };
        let trimmed = raw_code.trim();
        if trimmed.is_empty() {
            return 0;
        }
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(cfg_str) = (unsafe { read_optional_c_str(config_json) }) else {
            return 0;
        };
        let Ok(config) = parse_config(cfg_str) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(langs) = (unsafe { read_optional_c_str(preferred_langs_json) }) else {
            return 0;
        };
        // SAFETY: Forwarded from this function's safety contract.
        let Ok(numeric) = (unsafe { read_optional_c_str(numeric_locale) }) else {
            return 0;
        };
        let (l10n, strings) = build_l10n(langs, numeric);
        sessions::start_receive(trimmed.to_owned(), config, l10n, strings)
    })
}

/// Accepts a pending incoming offer for `handle`.
///
/// # Safety
///
/// `dest_dir` must either be null (for text offers) or point to a valid
/// NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn totaldrop_mobile_session_accept_offer(
    handle: u64,
    dest_dir: *const c_char,
) -> i32 {
    guard_ffi_i32(|| {
        // SAFETY: Forwarded from this function's safety contract.
        let dir_opt = match unsafe { read_optional_c_str(dest_dir) } {
            Ok(v) => v
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(PathBuf::from),
            Err(_) => return FFI_ERR_INVALID_UTF8,
        };
        sessions::accept_offer(handle, dir_opt)
    })
}

/// Declines a pending incoming offer for `handle`.
#[unsafe(no_mangle)]
pub extern "C" fn totaldrop_mobile_session_decline_offer(handle: u64) -> i32 {
    guard_ffi_i32(|| sessions::decline_offer(handle))
}

/// Signals cancellation for an active transfer session `handle`.
#[unsafe(no_mangle)]
pub extern "C" fn totaldrop_mobile_session_stop(handle: u64) -> i32 {
    guard_ffi_i32(|| sessions::stop_session(handle))
}

/// Drains pending NDJSON event lines for `handle`.
#[unsafe(no_mangle)]
pub extern "C" fn totaldrop_mobile_session_poll_events_ndjson(handle: u64) -> *mut c_char {
    guard_ffi_json(|| match sessions::poll_events_ndjson(handle) {
        Some(ndjson) => into_c_string_ptr(ndjson),
        None => error_json(
            "invalid_handle",
            Some("errorOther"),
            "unknown session handle",
        ),
    })
}

/// Cancels (if active) and destroys `handle`.
#[unsafe(no_mangle)]
pub extern "C" fn totaldrop_mobile_session_destroy(handle: u64) -> i32 {
    guard_ffi_i32(|| sessions::destroy_session(handle))
}

#[cfg(test)]
mod tests {
    #![allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing,
        clippy::undocumented_unsafe_blocks
    )]

    use std::collections::HashMap;
    use std::net::SocketAddr;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use futures_util::{SinkExt, StreamExt};
    use serde_json::{Value, json};
    use tokio::net::TcpListener;
    use tokio::sync::{Mutex, mpsc};
    use tokio_tungstenite::tungstenite::Message;
    use totaldrop_proto::wire::{ClientMessage, ServerMessage};

    use super::*;

    fn take_string(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null(), "FFI returned null string pointer");
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
        unsafe { totaldrop_mobile_string_free(ptr) };
        text
    }

    fn take_json(ptr: *mut c_char) -> Value {
        let raw = take_string(ptr);
        serde_json::from_str(&raw).unwrap_or_else(|e| panic!("invalid JSON {raw:?}: {e}"))
    }

    fn cstr(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    #[test]
    fn version_ui_bundle_and_voiceover_helpers() {
        unsafe { totaldrop_mobile_string_free(ptr::null_mut()) };
        let v = take_json(totaldrop_mobile_version_json());
        assert_eq!(v["ok"], true);
        assert_eq!(v["app_version"], APP_VERSION);
        assert_eq!(v["core_version"], CORE_VERSION);
        assert_eq!(v["bundle_version"], BUNDLE_VERSION);
        assert!(BUNDLE_VERSION.chars().all(|c| c.is_ascii_digit()));

        let ar = take_json(unsafe {
            totaldrop_mobile_ui_bundle_json(cstr(r#"["ar-SA"]"#).as_ptr(), cstr("ar_SA").as_ptr())
        });
        assert_eq!(ar["locale"], "ar");
        assert_eq!(ar["isRtl"], true);
        assert!(ar["strings"]["verificationTitle"].is_string());

        let vo = take_json(unsafe {
            totaldrop_mobile_voiceover_code_json(cstr("7-harbor-rocket").as_ptr())
        });
        assert_eq!(vo["ok"], true);
        assert_eq!(vo["spoken"], "7, harbor, rocket");
    }

    #[test]
    fn url_clipboard_share_manifest_and_checkpoint_validation() {
        let route = take_json(unsafe {
            totaldrop_mobile_handle_url_json(
                cstr("https://totaldrop.app/r#7-harbor-rocket").as_ptr(),
                cstr("idle").as_ptr(),
                cstr("en-US").as_ptr(),
                ptr::null(),
            )
        });
        assert_eq!(route["outcome"], "connect_receive");
        assert_eq!(route["display_code"], "7-harbor-rocket");
        assert_eq!(route["voiceover_spoken_code"], "7, harbor, rocket");

        let busy = take_json(unsafe {
            totaldrop_mobile_handle_url_json(
                cstr("totaldrop://r/7-harbor-rocket").as_ptr(),
                cstr("active_send").as_ptr(),
                cstr("en-US").as_ptr(),
                ptr::null(),
            )
        });
        assert_eq!(busy["outcome"], "busy");

        let clip = take_json(unsafe {
            totaldrop_mobile_extract_clipboard_code_json(
                cstr("Get my files with TotalDrop. Code: 9-harbor-rocket").as_ptr(),
            )
        });
        assert_eq!(clip["ok"], true);
        assert_eq!(clip["display_code"], "9-harbor-rocket");

        let good_manifest = json!({
            "appGroup": "group.app.totaldrop.ios",
            "rejectedBusy": false,
            "totalBytes": 1024,
            "entries": [{
                "stagedPath": "/var/mobile/Containers/Shared/AppGroup/TD/SharedInbox/report.pdf",
                "safeName": "report.pdf",
                "collisionKey": "report.pdf",
                "byteSize": 1024,
                "chunks": 1
            }],
            "skipped": []
        })
        .to_string();
        let parsed = take_json(unsafe {
            totaldrop_mobile_parse_share_manifest_json(
                cstr(&good_manifest).as_ptr(),
                cstr("/var/mobile/Containers/Shared/AppGroup/TD").as_ptr(),
            )
        });
        assert_eq!(parsed["ok"], true);
        assert_eq!(parsed["entries"].as_array().unwrap().len(), 1);

        let escape_manifest = json!({
            "appGroup": "group.app.totaldrop.ios",
            "rejectedBusy": false,
            "totalBytes": 10,
            "entries": [{
                "stagedPath": "/etc/passwd",
                "safeName": "passwd",
                "collisionKey": "passwd",
                "byteSize": 10,
                "chunks": 1
            }],
            "skipped": []
        })
        .to_string();
        let escaped = take_json(unsafe {
            totaldrop_mobile_parse_share_manifest_json(
                cstr(&escape_manifest).as_ptr(),
                cstr("/var/mobile/Containers/Shared/AppGroup/TD").as_ptr(),
            )
        });
        assert_eq!(escaped["ok"], false);
        assert_eq!(escaped["error"]["kind"], "invalid_manifest");

        let cp_json = json!({
            "taskIdentifier": "app.totaldrop.ios.transfer",
            "direction": "receiving",
            "doneBytes": 1048576,
            "totalBytes": 2097152,
            "completedChunks": 1,
            "totalChunks": 2,
            "percent": 50,
            "notificationTitle": "Receiving files",
            "notificationSubtitle": "Transfer continues in the background.",
            "progressSummary": "1 MB / 2 MB",
            "expiredBySystem": false
        })
        .to_string();
        let cp =
            take_json(unsafe { totaldrop_mobile_parse_checkpoint_json(cstr(&cp_json).as_ptr()) });
        assert_eq!(cp["ok"], true);
        assert_eq!(cp["direction"], "receiving");
        assert_eq!(cp["completed_chunks"], 1);
        assert_eq!(cp["percent"], 50);
        assert_eq!(cp["expired_by_system"], false);
    }

    #[test]
    fn sanitize_progress_and_invalid_handles() {
        let name = take_json(unsafe {
            totaldrop_mobile_sanitize_filename_json(cstr("photo\u{202E}gpj.app").as_ptr())
        });
        assert_eq!(name["has_hidden_controls"], true);
        assert_eq!(name["sanitized"], "photo<U+202E>gpj.app");

        let txt = take_json(unsafe {
            totaldrop_mobile_sanitize_text_json(cstr("note\u{202E}1\r\n2").as_ptr())
        });
        assert_eq!(txt["had_hidden_controls"], true);
        assert_eq!(txt["display_text"], "note<U+202E>1\n2");

        let prog = take_json(unsafe {
            totaldrop_mobile_format_progress_json(
                999_999,
                1_000_000,
                cstr("de-DE").as_ptr(),
                cstr("de_DE").as_ptr(),
            )
        });
        assert_eq!(prog["percent_value"], 99);
        assert!(prog["done_bytes_text"].as_str().unwrap().contains(','));

        assert_eq!(
            unsafe { totaldrop_mobile_session_accept_offer(0, ptr::null()) },
            FFI_ERR_INVALID_HANDLE
        );
        assert_eq!(
            totaldrop_mobile_session_decline_offer(999_999),
            FFI_ERR_INVALID_HANDLE
        );
        assert_eq!(
            totaldrop_mobile_session_stop(999_999),
            FFI_ERR_INVALID_HANDLE
        );
        assert_eq!(
            totaldrop_mobile_session_destroy(999_999),
            FFI_ERR_INVALID_HANDLE
        );
    }

    #[derive(Default)]
    struct MockRendezvousState {
        next_nameplate: u32,
        mailboxes: HashMap<u32, MockMailbox>,
    }

    struct MockMailbox {
        id: [u8; 16],
        messages: Vec<(usize, String, Vec<u8>)>,
        peers: Vec<(usize, mpsc::UnboundedSender<Message>)>,
    }

    async fn spawn_loopback_rendezvous() -> (SocketAddr, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let state = Arc::new(Mutex::new(MockRendezvousState {
            next_nameplate: 11,
            mailboxes: HashMap::new(),
        }));
        let handle = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let state = Arc::clone(&state);
                tokio::spawn(async move {
                    let Ok(ws) = tokio_tungstenite::accept_async(stream).await else {
                        return;
                    };
                    let (mut sink, mut stream) = ws.split();
                    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
                    let writer = tokio::spawn(async move {
                        while let Some(msg) = rx.recv().await {
                            let is_close = matches!(msg, Message::Close(_));
                            if sink.send(msg).await.is_err() || is_close {
                                break;
                            }
                        }
                    });

                    let mut my_peer_id: usize = 0;
                    let mut my_nameplate: Option<u32> = None;

                    while let Some(Ok(Message::Binary(raw))) = stream.next().await {
                        let Ok(client_msg) = ClientMessage::decode(&raw) else {
                            continue;
                        };
                        match client_msg {
                            ClientMessage::Allocate => {
                                let mut guard = state.lock().await;
                                let np = guard.next_nameplate;
                                guard.next_nameplate = guard.next_nameplate.saturating_add(1);
                                let mut mailbox_id = [0u8; 16];
                                mailbox_id[0..4].copy_from_slice(&np.to_be_bytes());
                                let mut token = [0x5Au8; 16];
                                token[0..4].copy_from_slice(&np.to_be_bytes());
                                guard.mailboxes.insert(
                                    np,
                                    MockMailbox {
                                        id: mailbox_id,
                                        messages: Vec::new(),
                                        peers: Vec::new(),
                                    },
                                );
                                let reply = ServerMessage::Allocated {
                                    nameplate: np,
                                    token,
                                };
                                let _ = tx.send(Message::Binary(reply.encode().into()));
                            }
                            ClientMessage::Claim { nameplate, .. } => {
                                let mut guard = state.lock().await;
                                if let Some(mb) = guard.mailboxes.get_mut(&nameplate) {
                                    let reply = ServerMessage::Claimed { mailbox: mb.id };
                                    let _ = tx.send(Message::Binary(reply.encode().into()));
                                    my_peer_id = mb.peers.len();
                                    for (from, phase, body) in &mb.messages {
                                        if *from != my_peer_id {
                                            let fwd = ServerMessage::Message {
                                                phase: phase.clone(),
                                                body: body.clone(),
                                            };
                                            let _ = tx.send(Message::Binary(fwd.encode().into()));
                                        }
                                    }
                                    mb.peers.push((my_peer_id, tx.clone()));
                                    my_nameplate = Some(nameplate);
                                } else {
                                    let reply = ServerMessage::Error {
                                        reason: "unknown nameplate".to_owned(),
                                    };
                                    let _ = tx.send(Message::Binary(reply.encode().into()));
                                }
                            }
                            ClientMessage::Add { phase, body } => {
                                if let Some(np) = my_nameplate {
                                    let mut guard = state.lock().await;
                                    if let Some(mb) = guard.mailboxes.get_mut(&np) {
                                        mb.messages.push((my_peer_id, phase.clone(), body.clone()));
                                        let fwd = ServerMessage::Message { phase, body }.encode();
                                        for (peer_id, peer_tx) in &mb.peers {
                                            if *peer_id != my_peer_id {
                                                let _ = peer_tx
                                                    .send(Message::Binary(fwd.clone().into()));
                                            }
                                        }
                                    }
                                }
                            }
                            ClientMessage::Close { .. } => {
                                let _ = tx.send(Message::Close(None));
                                break;
                            }
                        }
                    }
                    drop(tx);
                    let _ = writer.await;
                });
            }
        });
        (addr, handle)
    }

    fn poll_events_until<F>(handle: u64, timeout: Duration, mut pred: F) -> Vec<Value>
    where
        F: FnMut(&Value) -> bool,
    {
        let deadline = Instant::now().checked_add(timeout).unwrap();
        let mut all = Vec::new();
        while Instant::now() < deadline {
            let chunk = take_string(totaldrop_mobile_session_poll_events_ndjson(handle));
            for line in chunk.lines().filter(|l| !l.trim().is_empty()) {
                let ev: Value = serde_json::from_str(line).unwrap();
                let done = pred(&ev);
                all.push(ev);
                if done {
                    return all;
                }
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("timed out polling handle {handle}; events seen so far: {all:#?}");
    }

    #[test]
    fn loopback_e2e_file_and_text_transfer_via_mobile_c_abi() {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let (rv_addr, rv_task) = rt.block_on(spawn_loopback_rendezvous());
        let cfg = json!({
            "server": format!("ws://{rv_addr}"),
            "relay": "",
            "stun": "",
            "privacy_mode": false,
            "stronger_code": false
        })
        .to_string();

        let temp_root = std::env::temp_dir().join(format!(
            "totaldrop-apple-mobile-ffi-e2e-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&temp_root);
        let src_dir = temp_root.join("src");
        let dst_dir = temp_root.join("dst");
        std::fs::create_dir_all(&src_dir).unwrap();
        std::fs::create_dir_all(&dst_dir).unwrap();
        let src_file = src_dir.join("ios-sample.bin");
        let payload: Vec<u8> = (0..32_768u32).map(|i| (i % 241) as u8).collect();
        std::fs::write(&src_file, &payload).unwrap();

        let paths_json = serde_json::to_string(&vec![src_file.to_string_lossy()]).unwrap();
        let send_handle = unsafe {
            totaldrop_mobile_session_start_send_files(
                cstr(&paths_json).as_ptr(),
                cstr(&cfg).as_ptr(),
                cstr("en-US").as_ptr(),
                cstr("en_US").as_ptr(),
            )
        };
        assert_ne!(send_handle, 0);

        let send_ready = poll_events_until(send_handle, Duration::from_secs(10), |ev| {
            ev["event"] == "code_ready"
        });
        let code = send_ready
            .iter()
            .find(|ev| ev["event"] == "code_ready")
            .unwrap()["display_code"]
            .as_str()
            .unwrap()
            .to_owned();

        let recv_handle = unsafe {
            totaldrop_mobile_session_start_receive(
                cstr(&code).as_ptr(),
                cstr(&cfg).as_ptr(),
                cstr("tr-TR").as_ptr(),
                cstr("tr_TR").as_ptr(),
            )
        };
        assert_ne!(recv_handle, 0);

        let offer_events = poll_events_until(recv_handle, Duration::from_secs(15), |ev| {
            ev["event"] == "offer_ready" || ev["event"] == "failed"
        });
        let offer = offer_events
            .iter()
            .find(|ev| ev["event"] == "offer_ready")
            .unwrap_or_else(|| panic!("expected offer_ready, got {offer_events:#?}"));
        assert_eq!(offer["files"], 1);
        assert_eq!(offer["total_bytes"], 32_768);

        assert_eq!(
            unsafe {
                totaldrop_mobile_session_accept_offer(
                    recv_handle,
                    cstr(&dst_dir.to_string_lossy()).as_ptr(),
                )
            },
            FFI_OK
        );

        let recv_done = poll_events_until(recv_handle, Duration::from_secs(15), |ev| {
            ev["event"] == "done" || ev["event"] == "failed"
        });
        assert_eq!(recv_done.last().unwrap()["event"], "done");
        assert_eq!(
            std::fs::read(dst_dir.join("ios-sample.bin")).unwrap(),
            payload
        );

        let send_done = poll_events_until(send_handle, Duration::from_secs(15), |ev| {
            ev["event"] == "done" || ev["event"] == "failed"
        });
        assert_eq!(send_done.last().unwrap()["event"], "done");

        assert_eq!(totaldrop_mobile_session_destroy(send_handle), FFI_OK);
        assert_eq!(totaldrop_mobile_session_destroy(recv_handle), FFI_OK);

        // Text E2E with Bidi check
        let note = "iOS/tvOS note \u{202E}rtl";
        let text_send = unsafe {
            totaldrop_mobile_session_start_send_text(
                cstr(note).as_ptr(),
                cstr(&cfg).as_ptr(),
                cstr("en-US").as_ptr(),
                cstr("en_US").as_ptr(),
            )
        };
        let text_ready = poll_events_until(text_send, Duration::from_secs(10), |ev| {
            ev["event"] == "code_ready"
        });
        let text_code = text_ready.last().unwrap()["display_code"]
            .as_str()
            .unwrap()
            .to_owned();
        let text_recv = unsafe {
            totaldrop_mobile_session_start_receive(
                cstr(&text_code).as_ptr(),
                cstr(&cfg).as_ptr(),
                cstr("en-US").as_ptr(),
                cstr("en_US").as_ptr(),
            )
        };
        let text_offer = poll_events_until(text_recv, Duration::from_secs(15), |ev| {
            ev["event"] == "offer_ready" || ev["event"] == "failed"
        });
        assert_eq!(text_offer.last().unwrap()["is_text"], true);
        assert_eq!(
            unsafe { totaldrop_mobile_session_accept_offer(text_recv, ptr::null()) },
            FFI_OK
        );
        let text_done = poll_events_until(text_recv, Duration::from_secs(15), |ev| {
            ev["event"] == "done" || ev["event"] == "failed"
        });
        assert_eq!(
            text_done.last().unwrap()["sanitized_text"],
            "iOS/tvOS note <U+202E>rtl"
        );
        let _ = poll_events_until(text_send, Duration::from_secs(15), |ev| {
            ev["event"] == "done" || ev["event"] == "failed"
        });
        assert_eq!(totaldrop_mobile_session_destroy(text_send), FFI_OK);
        assert_eq!(totaldrop_mobile_session_destroy(text_recv), FFI_OK);

        rv_task.abort();
        let _ = std::fs::remove_dir_all(&temp_root);
    }
}
