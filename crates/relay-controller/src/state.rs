//! In-memory state owned by the internet-facing gateway pod.
//!
//! The gateway does NOT own a conversation registry or event log — those
//! live in the per-workspace harness, reached via the
//! `HarnessClientPool`. The gateway owns the *live* surface:
//!
//! - `channels` — server-minted channel_id → outbound mpsc + per-channel
//!   turn phase + pending server-requests + advertised methods.
//! - `last_turn_state` — per-conversation last recorded phase, backing the
//!   `GetTurnState` poll.
//! - `SubscriberRegistry` — per-workspace broadcast bus the harness's
//!   `Subscribe` stream drains; `ChannelIngest` notifies it. Standalone
//!   because the gateway has no per-workspace conversation state to
//!   attach it to.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use proto_common::{
    channel_outbound, ChannelOutbound, ClientResponseError, Heartbeat, ServerRequest, TurnState,
    TurnStateEvent, UserMessage,
};
use tokio::sync::{broadcast, mpsc, oneshot, Mutex, RwLock};
use tokio::task::AbortHandle;

use crate::harness_client::HarnessClientPool;
use crate::identity::IdentityTable;

pub enum ServerRequestOutcome {
    /// Client returned a successful result; payload is `result_json`.
    Result(String),
    /// Client returned a structured error.
    Error(ClientResponseError),
}

/// Reasons a `send_server_request_and_await` call may fail without ever
/// reaching the client OR after dispatching but before a response.
#[derive(Debug)]
pub enum ServerRequestError {
    UnknownChannel,
    UnsupportedMethod,
    SendFailed,
    Timeout,
    Disconnected,
}

/// Who opened a channel. ChannelIngest admits only the same caller: a
/// person channel only its own subject, an adapter channel only that
/// adapter. An adapter channel also keeps the sender handle it was opened
/// for, so every message re-resolves that handle against the live identity
/// table and a removed handle binding cuts an open channel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChannelOpener {
    Person,
    Adapter { channel: String, sender: String },
}

/// Catch-up state for a channel that is replaying history. Channels
/// minted with `resume_after_seq` start in catch-up mode; live frames
/// arriving during catch-up are buffered and drained on transition.
pub struct CatchUpState {
    pub catching_up: bool,
    pub buffer: Vec<ChannelOutbound>,
}

/// Per-workspace high-water sequence and last-send timestamp. Updated
/// on every fan-out delivery so the heartbeat task can read the current
/// high-water seq without a per-frame lock.
pub struct WorkspaceSeqState {
    pub high_water_seq: u64,
    pub last_send: Instant,
}

/// Server-side state for one registered channel. Created via
/// `mint_channel`; lifetime tied to the originating ChannelReceive
/// response stream.
pub struct ChannelEntry {
    /// How the channel was opened; see [`ChannelOpener`].
    pub opener: ChannelOpener,
    /// The subject that minted this channel. ChannelIngest callers
    /// must verify against this binding (PermissionDenied on mismatch),
    /// so two subjects in one workspace cannot reach each other's channels.
    pub subject: String,
    /// The workspace the minting subject names. The harness link checks
    /// against this, because the harness knows workspaces and not subjects.
    pub workspace: String,
    pub tx: mpsc::Sender<ChannelOutbound>,
    /// Cluster-owned turn phase for the channel. `set_and_broadcast_turn_state`
    /// updates this and enqueues a frame under the same lock acquisition so
    /// replay on fresh ChannelReceive cannot race a live transition.
    pub current_state: Mutex<TurnState>,
    /// Client-advertised tool methods this channel can render. Updated
    /// on every `ChannelIngest` (last-sender-wins). The controller
    /// refuses to dispatch a `ServerRequest` whose method is not in
    /// this set.
    pub supported_methods: Mutex<HashSet<String>>,
    /// Catch-up state: channels with `resume_after_seq` start catching
    /// up; live frames are buffered until the transition to live.
    pub catchup: Mutex<CatchUpState>,
    /// Abort handle for the per-channel heartbeat task. `None` until the
    /// channel transitions to live (no heartbeats during catch-up).
    pub heartbeat_handle: Mutex<Option<AbortHandle>>,
}

/// Last recorded turn phase for one conversation. Backs `GetTurnState`
/// so a client that missed the pushed `TurnStateEvent` (reconnect, dropped
/// receive stream) can poll the controller-owned truth. `reason`/`code`
/// are populated only for `Failed`; empty otherwise.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurnStateRecord {
    pub state: TurnState,
    pub reason: String,
    pub code: String,
}

/// Per-workspace broadcast bus. The harness opens a `Subscribe`
/// stream per workspace and drains the matching sender; `ChannelIngest`
/// pushes inbound `UserMessage`s onto it. Capacity 16.
#[derive(Default)]
pub struct SubscriberRegistry {
    senders: RwLock<HashMap<String, broadcast::Sender<UserMessage>>>,
}

impl SubscriberRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Subscribe to a workspace's bus, creating the sender on first use.
    /// Returns a fresh receiver; the sender is retained so later
    /// `notify` calls and additional subscribers share one bus.
    pub async fn subscribe_or_create(&self, workspace: &str) -> broadcast::Receiver<UserMessage> {
        {
            let senders = self.senders.read().await;
            if let Some(tx) = senders.get(workspace) {
                return tx.subscribe();
            }
        }
        let mut senders = self.senders.write().await;
        senders
            .entry(workspace.to_string())
            .or_insert_with(|| broadcast::channel(16).0)
            .subscribe()
    }

    /// Push a message onto a workspace's bus. No-op (and no allocation)
    /// when no subscriber has ever opened the workspace — a message with
    /// no harness listening is dropped.
    pub async fn notify(&self, workspace: &str, message: UserMessage) {
        let senders = self.senders.read().await;
        if let Some(tx) = senders.get(workspace) {
            let _ = tx.send(message);
        }
    }
}

