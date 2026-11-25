// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Static 2-thread Tokio runtime, monotonic `u64` transfer session registry,
//! and NDJSON event stream engine for `totaldrop-apple-mobile-ffi`.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use serde::{Deserialize, Serialize};
use tokio::sync::oneshot;
use totaldrop_apple_mobile_bridge::{
    AppleMobileL10n, MobileStopToken, MobileTransferConfig, UNIVERSAL_LINK_PREFIX,
    connect_mobile_receive, format_voiceover_code, localize_mobile_error, prepare_mobile_send,
};
use totaldrop_core::{Error as CoreError, Event, PreparedSend, TEXT_FILE, check_destination};
use totaldrop_l10n::{Arg, Strings};

use crate::{
    FFI_ERR_INVALID_ARG, FFI_ERR_INVALID_HANDLE, FFI_ERR_INVALID_STATE, FFI_OK,
    compute_progress_parts,
};

/// Maximum queued events per session before oldest progress ticks are coalesced.
const MAX_QUEUED_EVENTS: usize = 256;

/// Maximum top-level names rendered inline on iOS/tvOS offer previews.
const MAX_OFFER_PREVIEW_NAMES: usize = 10;

/// Static 2-thread Tokio runtime driving all async QUIC, crypto, and disk I/O
/// off SwiftUI `@MainActor` threads (ADR 0009).
static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .thread_name("totaldrop-ios")
        .build()
        .unwrap_or_else(|_| std::process::abort())
});

static NEXT_SESSION_ID: AtomicU64 = AtomicU64::new(1);

static SESSIONS: LazyLock<Mutex<HashMap<u64, Arc<SessionEntry>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// JSON-deserializable network and transfer config preserving explicit empty
/// relay/stun strings for loopback tests.
#[derive(Debug, Default, Deserialize)]
pub(crate) struct FfiMobileConfig {
    server: Option<String>,
    relay: Option<String>,
    stun: Option<String>,
    #[serde(default)]
    privacy_mode: bool,
    #[serde(default)]
    stronger_code: bool,
}

impl FfiMobileConfig {
    pub(crate) fn into_mobile_config(self) -> MobileTransferConfig {
        let defaults = MobileTransferConfig::default();
        MobileTransferConfig {
            server: self.server.unwrap_or(defaults.server),
            relay: self.relay.unwrap_or(defaults.relay),
            stun: self.stun.unwrap_or(defaults.stun),
            privacy_mode: self.privacy_mode,
            stronger_code: self.stronger_code,
        }
    }
}

#[derive(Debug)]
enum OfferDecision {
    Accept { dest_dir: Option<PathBuf> },
    Decline,
}

/// NDJSON event emitted by `totaldrop_mobile_session_poll_events_ndjson`.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub(crate) enum MobileSessionEvent {
    CodeReady {
        display_code: String,
        canonical_code: String,
        universal_link: String,
        voiceover_spoken_code: String,
        share_message: String,
        entries: usize,
        total_bytes: u64,
        formatted_total: String,
        skipped: usize,
        is_text: bool,
    },
    Waiting {
        headline: String,
    },
    Connected {
        verification_words: Vec<String>,
        joined_words_ltr: String,
    },
    OfferReady {
        files: usize,
        dirs: usize,
        total_bytes: u64,
        formatted_size: String,
        is_text: bool,
        headline: String,
        summary_line: String,
        top_level_names: Vec<String>,
        remaining_names: usize,
        more_names_line: Option<String>,
        has_hidden_controls: bool,
        verification_words: Vec<String>,
        joined_words_ltr: String,
    },
    Progress {
        done_bytes: u64,
        total_bytes: u64,
        percent_value: u8,
        percent_text: String,
        done_bytes_text: String,
        total_bytes_text: String,
        fraction_text: String,
    },
    Done {
        files_ok: usize,
        files_failed: usize,
        bytes: u64,
        formatted_bytes: String,
        is_text: bool,
        saved_to: Option<String>,
        placed: Vec<String>,
        received_text: Option<String>,
        sanitized_text: Option<String>,
        text_shortened: bool,
        text_had_hidden_controls: bool,
    },
    Declined {
        is_text: bool,
        headline: String,
    },
    Failed {
        headline: String,
        cause: Option<String>,
        technical_detail: String,
    },
}

