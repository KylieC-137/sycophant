//! Workspace-scoped event log for resumable streaming.
//!
//! An append-only ND-JSON file (`event_log.jsonl`) at the workspace level on
//! the conversation PVC, alongside conversation directories. Each entry is
//! `{ seq, outbound }` where `outbound` is a base64-encoded protobuf
//! `ChannelOutbound`.
//!
//! The log is the single source of truth for the workspace-scoped sequence
//! counter. On construction the file is scanned and `next_seq` is set to
//! `last_seq + 1`. An empty or absent file yields `next_seq = 1`.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use prost::Message as ProstMessage;
use serde::{Deserialize, Serialize};

use proto_common::ChannelOutbound;

/// Filename of the event log under the workspace conversation directory.
const EVENT_LOG_FILENAME: &str = "event_log.jsonl";

/// One persisted event-log line: a workspace-scoped sequence number and the
/// base64-encoded protobuf bytes of the `ChannelOutbound` envelope.
#[derive(Serialize, Deserialize)]
struct EventRecord {
    seq: u64,
    /// Base64-encoded protobuf bytes of `ChannelOutbound`.
    outbound_b64: String,
}

/// Workspace-scoped event log. Thread-safe: the sequence counter is atomic
/// and appends are serialized by a tokio mutex.
pub(crate) struct EventLog {
    path: PathBuf,
    next_seq: AtomicU64,
    append_lock: tokio::sync::Mutex<()>,
}

impl EventLog {
    /// Construct an `EventLog` rooted at `dir`. On construction, scans the
    /// existing file (if any) to recover the last sequence number.
    pub(crate) fn new(dir: &Path) -> Self {
        let path = dir.join(EVENT_LOG_FILENAME);
        let last_seq = Self::scan_last_seq(&path);
        Self {
            path,
            next_seq: AtomicU64::new(last_seq + 1),
            append_lock: tokio::sync::Mutex::new(()),
        }
    }

    /// Atomically increment and return the next workspace-scoped sequence
    /// number. 1-indexed.
    pub(crate) fn next_seq(&self) -> u64 {
        self.next_seq.fetch_add(1, Ordering::SeqCst)
    }

    /// Append one event to the log file. Blocking I/O runs on a spawn_blocking
    /// task so callers can `.await` it. Returns `Err` on I/O failure.
    pub(crate) async fn append(&self, seq: u64, outbound: &ChannelOutbound) -> Result<(), String> {
        let bytes = outbound.encode_to_vec();
        let record = EventRecord {
            seq,
            outbound_b64: base64_encode(&bytes),
        };
        let mut line =
            serde_json::to_string(&record).map_err(|e| format!("serialize event record: {e}"))?;
        line.push('\n');

        let _guard = self.append_lock.lock().await;

        let path = self.path.clone();
        let parent = self
            .path
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_default();
        tokio::task::spawn_blocking(move || -> Result<(), String> {
            use std::io::Write;
            std::fs::create_dir_all(&parent)
                .map_err(|e| format!("create event-log dir: {e}"))?;
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .map_err(|e| format!("open event log {}: {e}", path.display()))?;
            file.write_all(line.as_bytes())
                .map_err(|e| format!("append event record {}: {e}", path.display()))
        })
        .await
        .map_err(|e| format!("append join error: {e}"))?
    }