pub struct GatewayState {
    /// channel_id (UUID, server-minted) → ChannelEntry.
    channels: RwLock<HashMap<String, ChannelEntry>>,
    /// (subject, conversation_id) → last recorded turn phase. Keyed by
    /// the caller's verified subject so a `GetTurnState` poll can only read
    /// its own phase; conversation_id alone is a bare UUID and would
    /// leak across a tenant's subjects. Written on every turn-state
    /// broadcast; read by the poll.
    last_turn_state: RwLock<HashMap<(String, String), TurnStateRecord>>,
    /// Per-workspace inbound user-message bus.
    subscribers: SubscriberRegistry,
    /// The live identity table, swapped by the identity watcher on every
    /// relay-identity ConfigMap delivery. It answers the workspace list and
    /// resolves channel handles to subjects; authorization itself is a
    /// per-request Kubernetes review.
    identity: Arc<RwLock<IdentityTable>>,
    /// conversation_id → the subject that minted it. A cache, not the
    /// record: the harness holds the durable stamp. A miss resolves against
    /// the harness; it never reads as "unowned, therefore fine".
    conversation_owners: RwLock<HashMap<String, String>>,
    /// call_id → the (subject, workspace) that dispatched it. The relay
    /// mints the call_id (via the harness), so a CancelToolRequest — which
    /// carries no workspace — resolves its workspace here.
    dispatched_calls: RwLock<HashMap<String, (String, String)>>,
    kube_client: Option<kube::Client>,
    namespace: String,
    /// Pool of per-workspace harness clients for the tool forwards
    /// (`WatchTools`/`CallTool`) and the conversation-lifecycle forwards.
    harness_clients: Arc<HarnessClientPool>,
    /// Per-workspace capability grants the gateway serves on ListGrants,
    /// swapped by the toolset-grants watcher on every ConfigMap delivery. Names
    /// only; empty when no workspace has minted its ConfigMap yet.
    capabilities: Arc<RwLock<crate::capabilities::CapabilityGrants>>,
    idp_issuer: String,
    idp_audience: String,
    idp_certificate_authority: String,
    /// Workspace-wide pending server requests keyed by (workspace, request_id).
    /// Moved from per-channel to workspace-wide so a `ClientResponse` from any
    /// workspace channel resolves the awaiter.
    pending_server_requests: RwLock<HashMap<(String, String), oneshot::Sender<ServerRequestOutcome>>>,
    /// Per-workspace high-water seq and last-send timestamp. Updated on every
    /// sequenced fan-out so the heartbeat task reads the current high-water
    /// seq without a per-frame lock.
    workspace_seq: RwLock<HashMap<String, WorkspaceSeqState>>,
    /// Heartbeat interval. Channels that are idle longer than this receive a
    /// `Heartbeat { workspace_seq }` frame. `Duration::ZERO` disables heartbeats.
    heartbeat_interval: Duration,
}

impl GatewayState {
    pub fn new(kube_client: Option<kube::Client>, namespace: String) -> Self {
        let harness_clients = HarnessClientPool::new(&namespace);
        Self {
            channels: RwLock::new(HashMap::new()),
            last_turn_state: RwLock::new(HashMap::new()),
            subscribers: SubscriberRegistry::new(),
            identity: Arc::new(RwLock::new(IdentityTable::default())),
            conversation_owners: RwLock::new(HashMap::new()),
            dispatched_calls: RwLock::new(HashMap::new()),
            kube_client,
            namespace,
            harness_clients,
            capabilities: Arc::new(RwLock::new(crate::capabilities::CapabilityGrants::default())),
            idp_issuer: String::new(),
            idp_audience: String::new(),
            idp_certificate_authority: String::new(),
            pending_server_requests: RwLock::new(HashMap::new()),
            workspace_seq: RwLock::new(HashMap::new()),
            heartbeat_interval: Duration::from_secs(15),
        }
    }

    /// Set the heartbeat interval. `Duration::ZERO` disables heartbeats.
    pub fn set_heartbeat_interval(&mut self, interval: Duration) {
        self.heartbeat_interval = interval;
    }

    /// The configured heartbeat interval.
    pub fn heartbeat_interval(&self) -> Duration {
        self.heartbeat_interval
    }

    /// Construct a `GatewayState` with IdP configuration.
    pub fn new_with_idp(
        kube_client: Option<kube::Client>,
        namespace: String,
        idp_issuer: String,
        idp_audience: String,
        idp_certificate_authority: String,
    ) -> Self {
        Self {
            idp_issuer,
            idp_audience,
            idp_certificate_authority,
            ..Self::new(kube_client, namespace)
        }
    }

    /// Like [`GatewayState::new`], but the harness pool dials `template`
    /// (`{workspace}` substituted) instead of the in-cluster Service DNS, so a
    /// test can stand a harness up on a loopback port.
    #[cfg(any(test, feature = "test-fixtures"))]
    pub fn with_harness_template(
        kube_client: Option<kube::Client>,
        namespace: String,
        template: String,
    ) -> Self {
        Self {
            harness_clients: HarnessClientPool::from_service_template(template),
            ..Self::new(kube_client, namespace)
        }
    }

    /// Shared handle on the live ListGrants table. The toolset-grants watcher
    /// writes through it; `list_grants` reads through it.
    pub fn capabilities(&self) -> Arc<RwLock<crate::capabilities::CapabilityGrants>> {
        self.capabilities.clone()
    }

    /// Shared handle on the live identity table. The identity watcher writes
    /// through it; the workspace-list answer and handle resolution read it.
    pub fn identity(&self) -> Arc<RwLock<IdentityTable>> {
        self.identity.clone()
    }

    /// Returns the IdP configuration (issuer, audience, certificate_authority).
    pub fn idp_config(&self) -> (&str, &str, &str) {
        (&self.idp_issuer, &self.idp_audience, &self.idp_certificate_authority)
    }

    /// The subject a conversation is cached under, if the relay has seen
    /// it since this process started.
    pub async fn conversation_owner(&self, conversation_id: &str) -> Option<String> {
        self.conversation_owners
            .read()
            .await
            .get(conversation_id)
            .cloned()
    }

    /// Cache a conversation's owning subject after minting it or resolving
    /// it against the harness.
    pub async fn record_conversation_owner(&self, conversation_id: &str, subject: &str) {
        self.conversation_owners
            .write()
            .await
            .insert(conversation_id.to_string(), subject.to_string());
    }