impl MobileSessionEvent {
    fn from_core_error(error: &CoreError, is_sender: bool, l10n: &AppleMobileL10n) -> Self {
        let (headline, cause, technical_detail) = localize_mobile_error(error, is_sender, l10n);
        Self::Failed {
            headline,
            cause,
            technical_detail,
        }
    }
}

struct SessionContext {
    l10n: AppleMobileL10n,
    strings: Strings,
}

struct SessionEntry {
    stop: MobileStopToken,
    events: Mutex<VecDeque<MobileSessionEvent>>,
    pending_decision: Mutex<Option<oneshot::Sender<OfferDecision>>>,
    pending_is_text: Mutex<Option<bool>>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl SessionEntry {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            stop: MobileStopToken::new(),
            events: Mutex::new(VecDeque::new()),
            pending_decision: Mutex::new(None),
            pending_is_text: Mutex::new(None),
            task: Mutex::new(None),
        })
    }

    fn push_event(&self, event: MobileSessionEvent) {
        if let Ok(mut queue) = self.events.lock() {
            if matches!(event, MobileSessionEvent::Progress { .. })
                && matches!(queue.back(), Some(MobileSessionEvent::Progress { .. }))
            {
                let _ = queue.pop_back();
            } else if queue.len() >= MAX_QUEUED_EVENTS {
                let _ = queue.pop_front();
            }
            queue.push_back(event);
        }
    }

    fn drain_ndjson(&self) -> String {
        let drained: Vec<MobileSessionEvent> = match self.events.lock() {
            Ok(mut queue) => queue.drain(..).collect(),
            Err(_) => return String::new(),
        };
        if drained.is_empty() {
            return String::new();
        }
        let mut out = String::new();
        for ev in drained {
            if let Ok(line) = serde_json::to_string(&ev) {
                out.push_str(&line);
                out.push('\n');
            }
        }
        out
    }

    fn set_pending_decision(&self, tx: oneshot::Sender<OfferDecision>, is_text: bool) {
        if let Ok(mut slot) = self.pending_is_text.lock() {
            *slot = Some(is_text);
        }
        if let Ok(mut slot) = self.pending_decision.lock() {
            *slot = Some(tx);
        }
    }

    fn clear_pending_decision(&self) {
        if let Ok(mut slot) = self.pending_decision.lock() {
            *slot = None;
        }
        if let Ok(mut slot) = self.pending_is_text.lock() {
            *slot = None;
        }
    }

    fn take_pending_decision(&self) -> Option<(oneshot::Sender<OfferDecision>, bool)> {
        let tx = self.pending_decision.lock().ok()?.take()?;
        let is_text = self
            .pending_is_text
            .lock()
            .ok()
            .and_then(|mut s| s.take())
            .unwrap_or(false);
        Some((tx, is_text))
    }
}

fn register_session(entry: Arc<SessionEntry>) -> u64 {
    let id = NEXT_SESSION_ID.fetch_add(1, Ordering::Relaxed);
    if let Ok(mut map) = SESSIONS.lock() {
        map.insert(id, entry);
    }
    id
}

fn lookup_session(handle: u64) -> Option<Arc<SessionEntry>> {
    if handle == 0 {
        return None;
    }
    SESSIONS.lock().ok()?.get(&handle).cloned()
}

fn join_words_ltr(words: &[String]) -> String {
    let joined = words.join(" \u{00B7} ");
    format!("\u{2066}{joined}\u{2069}")
}

fn make_event_callback(
    entry: Arc<SessionEntry>,
    ctx: Arc<SessionContext>,
) -> totaldrop_core::Events {
    Arc::new(move |ev| match ev {
        Event::Waiting => {
            entry.push_event(MobileSessionEvent::Waiting {
                headline: ctx.l10n.text("sendWaiting"),
            });
        }
        Event::Connected { words } => {
            let joined_words_ltr = join_words_ltr(&words);
            entry.push_event(MobileSessionEvent::Connected {
                verification_words: words,
                joined_words_ltr,
            });
        }
        Event::Progress { done, total } => {
            let parts = compute_progress_parts(done, total, &ctx.strings);
            let clamped = if total > 0 { done.min(total) } else { done };
            entry.push_event(MobileSessionEvent::Progress {
                done_bytes: clamped,
                total_bytes: total,
                percent_value: parts.percent_value,
                percent_text: parts.percent_text,
                done_bytes_text: parts.done_bytes_text,
                total_bytes_text: parts.total_bytes_text,
                fraction_text: parts.fraction_text,
            });
        }
    })
}