    /// Read the log and return all entries with `seq > after_seq`, in order.
    pub(crate) fn replay_after(&self, after_seq: u64) -> Result<Vec<ChannelOutbound>, String> {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(format!("read event log: {e}")),
        };
        let mut entries = Vec::new();
        for line in text.lines() {
            if line.trim().is_empty() {
                continue;
            }
            let record: EventRecord = match serde_json::from_str(line) {
                Ok(r) => r,
                Err(e) => {
                    tracing::warn!(error = %e, "skipping unparsable event log line");
                    continue;
                }
            };
            if record.seq > after_seq {
                let bytes = base64_decode(&record.outbound_b64)
                    .map_err(|e| format!("decode event base64: {e}"))?;
                let outbound = ChannelOutbound::decode(bytes.as_slice())
                    .map_err(|e| format!("decode event protobuf: {e}"))?;
                entries.push(outbound);
            }
        }
        Ok(entries)
    }

    /// Scan the file for the last sequence number. Returns 0 when the file
    /// is absent or empty.
    fn scan_last_seq(path: &Path) -> u64 {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(_) => return 0,
        };
        let mut last = 0u64;
        for line in text.lines() {
            if line.trim().is_empty() {
                continue;
            }
            if let Ok(record) = serde_json::from_str::<EventRecord>(line) {
                if record.seq > last {
                    last = record.seq;
                }
            }
        }
        last
    }
}

fn base64_encode(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn base64_decode(s: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(s)
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use proto_common::{channel_outbound, ChannelAck};

    fn make_outbound(channel_id: &str) -> ChannelOutbound {
        ChannelOutbound {
            command: Some(channel_outbound::Command::Ack(ChannelAck {
                channel_id: channel_id.to_string(),
            })),
            workspace_seq: None,
        }
    }

    #[test]
    fn new_empty_dir_starts_at_seq_1() {
        let dir = tempfile::tempdir().unwrap();
        let log = EventLog::new(dir.path());
        assert_eq!(log.next_seq(), 1);
        assert_eq!(log.next_seq(), 2);
    }

    #[tokio::test]
    async fn append_and_replay() {
        let dir = tempfile::tempdir().unwrap();
        let log = EventLog::new(dir.path());

        let seq1 = log.next_seq();
        let out1 = make_outbound("ch-1");
        log.append(seq1, &out1).await.unwrap();

        let seq2 = log.next_seq();
        let out2 = make_outbound("ch-2");
        log.append(seq2, &out2).await.unwrap();

        // Replay from 0 returns everything.
        let all = log.replay_after(0).unwrap();
        assert_eq!(all.len(), 2);

        // Replay from seq1 returns only seq2.
        let after_1 = log.replay_after(seq1).unwrap();
        assert_eq!(after_1.len(), 1);

        // Replay from seq2 returns nothing.
        let after_2 = log.replay_after(seq2).unwrap();
        assert!(after_2.is_empty());
    }

    #[tokio::test]
    async fn survives_restart() {
        let dir = tempfile::tempdir().unwrap();
        {
            let log = EventLog::new(dir.path());
            let seq = log.next_seq();
            log.append(seq, &make_outbound("ch-1")).await.unwrap();
            let seq2 = log.next_seq();
            log.append(seq2, &make_outbound("ch-2")).await.unwrap();
        }
        // Reconstruct from disk — sequence counter must continue.
        let log = EventLog::new(dir.path());
        assert_eq!(log.next_seq(), 3);
        let entries = log.replay_after(0).unwrap();
        assert_eq!(entries.len(), 2);
    }

    #[tokio::test]
    async fn replay_absent_file_returns_empty() {
        let dir = tempfile::tempdir().unwrap();
        let log = EventLog::new(dir.path());
        let entries = log.replay_after(0).unwrap();
        assert!(entries.is_empty());
    }

    #[tokio::test]
    async fn tolerates_torn_trailing_line() {
        let dir = tempfile::tempdir().unwrap();
        let log = EventLog::new(dir.path());
        let seq = log.next_seq();
        log.append(seq, &make_outbound("ch-1")).await.unwrap();
        // Append a torn line.
        {
            use std::io::Write;
            let mut f = std::fs::OpenOptions::new()
                .append(true)
                .open(dir.path().join(EVENT_LOG_FILENAME))
                .unwrap();
            f.write_all(b"{\"seq\":99,\"outbound_b64\":\"AAAA").unwrap();
        }
        let entries = log.replay_after(0).unwrap();
        assert_eq!(entries.len(), 1, "the intact record before the tear is still replayed");
    }
}