    /// Record which (subject, workspace) dispatched a call, so a later
    /// CancelToolRequest resolves its workspace without a wire field.
    pub async fn record_dispatched_call(&self, call_id: &str, subject: &str, workspace: &str) {
        self.dispatched_calls.write().await.insert(
            call_id.to_string(),
            (subject.to_string(), workspace.to_string()),
        );
    }

    /// The (subject, workspace) a call_id was dispatched under, if the relay
    /// has seen it since this process started.
    pub async fn dispatched_call(&self, call_id: &str) -> Option<(String, String)> {
        self.dispatched_calls.read().await.get(call_id).cloned()
    }

    pub fn kube_client(&self) -> Option<&kube::Client> {
        self.kube_client.as_ref()
    }

    pub fn namespace(&self) -> &str {
        &self.namespace
    }

    pub fn harness_clients(&self) -> &Arc<HarnessClientPool> {
        &self.harness_clients
    }

    pub async fn subscribe_or_create(&self, workspace: &str) -> broadcast::Receiver<UserMessage> {
        self.subscribers.subscribe_or_create(workspace).await
    }

    pub async fn notify_subscriber(&self, workspace: &str, message: UserMessage) {
        self.subscribers.notify(workspace, message).await;
    }

    /// Mint a fresh channel_id (UUID), bind it to the minting subject
    /// and that subject's workspace, and store the tx for outbound routing.
    /// `catching_up` controls whether the channel starts in catch-up mode
    /// (buffering live frames until `transition_to_live` is called).
    /// Returns the channel_id; the caller is responsible for echoing it
    /// back to the adapter as the first frame of the outbound stream
    /// (ChannelAck).
    pub async fn mint_channel(
        &self,
        opener: ChannelOpener,
        subject: String,
        workspace: String,
        tx: mpsc::Sender<ChannelOutbound>,
        catching_up: bool,
    ) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        self.channels.write().await.insert(
            id.clone(),
            ChannelEntry {
                opener,
                subject,
                workspace,
                tx,
                current_state: Mutex::new(TurnState::Idle),
                supported_methods: Mutex::new(HashSet::new()),
                catchup: Mutex::new(CatchUpState {
                    catching_up,
                    buffer: Vec::new(),
                }),
                heartbeat_handle: Mutex::new(None),
            },
        );
        id
    }

    pub async fn unregister_channel(&self, channel_id: &str) {
        if let Some(entry) = self.channels.write().await.remove(channel_id) {
            // Cancel the per-channel heartbeat task if running.
            if let Some(handle) = entry.heartbeat_handle.lock().await.take() {
                handle.abort();
            }
        }
    }

    /// Return all channel_ids bound to `workspace`.
    pub async fn channels_for_workspace(&self, workspace: &str) -> Vec<String> {
        self.channels
            .read()
            .await
            .iter()
            .filter(|(_, e)| e.workspace == workspace)
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// Fan out a frame to all channels in `workspace`. Catching-up
    /// channels buffer the frame; live channels send directly. Returns
    /// the number of channels the frame was delivered to (live sends
    /// that succeeded).
    pub async fn send_to_workspace(&self, workspace: &str, msg: ChannelOutbound) -> usize {
        let channels = self.channels.read().await;
        let mut delivered = 0;
        for entry in channels.values().filter(|e| e.workspace == workspace) {
            let mut catchup = entry.catchup.lock().await;
            if catchup.catching_up {
                catchup.buffer.push(msg.clone());
            } else {
                if entry.tx.send(msg.clone()).await.is_ok() {
                    delivered += 1;
                }
            }
        }
        // Update workspace seq tracking if the frame carries a seq.
        if let Some(seq) = msg.workspace_seq {
            self.update_workspace_seq(workspace, seq).await;
        }
        delivered
    }

    /// Transition a channel from catching-up to live: drain the buffer,
    /// then clear the flag. Returns false if the channel does not exist.
    pub async fn transition_to_live(&self, channel_id: &str) -> bool {
        let channels = self.channels.read().await;
        let Some(entry) = channels.get(channel_id) else {
            return false;
        };
        let mut catchup = entry.catchup.lock().await;
        let buffer = std::mem::take(&mut catchup.buffer);
        catchup.catching_up = false;
        // Send all buffered frames now that we're live.
        for frame in buffer {
            let _ = entry.tx.send(frame).await;
        }
        true
    }

    /// Update the workspace high-water sequence and last-send timestamp.
    pub async fn update_workspace_seq(&self, workspace: &str, seq: u64) {
        let mut map = self.workspace_seq.write().await;
        let entry = map.entry(workspace.to_string()).or_insert_with(|| WorkspaceSeqState {
            high_water_seq: 0,
            last_send: Instant::now(),
        });
        if seq > entry.high_water_seq {
            entry.high_water_seq = seq;
        }
        entry.last_send = Instant::now();
    }

    /// Read the current high-water seq for a workspace. Returns 0 if
    /// no sequenced frame has been delivered yet.
    pub async fn workspace_high_water_seq(&self, workspace: &str) -> u64 {
        self.workspace_seq
            .read()
            .await
            .get(workspace)
            .map(|s| s.high_water_seq)
            .unwrap_or(0)
    }

    /// Spawn a per-channel heartbeat task. The task sends a `Heartbeat`
    /// frame when the channel has been idle for `interval`. Stores the
    /// abort handle on the channel entry so `unregister_channel` cancels
    /// it. No-op when `interval` is zero.
    pub async fn spawn_heartbeat(
        self: &Arc<Self>,
        channel_id: &str,
        interval: Duration,
    ) {
        if interval.is_zero() {
            return;
        }
        let channels = self.channels.read().await;
        let Some(entry) = channels.get(channel_id) else {
            return;
        };
        let workspace = entry.workspace.clone();
        let tx = entry.tx.clone();
        let state = self.clone();
        let channel_id_owned = channel_id.to_string();
        let task = tokio::spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            ticker.tick().await; // First tick is immediate, skip it.
            loop {
                ticker.tick().await;
                // Check if the channel is still catching up — no heartbeats during catch-up.
                {
                    let channels = state.channels.read().await;
                    let Some(e) = channels.get(&channel_id_owned) else {
                        break;
                    };
                    if e.catchup.lock().await.catching_up {
                        continue;
                    }
                }
                let seq = state.workspace_high_water_seq(&workspace).await;
                let msg = ChannelOutbound {
                    command: Some(channel_outbound::Command::Heartbeat(Heartbeat {
                        workspace_seq: seq,
                    })),
                    workspace_seq: None,
                };
                if tx.send(msg).await.is_err() {
                    break;
                }
            }
        });
        let abort_handle = task.abort_handle();
        *entry.heartbeat_handle.lock().await = Some(abort_handle);
    }

    /// Return who opened a channel_id and the `(subject, workspace)` it is
    /// bound to, in one read, or None if unknown. ChannelIngest admits only
    /// the caller that opened it. A caller that needs more than one field must
    /// not take two locks: the channel can be unregistered between them,
    /// leaving the second lookup empty while the first said the channel was
    /// live.
    pub async fn channel_binding(
        &self,
        channel_id: &str,
    ) -> Option<(ChannelOpener, String, String)> {
        self.channels.read().await.get(channel_id).map(|entry| {
            (
                entry.opener.clone(),
                entry.subject.clone(),
                entry.workspace.clone(),
            )
        })
    }

    pub async fn send_to_channel(&self, channel_id: &str, msg: ChannelOutbound) -> bool {
        let channels = self.channels.read().await;
        if let Some(entry) = channels.get(channel_id) {
            entry.tx.send(msg).await.is_ok()
        } else {
            false
        }
    }

    /// Update the channel's turn phase AND enqueue a matching
    /// `TurnStateEvent` on its outbound mpsc, both under the per-channel
    /// `current_state` mutex. The lock acquisition serialises live
    /// transitions against replay-on-reconnect reads, so a client never
    /// sees a stale state after a fresh ChannelReceive's replay frame.
    /// Returns false if the channel is no longer registered.
    pub async fn set_and_broadcast_turn_state(
        &self,
        channel_id: &str,
        subject: &str,
        conversation_id: &str,
        state: TurnState,
    ) -> bool {
        // Record before the channel lookup so the per-conversation phase is
        // captured even when the channel has gone away (client disconnected
        // mid-turn) — the client recovers it via GetTurnState on reconnect.
        self.record_turn_state(
            subject,
            conversation_id,
            TurnStateRecord {
                state,
                reason: String::new(),
                code: String::new(),
            },
        )
        .await;
        let channels = self.channels.read().await;
        let Some(entry) = channels.get(channel_id) else {
            return false;
        };
        let mut guard = entry.current_state.lock().await;
        *guard = state;
        let msg = ChannelOutbound {
            command: Some(channel_outbound::Command::TurnState(TurnStateEvent {
                state: state as i32,
                conversation_id: conversation_id.to_string(),
                ..Default::default()
            })),
            workspace_seq: None,
        };
        entry.tx.send(msg).await.is_ok()
    }

    /// Like `set_and_broadcast_turn_state`, but emits `FAILED` carrying a
    /// human-readable `reason` and a machine-readable `code`, and records
    /// the same so a later `GetTurnState` poll recovers the failure.
    /// Records before the channel lookup (a torn-down channel still needs
    /// the recorded FAILED for the reconnect poll). Returns false if the
    /// channel is no longer registered.
    pub async fn set_and_broadcast_turn_failed(
        &self,
        channel_id: &str,
        subject: &str,
        conversation_id: &str,
        reason: &str,
        code: &str,
    ) -> bool {
        self.record_turn_state(
            subject,
            conversation_id,
            TurnStateRecord {
                state: TurnState::Failed,
                reason: reason.to_string(),
                code: code.to_string(),
            },
        )
        .await;
        let channels = self.channels.read().await;
        let Some(entry) = channels.get(channel_id) else {
            return false;
        };
        let mut guard = entry.current_state.lock().await;
        *guard = TurnState::Failed;
        let msg = ChannelOutbound {
            command: Some(channel_outbound::Command::TurnState(TurnStateEvent {
                state: TurnState::Failed as i32,
                conversation_id: conversation_id.to_string(),
                reason: reason.to_string(),
                code: code.to_string(),
                ..Default::default()
            })),
            workspace_seq: None,
        };
        entry.tx.send(msg).await.is_ok()
    }

    /// Record the latest turn phase for a conversation so a later
    /// `GetTurnState` poll can recover it. Most-recent transition wins
    /// (unconditional overwrite). Empty `conversation_id` is ignored —
    /// channel-wide replay frames carry no conversation context and must
    /// not pollute the per-conversation map.
    pub async fn record_turn_state(
        &self,
        subject: &str,
        conversation_id: &str,
        record: TurnStateRecord,
    ) {
        if conversation_id.is_empty() {
            return;
        }
        self.last_turn_state
            .write()
            .await
            .insert((subject.to_string(), conversation_id.to_string()), record);
    }

    /// Read the recorded turn phase for a conversation. `None` when no
    /// transition has been recorded (fresh conversation, or the map was
    /// lost to a controller restart) — the `GetTurnState` handler maps
    /// that to IDLE, since absence of a record is not a failure.
    pub async fn turn_state_record(
        &self,
        subject: &str,
        conversation_id: &str,
    ) -> Option<TurnStateRecord> {
        self.last_turn_state
            .read()
            .await
            .get(&(subject.to_string(), conversation_id.to_string()))
            .cloned()
    }

    /// Replay the channel's current turn phase as a `TurnStateEvent`
    /// without modifying it. Used by `ChannelReceive` after the initial
    /// `ChannelAck` so fresh streams (reconnects, second-device opens)
    /// land in the correct visual state immediately. Emits an empty
    /// `conversation_id` — the channel's current_state is a per-channel
    /// summary, not per-conversation.
    pub async fn replay_turn_state(&self, channel_id: &str) -> bool {
        let channels = self.channels.read().await;
        let Some(entry) = channels.get(channel_id) else {
            return false;
        };
        let guard = entry.current_state.lock().await;
        let msg = ChannelOutbound {
            command: Some(channel_outbound::Command::TurnState(TurnStateEvent {
                state: *guard as i32,
                ..Default::default()
            })),
            workspace_seq: None,
        };
        entry.tx.send(msg).await.is_ok()
    }

    /// Replace the channel's advertised supported_methods set. Called by
    /// `channel_ingest` on every inbound request because the client may
    /// change devices (each device declares its own renderer set).
    /// Returns false if the channel is no longer registered.
    pub async fn update_supported_methods(&self, channel_id: &str, methods: Vec<String>) -> bool {
        let channels = self.channels.read().await;
        let Some(entry) = channels.get(channel_id) else {
            return false;
        };
        let mut guard = entry.supported_methods.lock().await;
        *guard = methods.into_iter().collect();
        true
    }

    /// Deliver a client's `ClientResponse` to whichever
    /// `send_server_request_and_await` awaiter is parked on the matching
    /// request_id. Returns true if a matching pending request was found
    /// and the outcome delivered; false otherwise (unknown workspace,
    /// unknown request_id, or awaiter already dropped — all benign).
    pub async fn deliver_client_response(
        &self,
        workspace: &str,
        request_id: &str,
        outcome: ServerRequestOutcome,
    ) -> bool {
        let key = (workspace.to_string(), request_id.to_string());
        let mut pending = self.pending_server_requests.write().await;
        let Some(sender) = pending.remove(&key) else {
            return false;
        };
        sender.send(outcome).is_ok()
    }

    /// Fire-and-forget notification to all channels in `workspace` that
    /// support `method`. Empty `request_id` on the wire signals to the
    /// client that no response is expected.
    pub async fn send_server_notification(
        &self,
        workspace: &str,
        method: &str,
        params_json: String,
        workspace_seq: Option<u64>,
    ) -> Result<(), ServerRequestError> {
        let channels = self.channels.read().await;
        let workspace_channels: Vec<_> = channels
            .values()
            .filter(|e| e.workspace == workspace)
            .collect();
        if workspace_channels.is_empty() {
            return Err(ServerRequestError::UnknownChannel);
        }
        let mut any_sent = false;
        for entry in workspace_channels {
            if !entry.supported_methods.lock().await.contains(method) {
                continue;
            }
            let msg = ChannelOutbound {
                command: Some(channel_outbound::Command::ServerRequest(ServerRequest {
                    request_id: String::new(),
                    method: method.to_string(),
                    params_json: params_json.clone(),
                })),
                workspace_seq,
            };
            let mut catchup = entry.catchup.lock().await;
            if catchup.catching_up {
                catchup.buffer.push(msg);
                any_sent = true;
            } else if entry.tx.send(msg).await.is_ok() {
                any_sent = true;
            }
        }
        if !any_sent {
            return Err(ServerRequestError::UnsupportedMethod);
        }
        if let Some(seq) = workspace_seq {
            drop(channels);
            self.update_workspace_seq(workspace, seq).await;
        }
        Ok(())
    }

    /// Dispatch a server-initiated request to the first channel in
    /// `workspace` that supports `method`, and await the matching
    /// `ClientResponse`. The pending-request registry is workspace-wide
    /// so a response from any channel in the workspace resolves it.
    ///
    /// Timeout cleanup is best-effort: on `Err(Timeout)` we remove the
    /// pending slot so a late `ClientResponse` doesn't leak memory. A
    /// late response arriving for a removed slot is dropped silently
    /// (deliver_client_response returns false).
    pub async fn send_server_request_and_await(
        self: &Arc<Self>,
        workspace: &str,
        request_id: &str,
        method: &str,
        params_json: String,
        timeout: Duration,
    ) -> Result<ServerRequestOutcome, ServerRequestError> {
        let (tx_oneshot, rx_oneshot) = oneshot::channel();
        {
            let channels = self.channels.read().await;
            let workspace_channels: Vec<_> = channels
                .values()
                .filter(|e| e.workspace == workspace)
                .collect();
            if workspace_channels.is_empty() {
                return Err(ServerRequestError::UnknownChannel);
            }
            // Check that at least one channel supports the method.
            let any_supports = {
                let mut found = false;
                for entry in &workspace_channels {
                    if entry.supported_methods.lock().await.contains(method) {
                        found = true;
                        break;
                    }
                }
                found
            };
            if !any_supports {
                return Err(ServerRequestError::UnsupportedMethod);
            }
            // Register the pending request workspace-wide.
            self.pending_server_requests
                .write()
                .await
                .insert(
                    (workspace.to_string(), request_id.to_string()),
                    tx_oneshot,
                );
            // Fan out the ServerRequest to ALL workspace channels.
            let msg = ChannelOutbound {
                command: Some(channel_outbound::Command::ServerRequest(ServerRequest {
                    request_id: request_id.to_string(),
                    method: method.to_string(),
                    params_json,
                })),
                workspace_seq: None,
            };
            let mut any_sent = false;
            for entry in &workspace_channels {
                let mut catchup = entry.catchup.lock().await;
                if catchup.catching_up {
                    catchup.buffer.push(msg.clone());
                    any_sent = true;
                } else {
                    drop(catchup);
                    if entry.tx.send(msg.clone()).await.is_ok() {
                        any_sent = true;
                    }
                }
            }
            if !any_sent {
                self.pending_server_requests
                    .write()
                    .await
                    .remove(&(workspace.to_string(), request_id.to_string()));
                return Err(ServerRequestError::SendFailed);
            }
        }
        let workspace_owned = workspace.to_string();
        let request_id_owned = request_id.to_string();
        match tokio::time::timeout(timeout, rx_oneshot).await {
            Ok(Ok(outcome)) => Ok(outcome),
            Ok(Err(_)) => Err(ServerRequestError::Disconnected),
            Err(_) => {
                self.pending_server_requests
                    .write()
                    .await
                    .remove(&(workspace_owned, request_id_owned));
                Err(ServerRequestError::Timeout)
            }
        }
    }
}