pub(crate) fn start_send_files(
    paths: Vec<PathBuf>,
    config: MobileTransferConfig,
    l10n: AppleMobileL10n,
    strings: Strings,
) -> u64 {
    let entry = SessionEntry::new();
    let handle = register_session(Arc::clone(&entry));
    let ctx = Arc::new(SessionContext { l10n, strings });
    let task_entry = Arc::clone(&entry);
    let task_ctx = Arc::clone(&ctx);

    let join = RUNTIME.spawn(async move {
        let prepared = match prepare_mobile_send(&config, paths, &task_entry.stop).await {
            Ok(p) => p,
            Err(err) => {
                task_entry.push_event(MobileSessionEvent::from_core_error(
                    &err,
                    true,
                    &task_ctx.l10n,
                ));
                return;
            }
        };
        run_prepared_send(prepared, false, task_entry, task_ctx).await;
    });

    if let Ok(mut slot) = entry.task.lock() {
        *slot = Some(join);
    }
    handle
}

pub(crate) fn start_send_text(
    text: String,
    config: MobileTransferConfig,
    l10n: AppleMobileL10n,
    strings: Strings,
) -> u64 {
    let entry = SessionEntry::new();
    let handle = register_session(Arc::clone(&entry));
    let ctx = Arc::new(SessionContext { l10n, strings });
    let task_entry = Arc::clone(&entry);
    let task_ctx = Arc::clone(&ctx);

    let join = RUNTIME.spawn(async move {
        if task_entry.stop.is_cancelled() {
            task_entry.push_event(MobileSessionEvent::from_core_error(
                &CoreError::Stopped,
                true,
                &task_ctx.l10n,
            ));
            return;
        }
        let opts = config.send_options();
        let prepared = tokio::select! {
            biased;
            res = PreparedSend::text(&opts, &text, TEXT_FILE) => res,
            () = task_entry.stop.as_core_stop().stopped() => Err(CoreError::Stopped),
        };
        let prepared = match prepared {
            Ok(p) => p,
            Err(err) => {
                task_entry.push_event(MobileSessionEvent::from_core_error(
                    &err,
                    true,
                    &task_ctx.l10n,
                ));
                return;
            }
        };
        run_prepared_send(prepared, true, task_entry, task_ctx).await;
    });

    if let Ok(mut slot) = entry.task.lock() {
        *slot = Some(join);
    }
    handle
}

async fn run_prepared_send(
    prepared: PreparedSend,
    is_text: bool,
    entry: Arc<SessionEntry>,
    ctx: Arc<SessionContext>,
) {
    let code = prepared.code().clone();
    let display_code = code.to_english();
    let universal_link = format!("{UNIVERSAL_LINK_PREFIX}{display_code}");
    let voiceover_spoken_code = format_voiceover_code(&display_code);
    let share_message = ctx
        .strings
        .get("sendShareText", &[("code", Arg::Text(&display_code))]);
    let (entries, total_bytes) = prepared.totals();
    let skipped = prepared.skipped();
    entry.push_event(MobileSessionEvent::CodeReady {
        display_code,
        canonical_code: code.canonical(),
        universal_link,
        voiceover_spoken_code,
        share_message,
        entries,
        total_bytes,
        formatted_total: ctx.l10n.format_bytes(total_bytes),
        skipped,
        is_text,
    });

    let cb = make_event_callback(Arc::clone(&entry), Arc::clone(&ctx));
    let stop_clone = entry.stop.as_core_stop().clone();
    match prepared.run_with(cb, stop_clone).await {
        Ok(report) => {
            entry.push_event(MobileSessionEvent::Done {
                files_ok: report.files_ok,
                files_failed: report.files_failed,
                bytes: report.bytes,
                formatted_bytes: ctx.l10n.format_bytes(report.bytes),
                is_text,
                saved_to: None,
                placed: Vec::new(),
                received_text: None,
                sanitized_text: None,
                text_shortened: false,
                text_had_hidden_controls: false,
            });
        }
        Err(err) => {
            entry.push_event(MobileSessionEvent::from_core_error(&err, true, &ctx.l10n));
        }
    }
}

pub(crate) fn start_receive(
    code_or_link: String,
    config: MobileTransferConfig,
    l10n: AppleMobileL10n,
    strings: Strings,
) -> u64 {
    let entry = SessionEntry::new();
    let handle = register_session(Arc::clone(&entry));
    let ctx = Arc::new(SessionContext { l10n, strings });
    let task_entry = Arc::clone(&entry);
    let task_ctx = Arc::clone(&ctx);

    let join = RUNTIME.spawn(async move {
        let offer = match connect_mobile_receive(&config, &code_or_link, &task_entry.stop).await {
            Ok(o) => o,
            Err(err) => {
                task_entry.push_event(MobileSessionEvent::from_core_error(
                    &err,
                    false,
                    &task_ctx.l10n,
                ));
                return;
            }
        };

        let summary = offer.summary();
        let is_text = summary.text;
        let formatted_size = task_ctx.l10n.format_bytes(summary.total_size);
        let headline = if is_text {
            task_ctx.l10n.text("receiveOfferText")
        } else {
            task_ctx.l10n.text("receiveOffer")
        };
        let summary_line = if is_text {
            task_ctx.l10n.text("receiveOfferTextNote")
        } else {
            let file_count = u64::try_from(summary.files).unwrap_or(u64::MAX);
            task_ctx.strings.get(
                "receiveOfferSummary",
                &[
                    ("files", Arg::Count(file_count)),
                    ("size", Arg::Text(&formatted_size)),
                ],
            )
        };

        let mut has_hidden_controls = false;
        let mut top_level_names =
            Vec::with_capacity(summary.top_level.len().min(MAX_OFFER_PREVIEW_NAMES));
        for (idx, raw) in summary.top_level.iter().enumerate() {
            let sanitized = task_ctx.l10n.sanitize_name(raw);
            if sanitized != *raw {
                has_hidden_controls = true;
            }
            if idx < MAX_OFFER_PREVIEW_NAMES {
                top_level_names.push(sanitized);
            }
        }
        let remaining_names = summary
            .top_level
            .len()
            .saturating_sub(top_level_names.len());
        let more_names_line = if remaining_names > 0 {
            let more_count = u64::try_from(remaining_names).unwrap_or(u64::MAX);
            Some(
                task_ctx
                    .strings
                    .get("receiveAndMore", &[("count", Arg::Count(more_count))]),
            )
        } else {
            None
        };

        let words = offer.words().to_vec();
        let joined_words_ltr = join_words_ltr(&words);
        let files_count = summary.files;
        let dirs_count = summary.dirs;
        let total_size = summary.total_size;

        let (tx, rx) = oneshot::channel::<OfferDecision>();
        task_entry.set_pending_decision(tx, is_text);

        task_entry.push_event(MobileSessionEvent::OfferReady {
            files: files_count,
            dirs: dirs_count,
            total_bytes: total_size,
            formatted_size,
            is_text,
            headline,
            summary_line,
            top_level_names,
            remaining_names,
            more_names_line,
            has_hidden_controls,
            verification_words: words,
            joined_words_ltr,
        });

        let decision = tokio::select! {
            biased;
            res = rx => res.ok(),
            () = task_entry.stop.as_core_stop().stopped() => None,
        };
        task_entry.clear_pending_decision();

        match decision {
            None => {
                let err = offer.stop().await;
                task_entry.push_event(MobileSessionEvent::from_core_error(
                    &err,
                    false,
                    &task_ctx.l10n,
                ));
            }
            Some(OfferDecision::Decline) => match offer.decline().await {
                Ok(()) => {
                    task_entry.push_event(MobileSessionEvent::Declined {
                        is_text,
                        headline: task_ctx.l10n.text("errorDeclined"),
                    });
                }
                Err(err) => {
                    task_entry.push_event(MobileSessionEvent::from_core_error(
                        &err,
                        false,
                        &task_ctx.l10n,
                    ));
                }
            },
            Some(OfferDecision::Accept { dest_dir }) => {
                if is_text {
                    match offer.accept_text_with(task_entry.stop.as_core_stop()).await {
                        Ok(report) => {
                            let raw_text = report.text.clone();
                            let sanitized = raw_text
                                .as_deref()
                                .map(|txt| task_ctx.l10n.sanitize_received_text(txt));
                            task_entry.push_event(MobileSessionEvent::Done {
                                files_ok: report.files_ok,
                                files_failed: report.files_failed,
                                bytes: report.bytes,
                                formatted_bytes: task_ctx.l10n.format_bytes(report.bytes),
                                is_text: true,
                                saved_to: None,
                                placed: Vec::new(),
                                received_text: raw_text,
                                sanitized_text: sanitized.as_ref().map(|s| s.0.clone()),
                                text_shortened: sanitized.as_ref().is_some_and(|s| s.1),
                                text_had_hidden_controls: sanitized.as_ref().is_some_and(|s| s.2),
                            });
                        }
                        Err(err) => {
                            task_entry.push_event(MobileSessionEvent::from_core_error(
                                &err,
                                false,
                                &task_ctx.l10n,
                            ));
                        }
                    }
                } else {
                    let Some(dest) = dest_dir else {
                        let err = offer.stop().await;
                        task_entry.push_event(MobileSessionEvent::from_core_error(
                            &err,
                            false,
                            &task_ctx.l10n,
                        ));
                        return;
                    };
                    if let Err(err) = check_destination(&dest) {
                        let _ = offer.stop().await;
                        task_entry.push_event(MobileSessionEvent::from_core_error(
                            &err,
                            false,
                            &task_ctx.l10n,
                        ));
                        return;
                    }
                    let cb = make_event_callback(Arc::clone(&task_entry), Arc::clone(&task_ctx));
                    match offer
                        .accept_with(&dest, cb, task_entry.stop.as_core_stop())
                        .await
                    {
                        Ok(report) => {
                            let placed: Vec<String> = report
                                .placed
                                .iter()
                                .map(|p| task_ctx.l10n.sanitize_name(&p.to_string_lossy()))
                                .collect();
                            task_entry.push_event(MobileSessionEvent::Done {
                                files_ok: report.files_ok,
                                files_failed: report.files_failed,
                                bytes: report.bytes,
                                formatted_bytes: task_ctx.l10n.format_bytes(report.bytes),
                                is_text: false,
                                saved_to: Some(dest.to_string_lossy().into_owned()),
                                placed,
                                received_text: None,
                                sanitized_text: None,
                                text_shortened: false,
                                text_had_hidden_controls: false,
                            });
                        }
                        Err(err) => {
                            task_entry.push_event(MobileSessionEvent::from_core_error(
                                &err,
                                false,
                                &task_ctx.l10n,
                            ));
                        }
                    }
                }
            }
        }
    });

    if let Ok(mut slot) = entry.task.lock() {
        *slot = Some(join);
    }
    handle
}