/// Fixtures shared by the crate's unit tests.
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;

    pub(crate) fn make_state() -> Arc<GatewayState> {
        Arc::new(GatewayState::new(None, "default".into()))
    }

    /// Mint a person-opened channel for `subject` on `workspace`.
    pub(crate) async fn mint_person(
        state: &GatewayState,
        subject: &str,
        workspace: &str,
        tx: mpsc::Sender<ChannelOutbound>,
    ) -> String {
        state
            .mint_channel(ChannelOpener::Person, subject.into(), workspace.into(), tx, false)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{make_state, mint_person};
    use super::*;

    fn extract_turn_state(msg: &ChannelOutbound) -> Option<TurnState> {
        match &msg.command {
            Some(channel_outbound::Command::TurnState(e)) => TurnState::try_from(e.state).ok(),
            _ => None,
        }
    }

    fn extract_turn_state_event(msg: &ChannelOutbound) -> Option<&TurnStateEvent> {
        match &msg.command {
            Some(channel_outbound::Command::TurnState(e)) => Some(e),
            _ => None,
        }
    }

    #[tokio::test]
    async fn mint_channel_and_send() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(4);
        let id = mint_person(&state, "subject-alpha", "alpha", tx).await;
        assert!(
            state
                .send_to_channel(
                    &id,
                    ChannelOutbound {
                        command: Some(channel_outbound::Command::Ack(proto_common::ChannelAck {
                            channel_id: id.clone(),
                        })),
                        workspace_seq: None,
                    }
                )
                .await
        );
        let got = rx.recv().await.unwrap();
        assert!(matches!(
            got.command,
            Some(channel_outbound::Command::Ack(_))
        ));
    }

    #[tokio::test]
    async fn mint_channel_returns_unique_ids() {
        let state = make_state();
        let (tx, _rx) = mpsc::channel(1);
        let a = mint_person(&state, "subject-ws", "ws", tx.clone()).await;
        let b = mint_person(&state, "subject-ws", "ws", tx).await;
        assert_ne!(a, b, "each mint must produce a distinct channel_id");
    }

    #[tokio::test]
    async fn channel_binding_returns_opener_subject_workspace() {
        let state = make_state();
        let (tx, _rx) = mpsc::channel(1);
        let id = mint_person(&state, "subject-hello", "hello-world", tx).await;
        let (_, _, ws) = state
            .channel_binding(&id)
            .await
            .expect("channel must exist");
        assert_eq!(ws, "hello-world");
        assert!(state.channel_binding("nonexistent").await.is_none());
    }

    #[tokio::test]
    async fn send_to_channel_does_not_leak_to_other_channel() {
        let state = make_state();
        let (tx_a, mut rx_a) = mpsc::channel(4);
        let (tx_b, mut rx_b) = mpsc::channel(4);
        let a = mint_person(&state, "subject-ws", "ws", tx_a).await;
        let _b = mint_person(&state, "subject-ws", "ws", tx_b).await;
        state
            .send_to_channel(
                &a,
                ChannelOutbound {
                    command: Some(channel_outbound::Command::Ack(proto_common::ChannelAck {
                        channel_id: a.clone(),
                    })),
                    workspace_seq: None,
                },
            )
            .await;
        assert!(rx_a.recv().await.is_some());
        // b must not have received anything.
        assert!(rx_b.try_recv().is_err());
    }

    #[tokio::test]
    async fn unregister_channel_removes() {
        let state = make_state();
        let (tx, _rx) = mpsc::channel(1);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        state.unregister_channel(&id).await;
        assert!(state.channel_binding(&id).await.is_none());
    }

    #[tokio::test]
    async fn mint_channel_defaults_current_state_to_idle() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(4);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        assert!(state.replay_turn_state(&id).await);
        let msg = rx.recv().await.unwrap();
        assert_eq!(extract_turn_state(&msg), Some(TurnState::Idle));
    }

    #[tokio::test]
    async fn set_and_broadcast_turn_state_updates_state_and_emits_frame() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(4);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        assert!(
            state
                .set_and_broadcast_turn_state(&id, "subject-ws", "ws.conv-1", TurnState::Working)
                .await
        );
        let msg = rx.recv().await.unwrap();
        assert_eq!(extract_turn_state(&msg), Some(TurnState::Working));
    }

    #[tokio::test]
    async fn set_and_broadcast_turn_state_emits_conversation_id() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(4);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        assert!(
            state
                .set_and_broadcast_turn_state(&id, "subject-ws", "ws.conv-1", TurnState::Working)
                .await
        );
        let msg = rx.recv().await.unwrap();
        let event = extract_turn_state_event(&msg).unwrap();
        assert_eq!(event.conversation_id, "ws.conv-1");
        assert_eq!(event.state, TurnState::Working as i32);
    }

    #[tokio::test]
    async fn set_and_broadcast_turn_state_returns_false_for_unknown_channel() {
        let state = make_state();
        assert!(
            !state
                .set_and_broadcast_turn_state("ghost", "ws", "ws.conv", TurnState::Working)
                .await
        );
    }

    #[tokio::test]
    async fn turn_state_transitions_arrive_in_fifo_order() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(8);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        state
            .set_and_broadcast_turn_state(&id, "subject-ws", "ws.c", TurnState::Working)
            .await;
        state
            .set_and_broadcast_turn_state(&id, "subject-ws", "ws.c", TurnState::Idle)
            .await;
        let first = rx.recv().await.unwrap();
        let second = rx.recv().await.unwrap();
        assert_eq!(extract_turn_state(&first), Some(TurnState::Working));
        assert_eq!(extract_turn_state(&second), Some(TurnState::Idle));
    }

    #[tokio::test]
    async fn set_and_broadcast_turn_state_records_phase_for_poll() {
        let state = make_state();
        let (tx, _rx) = mpsc::channel(4);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        state
            .set_and_broadcast_turn_state(&id, "subject-ws", "ws.conv-x", TurnState::Working)
            .await;
        let rec = state
            .turn_state_record("subject-ws", "ws.conv-x")
            .await
            .unwrap();
        assert_eq!(rec.state, TurnState::Working);
    }

    #[tokio::test]
    async fn set_and_broadcast_records_even_when_channel_gone() {
        // The per-conversation record must survive a disconnected channel
        // so the reconnect poll recovers the phase.
        let state = make_state();
        state
            .set_and_broadcast_turn_state("ghost", "ws", "ws.conv-y", TurnState::Working)
            .await;
        let rec = state.turn_state_record("ws", "ws.conv-y").await.unwrap();
        assert_eq!(rec.state, TurnState::Working);
    }

    #[tokio::test]
    async fn set_and_broadcast_turn_failed_emits_and_records_reason_code() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(4);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        assert!(
            state
                .set_and_broadcast_turn_failed(
                    &id,
                    "subject-ws",
                    "ws.conv-z",
                    "inference job reaped",
                    "14"
                )
                .await
        );
        let msg = rx.recv().await.unwrap();
        let event = extract_turn_state_event(&msg).unwrap();
        assert_eq!(event.state, TurnState::Failed as i32);
        // Kills state.rs conversation_id in the failed broadcast event:
        // dropping the field defaults it to empty, so a client watching the
        // stream could not route the FAILED frame to the right conversation.
        assert_eq!(event.conversation_id, "ws.conv-z");
        assert_eq!(event.reason, "inference job reaped");
        assert_eq!(event.code, "14");
        let rec = state
            .turn_state_record("subject-ws", "ws.conv-z")
            .await
            .unwrap();
        assert_eq!(rec.state, TurnState::Failed);
        assert_eq!(rec.reason, "inference job reaped");
        assert_eq!(rec.code, "14");
    }

    #[tokio::test]
    async fn turn_state_record_absent_for_unknown_conversation() {
        let state = make_state();
        assert!(state.turn_state_record("ws", "ws.never").await.is_none());
    }

    #[tokio::test]
    async fn turn_state_record_scoped_to_subject() {
        let state = make_state();
        state
            .record_turn_state(
                "alice",
                "conv",
                TurnStateRecord {
                    state: TurnState::Working,
                    reason: String::new(),
                    code: String::new(),
                },
            )
            .await;
        assert!(state.turn_state_record("alice", "conv").await.is_some());
        // Another subject with the same conversation_id sees nothing.
        assert!(state.turn_state_record("bob", "conv").await.is_none());
    }

    #[tokio::test]
    async fn record_turn_state_ignores_empty_conversation_id() {
        let state = make_state();
        state
            .record_turn_state(
                "ws",
                "",
                TurnStateRecord {
                    state: TurnState::Working,
                    reason: String::new(),
                    code: String::new(),
                },
            )
            .await;
        assert!(state.turn_state_record("ws", "").await.is_none());
    }

    #[tokio::test]
    async fn notify_subscriber_routes_to_correct_workspace() {
        let state = make_state();
        let mut rx = state.subscribe_or_create("alpha").await;
        state
            .notify_subscriber(
                "alpha",
                UserMessage {
                    content: vec![],
                    sender: "u".into(),
                    reply_channel: Some("chan-1".into()),
                    conversation_id: "alpha.c".into(),
                    grants: vec![],
                },
            )
            .await;
        let got = rx.recv().await.unwrap();
        assert_eq!(got.sender, "u");
        assert_eq!(got.reply_channel.as_deref(), Some("chan-1"));
    }

    #[tokio::test]
    async fn notify_subscriber_does_not_leak_to_other_workspace() {
        let state = make_state();
        let mut alpha_rx = state.subscribe_or_create("alpha").await;
        let mut beta_rx = state.subscribe_or_create("beta").await;
        state
            .notify_subscriber(
                "alpha",
                UserMessage {
                    content: vec![],
                    sender: "only-alpha".into(),
                    reply_channel: None,
                    conversation_id: "alpha.c".into(),
                    grants: vec![],
                },
            )
            .await;
        assert_eq!(alpha_rx.recv().await.unwrap().sender, "only-alpha");
        assert!(
            beta_rx.try_recv().is_err(),
            "beta's bus must not receive alpha's message"
        );
    }

    #[tokio::test]
    async fn notify_unknown_workspace_is_noop() {
        // No subscriber has opened the workspace → message dropped, no panic.
        let state = make_state();
        state
            .notify_subscriber(
                "never-opened",
                UserMessage {
                    content: vec![],
                    sender: "x".into(),
                    reply_channel: None,
                    conversation_id: String::new(),
                    grants: vec![],
                },
            )
            .await;
    }

    #[tokio::test]
    async fn deliver_client_response_unknown_workspace_is_false() {
        let state = make_state();
        assert!(
            !state
                .deliver_client_response(
                    "ghost-ws",
                    "req-1",
                    ServerRequestOutcome::Result("{}".into())
                )
                .await
        );
    }

    #[tokio::test]
    async fn send_server_notification_unknown_workspace_errors() {
        let state = make_state();
        let err = state
            .send_server_notification("ghost-ws", "RevealPath", "{}".into(), None)
            .await
            .unwrap_err();
        assert!(matches!(err, ServerRequestError::UnknownChannel));
    }

    #[tokio::test]
    async fn send_server_notification_unsupported_method_errors() {
        let state = make_state();
        let (tx, _rx) = mpsc::channel(4);
        let _id = mint_person(&state, "subject-ws", "ws", tx).await;
        // No supported_methods advertised → unsupported.
        let err = state
            .send_server_notification("ws", "RevealPath", "{}".into(), None)
            .await
            .unwrap_err();
        assert!(matches!(err, ServerRequestError::UnsupportedMethod));
    }

    #[tokio::test]
    async fn send_server_notification_delivers_when_method_supported() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(4);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        state
            .update_supported_methods(&id, vec!["RevealPath".into()])
            .await;
        state
            .send_server_notification("ws", "RevealPath", "{\"p\":1}".into(), None)
            .await
            .unwrap();
        let msg = rx.recv().await.unwrap();
        match msg.command {
            Some(channel_outbound::Command::ServerRequest(sr)) => {
                assert_eq!(sr.method, "RevealPath");
                assert!(
                    sr.request_id.is_empty(),
                    "notification carries empty request_id"
                );
            }
            other => panic!("expected ServerRequest, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn send_server_notification_fans_out_to_workspace_channels() {
        let state = make_state();
        let (tx_a, mut rx_a) = mpsc::channel(4);
        let (tx_b, mut rx_b) = mpsc::channel(4);
        let id_a = mint_person(&state, "subject-ws", "ws", tx_a).await;
        let id_b = mint_person(&state, "subject-ws", "ws", tx_b).await;
        state
            .update_supported_methods(&id_a, vec!["RevealPath".into()])
            .await;
        state
            .update_supported_methods(&id_b, vec!["RevealPath".into()])
            .await;
        state
            .send_server_notification("ws", "RevealPath", "{}".into(), None)
            .await
            .unwrap();
        assert!(rx_a.recv().await.is_some(), "channel a must receive");
        assert!(rx_b.recv().await.is_some(), "channel b must receive");
    }

    #[tokio::test]
    async fn send_server_request_and_await_rejects_unsupported_method_without_dispatch() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(4);
        let _id = mint_person(&state, "subject-ws", "ws", tx).await;
        // No supported_methods advertised → reject before dispatch.
        let result = state
            .send_server_request_and_await(
                "ws",
                "req-1",
                "AskUser",
                "{}".into(),
                Duration::from_millis(200),
            )
            .await;
        assert!(matches!(result, Err(ServerRequestError::UnsupportedMethod)));
        assert!(
            rx.try_recv().is_err(),
            "no frame should be dispatched for an unsupported method"
        );
    }

    #[tokio::test]
    async fn send_server_request_and_await_times_out_and_cleans_up() {
        tokio::time::pause();
        let state = make_state();
        let (tx, _rx) = mpsc::channel(4);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        state
            .update_supported_methods(&id, vec!["AskUser".into()])
            .await;
        let handle = tokio::spawn(async move {
            state
                .send_server_request_and_await(
                    "ws",
                    "req-1",
                    "AskUser",
                    "{}".into(),
                    Duration::from_secs(5),
                )
                .await
        });
        tokio::time::advance(Duration::from_secs(6)).await;
        let result = handle.await.unwrap();
        assert!(matches!(result, Err(ServerRequestError::Timeout)));
    }

    #[tokio::test]
    async fn send_server_request_and_await_delivers_client_response() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(4);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        state
            .update_supported_methods(&id, vec!["AskUser".into()])
            .await;
        let state_for_await = state.clone();
        let handle = tokio::spawn(async move {
            state_for_await
                .send_server_request_and_await(
                    "ws",
                    "req-7",
                    "AskUser",
                    "{}".into(),
                    Duration::from_secs(5),
                )
                .await
        });
        // Drain the dispatched ServerRequest frame, then deliver a response.
        let _frame = tokio::time::timeout(Duration::from_secs(1), rx.recv())
            .await
            .expect("ServerRequest frame must be dispatched before await")
            .unwrap();
        assert!(
            !state
                .deliver_client_response("", "req-7", ServerRequestOutcome::Result("ok".into()))
                .await,
            "empty workspace should not match"
        );
        assert!(
            state
                .deliver_client_response("ws", "req-7", ServerRequestOutcome::Result("ok".into()))
                .await
        );
        let outcome = handle.await.unwrap().unwrap();
        match outcome {
            ServerRequestOutcome::Result(s) => assert_eq!(s, "ok"),
            ServerRequestOutcome::Error(_) => panic!("expected Result outcome"),
        }
    }

    #[tokio::test]
    async fn update_supported_methods_unknown_channel_is_false() {
        let state = make_state();
        assert!(
            !state
                .update_supported_methods("ghost", vec!["X".into()])
                .await
        );
    }

    #[tokio::test]
    async fn send_to_workspace_fans_out_to_all_live_channels() {
        let state = make_state();
        let (tx_a, mut rx_a) = mpsc::channel(4);
        let (tx_b, mut rx_b) = mpsc::channel(4);
        let _a = mint_person(&state, "subject-ws", "ws", tx_a).await;
        let _b = mint_person(&state, "subject-ws", "ws", tx_b).await;
        let msg = ChannelOutbound {
            command: Some(channel_outbound::Command::Ack(proto_common::ChannelAck {
                channel_id: "test".into(),
            })),
            workspace_seq: Some(5),
        };
        let delivered = state.send_to_workspace("ws", msg).await;
        assert_eq!(delivered, 2);
        assert!(rx_a.recv().await.is_some());
        assert!(rx_b.recv().await.is_some());
    }

    #[tokio::test]
    async fn send_to_workspace_buffers_for_catching_up_channels() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(4);
        // Mint a catching-up channel.
        let id = state
            .mint_channel(ChannelOpener::Person, "s".into(), "ws".into(), tx, true)
            .await;
        let msg = ChannelOutbound {
            command: Some(channel_outbound::Command::Ack(proto_common::ChannelAck {
                channel_id: "test".into(),
            })),
            workspace_seq: Some(1),
        };
        let delivered = state.send_to_workspace("ws", msg).await;
        assert_eq!(delivered, 0, "catching-up channel should not count as delivered");
        assert!(rx.try_recv().is_err(), "catching-up channel should not receive");

        // Transition to live drains the buffer.
        assert!(state.transition_to_live(&id).await);
        let got = rx.recv().await.unwrap();
        assert!(matches!(got.command, Some(channel_outbound::Command::Ack(_))));
    }

    #[tokio::test]
    async fn channels_for_workspace_returns_matching_channels() {
        let state = make_state();
        let (tx, _rx) = mpsc::channel(1);
        let _a = mint_person(&state, "s", "alpha", tx.clone()).await;
        let _b = mint_person(&state, "s", "alpha", tx.clone()).await;
        let _c = mint_person(&state, "s", "beta", tx).await;
        let alpha_channels = state.channels_for_workspace("alpha").await;
        assert_eq!(alpha_channels.len(), 2);
        let beta_channels = state.channels_for_workspace("beta").await;
        assert_eq!(beta_channels.len(), 1);
    }

    #[tokio::test]
    async fn workspace_high_water_seq_tracks_max() {
        let state = make_state();
        assert_eq!(state.workspace_high_water_seq("ws").await, 0);
        state.update_workspace_seq("ws", 5).await;
        assert_eq!(state.workspace_high_water_seq("ws").await, 5);
        state.update_workspace_seq("ws", 3).await;
        assert_eq!(state.workspace_high_water_seq("ws").await, 5, "should not decrease");
        state.update_workspace_seq("ws", 10).await;
        assert_eq!(state.workspace_high_water_seq("ws").await, 10);
    }
}