pub(crate) fn accept_offer(handle: u64, dest_dir: Option<PathBuf>) -> i32 {
    let Some(entry) = lookup_session(handle) else {
        return FFI_ERR_INVALID_HANDLE;
    };
    let is_text = entry
        .pending_is_text
        .lock()
        .ok()
        .and_then(|slot| *slot)
        .unwrap_or(false);
    if !is_text {
        let Some(ref dir) = dest_dir else {
            return FFI_ERR_INVALID_ARG;
        };
        if dir.as_os_str().is_empty() {
            return FFI_ERR_INVALID_ARG;
        }
    }
    let Some((tx, _)) = entry.take_pending_decision() else {
        return FFI_ERR_INVALID_STATE;
    };
    match tx.send(OfferDecision::Accept { dest_dir }) {
        Ok(()) => FFI_OK,
        Err(_) => FFI_ERR_INVALID_STATE,
    }
}

pub(crate) fn decline_offer(handle: u64) -> i32 {
    let Some(entry) = lookup_session(handle) else {
        return FFI_ERR_INVALID_HANDLE;
    };
    let Some((tx, _)) = entry.take_pending_decision() else {
        return FFI_ERR_INVALID_STATE;
    };
    match tx.send(OfferDecision::Decline) {
        Ok(()) => FFI_OK,
        Err(_) => FFI_ERR_INVALID_STATE,
    }
}

pub(crate) fn stop_session(handle: u64) -> i32 {
    let Some(entry) = lookup_session(handle) else {
        return FFI_ERR_INVALID_HANDLE;
    };
    entry.stop.cancel();
    entry.clear_pending_decision();
    FFI_OK
}

pub(crate) fn poll_events_ndjson(handle: u64) -> Option<String> {
    let entry = lookup_session(handle)?;
    Some(entry.drain_ndjson())
}

pub(crate) fn destroy_session(handle: u64) -> i32 {
    if handle == 0 {
        return FFI_ERR_INVALID_HANDLE;
    }
    let removed = SESSIONS.lock().ok().and_then(|mut map| map.remove(&handle));
    let Some(entry) = removed else {
        return FFI_ERR_INVALID_HANDLE;
    };
    entry.stop.cancel();
    entry.clear_pending_decision();
    if let Ok(mut slot) = entry.task.lock()
        && let Some(join) = slot.take()
    {
        join.abort();
    }
    FFI_OK
}
