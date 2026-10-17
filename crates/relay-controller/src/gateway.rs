//! `RelayGateway` service — the per-request-review external surface.
//!
//! Every workspace-scoped request names its workspace; CancelTool resolves
//! its workspace from the call_id. Authorization is a Kubernetes review per
//! request, keyed by the credential class the listener stamped:
//!
//! - **Person tokens** (app and terminal-client paths): the relay resolves
//!   the caller's subject by TokenReview of the bearer.
//! - **Adapter tokens**: the relay authenticates the adapter by a TokenReview
//!   pinned to the adapter audience, requires the adapter's
//!   ServiceAccount shape, resolves the reported sender through the identity
//!   table.
//!
//! Either way the named workspace is then checked with one
//! SubjectAccessReview for the resolved subject, under the relay's own
//! credential and in the relay's own namespace. The subject's live RBAC is
//! the whole answer, so removing a RoleBinding cuts access on the very next
//! request.
//!
//! Forwarding handlers (mint_conversation, list_conversations,
//! delete_conversation, cancel_turn, set_conversation_name,
//! get_conversation_history, watch_tools, dispatch_tool, await_tool_result,
//! cancel_tool) carry no durable state: the conversation log lives
//! in the per-workspace harness, so they pick the caller's harness from the
//! pool and pass the call through. A conversation is reachable only by the
//! subject that minted it.

use std::sync::Arc;

use futures::StreamExt;
use proto_common::{
    channel_outbound, AwaitToolResultRequest, CallToolRequest, CancelToolRequest,
    CancelToolResponse, CancelTurnRequest, CancelTurnResponse, CatchUpComplete, ChannelAck,
    ChannelIngestAck, ChannelIngestRequest, ChannelOutbound, ChannelReceiveRequest,
    DeleteConversationRequest, DeleteConversationResponse, DispatchToolResponse,
    GetConversationHistoryRequest, GetConversationHistoryResponse, GetTurnStateRequest,
    ListConversationsRequest, ListConversationsResponse, ListGrantsRequest, ListGrantsResponse,
    ListWorkspacesRequest, ListWorkspacesResponse, MintConversationRequest,
    MintConversationResponse, ReplayImpossible, SetConversationNameRequest,
    SetConversationNameResponse, ToolListUpdate, ToolResultFrame, ToolsetGrants, TurnState,
    TurnStateEvent, UserMessage, WatchToolsRequest,
};
use relay_proto::relay_gateway_server::RelayGateway;
use relay_proto::{DiscoverRequest, DiscoverResponse};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status};

use crate::harness_client::HarnessClient;
use crate::listener::ListenerClass;
use crate::state::{ChannelOpener, GatewayState};
use shared::auth::{
    build_subject_access_review, extract_bearer_token, review_token_username,
    serviceaccount_from_username, ADAPTER_RELAY_AUDIENCE,
};

/// Seconds to keep the channel's outbound side open after the client
/// half-closes. Just under the 60s default gRPC client deadline.
const CHANNEL_DRAIN_SECS: u64 = 55;

/// Server-side clamp ceiling for `SetConversationName`. Enforced before
/// the forward so a hostile name never reaches the harness.
const MAX_CONVERSATION_NAME_CHARS: usize = 200;

/// An adapter ServiceAccount is named `adapter-<channel>`; the channel is the
/// SA name minus this prefix.
const ADAPTER_SA_NAME_PREFIX: &str = "adapter-";

/// The authenticated identity one request runs under, stamped by the
/// per-listener class layer. Handlers branch on the class only to pick the
/// authorization path; the credential itself never reaches them.
#[derive(Clone, Debug)]
enum Caller {
    /// A person token presented on the app/terminal-client listener.
    Person { subject: String },
    /// An adapter ServiceAccount token presented on the adapter listener.
    Adapter { channel: String },
}

/// Fires `unregister_channel` after a drain delay when the held
/// outbound stream is dropped. Used by `channel_receive` to tie
/// channel-registry lifetime to the gRPC response stream's lifetime
/// instead of a wall-clock timer. The drain delay lets multi-frame
/// outbound replies that were queued at the moment of drop finish.
struct ChannelDropGuard {
    state: Arc<GatewayState>,
    channel_id: String,
}

impl Drop for ChannelDropGuard {
    fn drop(&mut self) {
        let state = self.state.clone();
        let channel_id = std::mem::take(&mut self.channel_id);
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(CHANNEL_DRAIN_SECS)).await;
            tracing::info!(
                channel_id = %channel_id,
                "channel_receive: drain elapsed after stream drop, unregistering channel"
            );
            state.unregister_channel(&channel_id).await;
        });
    }
}

/// Wraps an outbound stream with a `ChannelDropGuard`. When tonic drops
/// the response stream (client disconnect or request cancellation), the
/// guard's `Drop` schedules the drain-and-unregister task. While the
/// stream is alive, the channel stays registered indefinitely.
struct GuardedStream<S> {
    inner: S,
    _guard: ChannelDropGuard,
}

impl<S: futures::Stream + Unpin> futures::Stream for GuardedStream<S> {
    type Item = S::Item;

    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        std::pin::Pin::new(&mut self.inner).poll_next(cx)
    }
}

/// A boxed outbound stream of `T` frames, the shape every streaming RPC
/// returns.
type BoxedStream<T> = std::pin::Pin<Box<dyn futures::Stream<Item = Result<T, Status>> + Send>>;

/// One SubjectAccessReview for `subject` on `workspace`'s harness Service in
/// the relay's own namespace, submitted under the relay's own credential.
/// A denied review is PermissionDenied.
async fn review_reach(
    client: kube::Client,
    namespace: &str,
    subject: &str,
    workspace: &str,
) -> Result<(), Status> {
    let review: kube::Api<k8s_openapi::api::authorization::v1::SubjectAccessReview> =
        kube::Api::all(client);
    let result = review
        .create(
            &kube::api::PostParams::default(),
            &build_subject_access_review(subject, workspace, namespace),
        )
        .await
        .map_err(|e| Status::internal(format!("SubjectAccessReview API error: {e}")))?;
    if result.status.map(|s| s.allowed).unwrap_or(false) {
        Ok(())
    } else {
        Err(Status::permission_denied(
            "caller cannot reach the named workspace",
        ))
    }
}

/// An adapter stream's sender handle, re-resolved before each item against
/// the live identity table.
struct HandleCheck {
    identity: Arc<tokio::sync::RwLock<crate::identity::IdentityTable>>,
    channel: String,
    sender: String,
}

/// The bearer token an open stream was admitted with, reviewed again before
/// each item so the stream ends once the token expires or is revoked.
struct TokenCheck {
    token: String,
    audience: Option<&'static str>,
}

/// The bearer token and audience a stream opened on `request` is re-reviewed
/// with.
#[allow(clippy::result_large_err)]
fn token_check<T>(request: &Request<T>) -> Result<TokenCheck, Status> {
    let audience = match request.extensions().get::<ListenerClass>() {
        Some(ListenerClass::AdapterToken) => Some(ADAPTER_RELAY_AUDIENCE),
        _ => None,
    };
    Ok(TokenCheck {
        token: extract_bearer_token(request)?.to_string(),
        audience,
    })
}

pub struct GatewayService {
    state: Arc<GatewayState>,
}

/// Whether a request bound to `verified_subject` may touch a conversation the
/// relay has cached under `cached_owner`.
///
/// The cache is a cache: a miss is not permission. It sends the relay to the
/// harness, which holds the durable owner stamp.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConversationAccess {
    Allow,
    Deny,
    ResolveWithHarness,
}

/// Pure conversation-ownership decision. Takes no workspace: two subjects in
/// one workspace must not reach each other's conversations, so a workspace
/// comparison is exactly the thing that must not appear here.
fn conversation_access(cached_owner: Option<&str>, verified_subject: &str) -> ConversationAccess {
    match cached_owner {
        Some(owner) if owner == verified_subject => ConversationAccess::Allow,
        Some(_) => ConversationAccess::Deny,
        None => ConversationAccess::ResolveWithHarness,
    }
}

fn denied_conversation() -> Status {
    Status::permission_denied("conversation belongs to a different subject")
}

fn denied_call() -> Status {
    Status::permission_denied("call belongs to a different subject or workspace")
}

fn denied_sender() -> Status {
    Status::permission_denied("sender has no operator handle binding")
}

/// Resolve an adapter's reported sender to the subject its operator handle
/// binding names in the live identity table.
async fn resolve_sender(
    identity: &tokio::sync::RwLock<crate::identity::IdentityTable>,
    channel: &str,
    sender: &str,
) -> Result<String, Status> {
    identity
        .read()
        .await
        .resolve_handle(channel, sender)
        .map(str::to_string)
        .ok_or_else(denied_sender)
}

/// Require that an adapter's sender still resolves to `subject`, the subject
/// the channel was opened for.
async fn require_sender(
    identity: &tokio::sync::RwLock<crate::identity::IdentityTable>,
    channel: &str,
    sender: &str,
    subject: &str,
) -> Result<(), Status> {
    if resolve_sender(identity, channel, sender).await? == subject {
        Ok(())
    } else {
        Err(denied_sender())
    }
}

/// Refuse a request that names no workspace.
#[allow(clippy::result_large_err)]
fn require_workspace(workspace: &str) -> Result<(), Status> {
    if workspace.is_empty() {
        return Err(Status::invalid_argument("request must name its workspace"));
    }
    Ok(())
}

/// Extract the channel an adapter ServiceAccount username names. `None`
/// when the username is not an `adapter-<channel>` SA of `namespace`.
fn adapter_channel(username: &str, namespace: &str) -> Option<String> {
    serviceaccount_from_username(username)
        .and_then(|(ns, sa)| (ns == namespace).then_some(sa))
        .and_then(|sa| sa.strip_prefix(ADAPTER_SA_NAME_PREFIX))
        .filter(|channel| !channel.is_empty())
        .map(str::to_string)
}

impl GatewayService {
    pub fn new(state: Arc<GatewayState>) -> Self {
        Self { state }
    }

    #[allow(clippy::result_large_err)]
    fn kube_client(&self) -> Result<kube::Client, Status> {
        self.state
            .kube_client()
            .cloned()
            .ok_or_else(|| Status::unavailable("no kube client configured"))
    }

    /// Authenticate the caller per the listener's stamped credential class
    /// and return the verified identity the request runs under.
    async fn authenticate<T>(&self, request: &Request<T>) -> Result<Caller, Status> {
        let class = request
            .extensions()
            .get::<ListenerClass>()
            .copied()
            .ok_or_else(|| {
                Status::permission_denied("missing listener class; middleware must populate it")
            })?;
        let token = extract_bearer_token(request)?;
        let client = self.kube_client()?;
        match class {
            ListenerClass::PersonToken => {
                let subject = review_token_username(&client, token, None).await?;
                Ok(Caller::Person { subject })
            }
            ListenerClass::AdapterToken => {
                // Audience-pinned TokenReview returning the raw username:
                // the structural adapter-<channel> check below, not a
                // workspace mapping, derives the channel.
                let username =
                    review_token_username(&client, token, Some(ADAPTER_RELAY_AUDIENCE)).await?;
                let namespace = self.state.namespace();
                let channel = adapter_channel(&username, namespace).ok_or_else(|| {
                    Status::permission_denied(format!(
                        "caller is not an adapter ServiceAccount of {namespace}"
                    ))
                })?;
                Ok(Caller::Adapter { channel })
            }
        }
    }

    /// The pooled harness client for `workspace`.
    async fn harness(&self, workspace: &str) -> Result<HarnessClient, Status> {
        self.state
            .harness_clients()
            .get(workspace)
            .await
            .map_err(|e| Status::unavailable(format!("harness unavailable: {e}")))
    }

    /// The reach check for every path: a SubjectAccessReview carrying the
    /// resolved subject and the relay's own namespace — never a
    /// caller-supplied one — submitted under the relay's own credential.
    async fn reach(&self, subject: &str, workspace: &str) -> Result<(), Status> {
        review_reach(
            self.kube_client()?,
            self.state.namespace(),
            subject,
            workspace,
        )
        .await
    }

    /// Wrap an open stream so it re-checks, before each item goes out,
    /// everything that admitted it: the bearer token (a TokenReview), with a
    /// [`HandleCheck`] that the adapter sender's handle still resolves to the
    /// subject, and the subject's reach (a SubjectAccessReview). Once any
    /// fails, the stream ends with that status, so an expired token, a
    /// removed RoleBinding, or a removed handle binding cuts a stream opened
    /// before it on its next item, the same as it cuts the next request.
    #[allow(clippy::result_large_err)]
    fn reauthorized<T, S>(
        &self,
        inner: S,
        token: TokenCheck,
        subject: &str,
        workspace: &str,
        handle: Option<HandleCheck>,
    ) -> Result<BoxedStream<T>, Status>
    where
        T: Send + 'static,
        S: futures::Stream<Item = Result<T, Status>> + Send + 'static,
    {
        let client = self.kube_client()?;
        let namespace = self.state.namespace().to_string();
        let subject = subject.to_string();
        let workspace = workspace.to_string();
        let handle = handle.map(Arc::new);
        let token = Arc::new(token);
        let inner = Box::pin(inner);
        Ok(Box::pin(futures::stream::unfold(
            Some(inner),
            move |inner| {
                let client = client.clone();
                let namespace = namespace.clone();
                let subject = subject.clone();
                let workspace = workspace.clone();
                let handle = handle.clone();
                let token = token.clone();
                async move {
                    let mut inner = inner?;
                    let item = inner.next().await?;
                    if let Err(e) =
                        review_token_username(&client, &token.token, token.audience).await
                    {
                        return Some((Err(e), None));
                    }
                    if let Some(h) = handle {
                        if let Err(e) =
                            require_sender(&h.identity, &h.channel, &h.sender, &subject).await
                        {
                            return Some((Err(e), None));
                        }
                    }
                    match review_reach(client, &namespace, &subject, &workspace).await {
                        Ok(()) => Some((item, Some(inner))),
                        Err(e) => Some((Err(e), None)),
                    }
                }
            },
        )))
    }

    /// Authenticate the caller and return its person subject. An adapter
    /// caller is refused: adapters resolve senders through ChannelReceive and
    /// reach nothing else.
    async fn person_subject<T>(&self, request: &Request<T>) -> Result<String, Status> {
        match self.authenticate(request).await? {
            Caller::Person { subject } => Ok(subject),
            Caller::Adapter { .. } => Err(Status::permission_denied(
                "the adapter listener serves channel receive only",
            )),
        }
    }

    /// Authorize the request's named workspace for the verified person
    /// caller and return its subject.
    async fn authorize_workspace<T>(
        &self,
        request: &Request<T>,
        workspace: &str,
    ) -> Result<String, Status> {
        require_workspace(workspace)?;
        let subject = self.person_subject(request).await?;
        self.reach(&subject, workspace).await?;
        Ok(subject)
    }

    /// Authorize a receive stream and resolve the subject it serves. A
    /// person token is its own subject; an adapter's sender resolves
    /// through the operator's handle binding. Either way the named
    /// workspace is reviewed for that subject.
    async fn authorize_receive(
        &self,
        request: &Request<ChannelReceiveRequest>,
    ) -> Result<(ChannelOpener, String), Status> {
        let caller = self.authenticate(request).await?;
        let req = request.get_ref();
        require_workspace(&req.workspace)?;
        let (opener, subject) = match &caller {
            Caller::Person { subject } => {
                if !req.sender.is_empty() {
                    return Err(Status::invalid_argument(
                        "ChannelReceiveRequest.sender is for the adapter path only",
                    ));
                }
                (ChannelOpener::Person, subject.clone())
            }
            Caller::Adapter { channel } => {
                if req.sender.is_empty() {
                    return Err(Status::invalid_argument(
                        "ChannelReceiveRequest.sender required",
                    ));
                }
                let subject = resolve_sender(&self.state.identity(), channel, &req.sender).await?;
                (
                    ChannelOpener::Adapter {
                        channel: channel.clone(),
                        sender: req.sender.clone(),
                    },
                    subject,
                )
            }
        };
        self.reach(&subject, &req.workspace).await?;
        Ok((opener, subject))
    }

    /// Refuse a request naming a conversation minted under another subject,
    /// including when both subjects name the same workspace. An empty id
    /// names no conversation and is passed through untouched.
    async fn require_conversation_subject(
        &self,
        workspace: &str,
        subject: &str,
        conversation_id: &str,
    ) -> Result<(), Status> {
        if conversation_id.is_empty() {
            return Ok(());
        }
        let cached = self.state.conversation_owner(conversation_id).await;
        match conversation_access(cached.as_deref(), subject) {
            ConversationAccess::Allow => Ok(()),
            ConversationAccess::Deny => Err(denied_conversation()),
            ConversationAccess::ResolveWithHarness => {
                self.resolve_conversation_owner(workspace, subject, conversation_id)
                    .await
            }
        }
    }

    /// Ask the harness — the holder of the durable owner stamp — whether
    /// this subject minted this conversation, and cache the answer. Denies
    /// when the harness does not list it for this subject.
    async fn resolve_conversation_owner(
        &self,
        workspace: &str,
        subject: &str,
        conversation_id: &str,
    ) -> Result<(), Status> {
        let mut client = self.harness(workspace).await?;
        let listed = client
            .as_mut()
            .list_conversations(ListConversationsRequest {
                workspace: workspace.to_string(),
                owner: subject.to_string(),
            })
            .await?
            .into_inner();
        if listed
            .conversations
            .iter()
            .any(|c| c.conversation_id == conversation_id)
        {
            self.state
                .record_conversation_owner(conversation_id, subject)
                .await;
            Ok(())
        } else {
            Err(denied_conversation())
        }
    }

    /// Look up a dispatched call and refuse it unless `subject` dispatched
    /// it. Returns the workspace the call was dispatched to.
    async fn owned_call(&self, call_id: &str, subject: &str) -> Result<String, Status> {
        let (owner, workspace) = self.state.dispatched_call(call_id).await.ok_or_else(|| {
            Status::not_found("call_id is not registered (call DispatchTool first)")
        })?;
        if owner != subject {
            return Err(denied_call());
        }
        Ok(workspace)
    }
}

/// True when a `ClientResponse` delivery found no matching awaiter, so the
/// handler should warn-log.
fn warn_on_undelivered(delivered: bool) -> bool {
    !delivered
}

#[tonic::async_trait]
impl RelayGateway for GatewayService {
    async fn discover(
        &self,
        _request: Request<DiscoverRequest>,
    ) -> Result<Response<DiscoverResponse>, Status> {
        let (issuer, client_id, ca) = self.state.idp_config();
        Ok(Response::new(DiscoverResponse {
            issuer: issuer.to_string(),
            client_id: client_id.to_string(),
            certificate_authority: ca.to_string(),
        }))
    }

    async fn list_workspaces(
        &self,
        request: Request<ListWorkspacesRequest>,
    ) -> Result<Response<ListWorkspacesResponse>, Status> {
        let subject = self.person_subject(&request).await?;
        let identity = self.state.identity();
        let workspaces = {
            let table = identity.read().await;
            table.workspaces_for(&subject)
        };
        Ok(Response::new(ListWorkspacesResponse { workspaces }))
    }

    async fn list_grants(
        &self,
        request: Request<ListGrantsRequest>,
    ) -> Result<Response<ListGrantsResponse>, Status> {
        let workspace = request.get_ref().workspace.clone();
        self.authorize_workspace(&request, &workspace).await?;
        let toolsets = self
            .state
            .capabilities()
            .read()
            .await
            .for_workspace(&workspace)
            .into_iter()
            .map(|(toolset, grants)| ToolsetGrants { toolset, grants })
            .collect();
        Ok(Response::new(ListGrantsResponse { toolsets }))
    }

    async fn mint_conversation(
        &self,
        request: Request<MintConversationRequest>,
    ) -> Result<Response<MintConversationResponse>, Status> {
        let workspace = request.get_ref().workspace.clone();
        let subject = self.authorize_workspace(&request, &workspace).await?;
        let mut client = self.harness(&workspace).await?;
        let resp = client
            .as_mut()
            .mint_conversation(MintConversationRequest {
                owner: subject.clone(),
                workspace,
            })
            .await?;
        self.state
            .record_conversation_owner(&resp.get_ref().conversation_id, &subject)
            .await;
        Ok(resp)
    }

    async fn list_conversations(
        &self,
        request: Request<ListConversationsRequest>,
    ) -> Result<Response<ListConversationsResponse>, Status> {
        let workspace = request.get_ref().workspace.clone();
        let subject = self.authorize_workspace(&request, &workspace).await?;
        let mut client = self.harness(&workspace).await?;
        client
            .as_mut()
            .list_conversations(ListConversationsRequest {
                workspace,
                owner: subject,
            })
            .await
    }

    async fn delete_conversation(
        &self,
        request: Request<DeleteConversationRequest>,
    ) -> Result<Response<DeleteConversationResponse>, Status> {
        let workspace = request.get_ref().workspace.clone();
        let subject = self.authorize_workspace(&request, &workspace).await?;
        let req = request.into_inner();
        if req.conversation_id.is_empty() {
            return Err(Status::invalid_argument(
                "DeleteConversationRequest.conversation_id required",
            ));
        }
        self.require_conversation_subject(&workspace, &subject, &req.conversation_id)
            .await?;
        let mut client = self.harness(&workspace).await?;
        client.as_mut().delete_conversation(req).await
    }

    async fn cancel_turn(
        &self,
        request: Request<CancelTurnRequest>,
    ) -> Result<Response<CancelTurnResponse>, Status> {
        let workspace = request.get_ref().workspace.clone();
        let subject = self.authorize_workspace(&request, &workspace).await?;
        let req = request.into_inner();
        if req.conversation_id.is_empty() {
            return Err(Status::invalid_argument(
                "CancelTurnRequest.conversation_id required",
            ));
        }
        self.require_conversation_subject(&workspace, &subject, &req.conversation_id)
            .await?;
        let mut client = self.harness(&workspace).await?;
        client.as_mut().cancel_turn(req).await
    }

    async fn set_conversation_name(
        &self,
        request: Request<SetConversationNameRequest>,
    ) -> Result<Response<SetConversationNameResponse>, Status> {
        let workspace = request.get_ref().workspace.clone();
        let subject = self.authorize_workspace(&request, &workspace).await?;
        let req = request.into_inner();
        if req.conversation_id.is_empty() {
            return Err(Status::invalid_argument(
                "SetConversationNameRequest.conversation_id required",
            ));
        }
        require_conversation_name_within_limit(&req.name)?;
        self.require_conversation_subject(&workspace, &subject, &req.conversation_id)
            .await?;
        let mut client = self.harness(&workspace).await?;
        client.as_mut().set_conversation_name(req).await
    }

    async fn get_conversation_history(
        &self,
        request: Request<GetConversationHistoryRequest>,
    ) -> Result<Response<GetConversationHistoryResponse>, Status> {
        let workspace = request.get_ref().workspace.clone();
        let subject = self.authorize_workspace(&request, &workspace).await?;
        let req = request.into_inner();
        if req.conversation_id.is_empty() {
            return Err(Status::invalid_argument("conversation_id required"));
        }
        let mut client = self.harness(&workspace).await?;
        client
            .as_mut()
            .get_conversation_history(GetConversationHistoryRequest {
                conversation_id: req.conversation_id,
                limit: req.limit,
                owner: subject,
                workspace,
            })
            .await
    }

    async fn get_turn_state(
        &self,
        request: Request<GetTurnStateRequest>,
    ) -> Result<Response<TurnStateEvent>, Status> {
        let workspace = request.get_ref().workspace.clone();
        let subject = self.authorize_workspace(&request, &workspace).await?;
        let req = request.into_inner();
        if req.conversation_id.is_empty() {
            return Err(Status::invalid_argument("conversation_id required"));
        }
        // Unknown / never-active conversation → IDLE. Absence of a record
        // is not an error — it is exactly the "input enabled, nothing in
        // flight" state the client wants.
        let event = match self
            .state
            .turn_state_record(&subject, &req.conversation_id)
            .await
        {
            Some(rec) => TurnStateEvent {
                state: rec.state as i32,
                conversation_id: req.conversation_id,
                reason: rec.reason,
                code: rec.code,
                ..Default::default()
            },
            None => TurnStateEvent {
                state: TurnState::Idle as i32,
                conversation_id: req.conversation_id,
                reason: String::new(),
                code: String::new(),
                ..Default::default()
            },
        };
        Ok(Response::new(event))
    }

    async fn channel_ingest(
        &self,
        request: Request<ChannelIngestRequest>,
    ) -> Result<Response<ChannelIngestAck>, Status> {
        // The channel_id is server-minted and opaque; the registry maps it
        // back to the subject and workspace it was minted under, and the
        // ingest re-runs the reach check so a revocation cuts a live
        // channel's next message. Holding a channel_id is not a credential:
        // the caller must be the one who opened the channel.
        let caller = self.authenticate(&request).await?;
        let req = request.into_inner();
        if req.channel_id.is_empty() {
            return Err(Status::invalid_argument(
                "ChannelIngestRequest.channel_id required",
            ));
        }
        let (opener, subject, workspace) = self
            .state
            .channel_binding(&req.channel_id)
            .await
            .ok_or_else(|| {
                Status::not_found(
                    "ChannelIngestRequest.channel_id is not registered (call ChannelReceive first)",
                )
            })?;
        let opened_by_caller = match (&caller, opener) {
            (
                Caller::Person {
                    subject: caller_subject,
                },
                ChannelOpener::Person,
            ) => *caller_subject == subject,
            (
                Caller::Adapter { channel },
                ChannelOpener::Adapter {
                    channel: opener,
                    sender,
                },
            ) => {
                // The handle is re-resolved on every message, like the
                // reach review: a removed handle binding cuts an open
                // channel on its next message.
                if *channel != opener {
                    false
                } else {
                    require_sender(&self.state.identity(), &opener, &sender, &subject).await?;
                    true
                }
            }
            _ => false,
        };
        if !opened_by_caller {
            return Err(Status::permission_denied(
                "caller did not open this channel",
            ));
        }
        self.reach(&subject, &workspace).await?;
        self.require_conversation_subject(&workspace, &subject, &req.conversation_id)
            .await?;

        // Capability set update is independent of the payload — clients
        // re-advertise on every ingest so a device switch picks up the
        // new renderer set immediately.
        if !req.supported_methods.is_empty() {
            self.state
                .update_supported_methods(&req.channel_id, req.supported_methods.clone())
                .await;
        }

        // Discriminate payload. Exactly one of user_message /
        // client_response must be set.
        match (req.user_message, req.client_response) {
            (Some(_), Some(_)) => Err(Status::invalid_argument(
                "ChannelIngestRequest must carry exactly one of user_message or client_response",
            )),
            (None, None) => Err(Status::invalid_argument(
                "ChannelIngestRequest must carry user_message or client_response",
            )),
            (Some(user_message), None) => {
                // Conversation id: empty → mint a fresh one via the caller's
                // harness; non-empty (opaque UUID) → continue it.
                let conversation_id = if req.conversation_id.is_empty() {
                    let mut client = self.harness(&workspace).await?;
                    let minted = client
                        .as_mut()
                        .mint_conversation(MintConversationRequest {
                            owner: subject.clone(),
                            workspace: workspace.clone(),
                        })
                        .await?
                        .into_inner()
                        .conversation_id;
                    self.state
                        .record_conversation_owner(&minted, &subject)
                        .await;
                    minted
                } else {
                    req.conversation_id.clone()
                };
                self.state
                    .notify_subscriber(
                        &workspace,
                        UserMessage {
                            content: user_message.content,
                            sender: user_message.sender,
                            reply_channel: Some(req.channel_id.clone()),
                            conversation_id: conversation_id.clone(),
                            // The client's grant selections ride through
                            // untouched; the controller is the closed-set
                            // authority, not the relay.
                            grants: user_message.grants,
                        },
                    )
                    .await;
                // The user message has been accepted and routed; the
                // harness will pick it up momentarily. Move the channel
                // to WORKING so the client renders an active indicator until
                // the assistant message (or a TurnError) lands.
                self.state
                    .set_and_broadcast_turn_state(
                        &req.channel_id,
                        &subject,
                        &conversation_id,
                        TurnState::Working,
                    )
                    .await;
                Ok(Response::new(ChannelIngestAck {
                    channel_id: req.channel_id,
                    conversation_id,
                }))
            }
            (None, Some(cr)) => {
                // Validate ClientResponse: exactly one of result_json / error.
                let result_set = !cr.result_json.is_empty();
                let error_set = cr.error.is_some();
                if result_set && error_set {
                    return Err(Status::invalid_argument(
                        "ClientResponse must carry exactly one of result_json or error",
                    ));
                }
                if !result_set && !error_set {
                    return Err(Status::invalid_argument(
                        "ClientResponse must carry result_json or error",
                    ));
                }
                let outcome = if error_set {
                    crate::state::ServerRequestOutcome::Error(cr.error.unwrap())
                } else {
                    crate::state::ServerRequestOutcome::Result(cr.result_json)
                };
                // Delivery to an unknown / expired request_id is benign
                // (timeout already fired). Warn-log but do not error.
                if warn_on_undelivered(
                    self.state
                        .deliver_client_response(&workspace, &cr.request_id, outcome)
                        .await,
                ) {
                    tracing::warn!(
                        channel_id = %req.channel_id,
                        request_id = %cr.request_id,
                        "channel_ingest: ClientResponse for unknown/expired request_id"
                    );
                }
                // ClientResponse path does not touch a conversation — empty
                // id in the ack is the honest signal that no conversation
                // was routed by this call.
                Ok(Response::new(ChannelIngestAck {
                    channel_id: req.channel_id,
                    conversation_id: String::new(),
                }))
            }
        }
    }

    type ChannelReceiveStream = BoxedStream<ChannelOutbound>;

    async fn channel_receive(
        &self,
        request: Request<ChannelReceiveRequest>,
    ) -> Result<Response<Self::ChannelReceiveStream>, Status> {
        let (opener, subject) = self.authorize_receive(&request).await?;
        let token = token_check(&request)?;
        let req = request.into_inner();
        let handle_check = match &opener {
            ChannelOpener::Adapter { channel, sender } => Some(HandleCheck {
                identity: self.state.identity(),
                channel: channel.clone(),
                sender: sender.clone(),
            }),
            ChannelOpener::Person => None,
        };

        let (tx, rx) = mpsc::channel(16);
        let resume_after_seq = req.resume_after_seq;
        // Determine if this channel starts in catch-up mode.
        let catching_up = resume_after_seq.is_some();
        // Mint the server-side channel_id and bind it to the resolved
        // subject and the authorized workspace. The adapter_hint is logged
        // only.
        let channel_id = self
            .state
            .mint_channel(opener, subject.clone(), req.workspace.clone(), tx.clone(), catching_up)
            .await;
        tracing::info!(
            channel_id = %channel_id,
            subject = %subject,
            workspace = %req.workspace,
            adapter_hint = ?req.adapter_hint,
            resume_after_seq = ?resume_after_seq,
            "channel_receive: minted channel_id"
        );

        // First frame of the outbound stream IS the ChannelAck — the
        // adapter MUST consume this before it can echo channel_id on
        // ChannelIngest.
        if let Err(e) = tx
            .send(ChannelOutbound {
                command: Some(channel_outbound::Command::Ack(ChannelAck {
                    channel_id: channel_id.clone(),
                })),
                workspace_seq: None,
            })
            .await
        {
            tracing::warn!(?e, "channel_receive: failed to send initial ChannelAck");
        }

        if let Some(after_seq) = resume_after_seq {
            // Resume mode: spawn a task to replay from the harness event log,
            // then transition to live. Return the stream immediately to avoid
            // mpsc(16) deadlock.
            let state = self.state.clone();
            let workspace = req.workspace.clone();
            let channel_id_for_replay = channel_id.clone();
            let tx_for_replay = tx.clone();
            tokio::spawn(async move {
                let replay_result = async {
                    let mut harness = state
                        .harness_clients()
                        .get(&workspace)
                        .await
                        .map_err(|e| format!("harness unavailable: {e}"))?;
                    let resp = harness
                        .as_mut()
                        .replay_event_log(harness_proto::ReplayEventLogRequest {
                            after_seq,
                        })
                        .await
                        .map_err(|e| format!("replay_event_log failed: {e}"))?;
                    let mut stream = resp.into_inner();
                    while let Some(frame) = futures::StreamExt::next(&mut stream).await {
                        match frame {
                            Ok(outbound) => {
                                if tx_for_replay.send(outbound).await.is_err() {
                                    return Err("client disconnected during replay".to_string());
                                }
                            }
                            Err(e) => {
                                return Err(format!("replay stream error: {e}"));
                            }
                        }
                    }
                    Ok(())
                }
                .await;

                match replay_result {
                    Ok(()) => {
                        // Send CatchUpComplete before transitioning to live.
                        let _ = tx_for_replay
                            .send(ChannelOutbound {
                                command: Some(channel_outbound::Command::CatchUpComplete(
                                    CatchUpComplete {},
                                )),
                                workspace_seq: None,
                            })
                            .await;
                    }
                    Err(e) => {
                        tracing::warn!(
                            channel_id = %channel_id_for_replay,
                            error = %e,
                            "channel_receive: replay failed, sending ReplayImpossible"
                        );
                        let _ = tx_for_replay
                            .send(ChannelOutbound {
                                command: Some(channel_outbound::Command::ReplayImpossible(
                                    ReplayImpossible {},
                                )),
                                workspace_seq: None,
                            })
                            .await;
                    }
                }

                // Transition to live: drain buffered frames, then start heartbeat.
                state.transition_to_live(&channel_id_for_replay).await;
                let interval = state.heartbeat_interval();
                state.spawn_heartbeat(&channel_id_for_replay, interval).await;
            });
        } else {
            // No resume: start live immediately, replay turn state as today.
            self.state.replay_turn_state(&channel_id).await;
            // Spawn heartbeat immediately for live channels.
            let interval = self.state.heartbeat_interval();
            self.state.spawn_heartbeat(&channel_id, interval).await;
        }

        // Tie unregister to the outbound stream's lifetime, not a
        // wall-clock timer. The guard travels with the response stream;
        // tonic drops the stream on client disconnect or cancellation,
        // and only then is the drain-and-unregister task scheduled.
        let guard = ChannelDropGuard {
            state: self.state.clone(),
            channel_id: channel_id.clone(),
        };

        #[allow(clippy::result_large_err)]
        let outbound_stream =
            ReceiverStream::new(rx).map(|msg| -> Result<ChannelOutbound, Status> { Ok(msg) });
        let guarded = GuardedStream {
            inner: self.reauthorized(
                outbound_stream,
                token,
                &subject,
                &req.workspace,
                handle_check,
            )?,
            _guard: guard,
        };

        Ok(Response::new(Box::pin(guarded)))
    }

    type WatchToolsStream = BoxedStream<ToolListUpdate>;

    async fn watch_tools(
        &self,
        request: Request<WatchToolsRequest>,
    ) -> Result<Response<Self::WatchToolsStream>, Status> {
        let workspace = request.get_ref().workspace.clone();
        let subject = self.authorize_workspace(&request, &workspace).await?;
        let token = token_check(&request)?;
        let mut client = self.harness(&workspace).await?;
        let upstream = client
            .as_mut()
            .watch_tools(WatchToolsRequest {
                workspace: workspace.clone(),
            })
            .await?
            .into_inner();
        // Pass-through, with the token and the subject's reach reviewed
        // before each item.
        Ok(Response::new(self.reauthorized(
            upstream, token, &subject, &workspace, None,
        )?))
    }

    async fn dispatch_tool(
        &self,
        request: Request<CallToolRequest>,
    ) -> Result<Response<DispatchToolResponse>, Status> {
        let workspace = request.get_ref().workspace.clone();
        let subject = self.authorize_workspace(&request, &workspace).await?;
        let req = request.into_inner();
        // conversation_id is optional here; when one is named it must
        // belong to the calling subject. No per-key, per-subject, or
        // per-tool restriction beyond that and the workspace boundary.
        self.require_conversation_subject(&workspace, &subject, &req.conversation_id)
            .await?;
        let mut client = self.harness(&workspace).await?;
        let resp = client.as_mut().dispatch_tool(req).await?;
        let call_id = resp.get_ref().call_id.clone();
        self.state
            .record_dispatched_call(&call_id, &subject, &workspace)
            .await;
        Ok(resp)
    }

    type AwaitToolResultStream = BoxedStream<ToolResultFrame>;

    async fn await_tool_result(
        &self,
        request: Request<AwaitToolResultRequest>,
    ) -> Result<Response<Self::AwaitToolResultStream>, Status> {
        let workspace = request.get_ref().workspace.clone();
        let subject = self.authorize_workspace(&request, &workspace).await?;
        let token = token_check(&request)?;
        let req = request.into_inner();
        if req.call_id.is_empty() {
            return Err(Status::invalid_argument(
                "AwaitToolResultRequest.call_id required",
            ));
        }
        // Holding a call_id is not a credential: only the subject that
        // dispatched the call, on the workspace it was dispatched to, may
        // read its result.
        let call_workspace = self.owned_call(&req.call_id, &subject).await?;
        if call_workspace != workspace {
            return Err(denied_call());
        }
        self.require_conversation_subject(&workspace, &subject, &req.conversation_id)
            .await?;
        let mut client = self.harness(&workspace).await?;
        let upstream = client.as_mut().await_tool_result(req).await?.into_inner();
        // Pass-through, with the token and the subject's reach reviewed
        // before each item.
        Ok(Response::new(self.reauthorized(
            upstream, token, &subject, &workspace, None,
        )?))
    }

    async fn cancel_tool(
        &self,
        request: Request<CancelToolRequest>,
    ) -> Result<Response<CancelToolResponse>, Status> {
        // CancelTool carries no workspace field: the relay minted the
        // call_id, so it resolves the call's (subject, workspace) from its
        // own registry, refuses a mismatched subject, and re-runs the reach
        // check so a revocation cuts a live call's cancel too.
        let subject = self.person_subject(&request).await?;
        let req = request.into_inner();
        if req.call_id.is_empty() {
            return Err(Status::invalid_argument(
                "CancelToolRequest.call_id required",
            ));
        }
        let workspace = self.owned_call(&req.call_id, &subject).await?;
        self.reach(&subject, &workspace).await?;
        let mut client = self.harness(&workspace).await?;
        client.as_mut().cancel_tool(req).await
    }
}

/// Reject a conversation name longer than `MAX_CONVERSATION_NAME_CHARS`
/// Unicode scalar values, before the harness forward.
#[allow(clippy::result_large_err)]
fn require_conversation_name_within_limit(name: &str) -> Result<(), Status> {
    if name.chars().count() > MAX_CONVERSATION_NAME_CHARS {
        Err(Status::invalid_argument(format!(
            "name exceeds {MAX_CONVERSATION_NAME_CHARS}-character limit",
        )))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_access_allow_deny_and_miss() {
        assert_eq!(
            conversation_access(
                Some("https://issuer.example#alice"),
                "https://issuer.example#alice"
            ),
            ConversationAccess::Allow
        );
        assert_eq!(
            conversation_access(
                Some("https://issuer.example#alice"),
                "https://issuer.example#bob"
            ),
            ConversationAccess::Deny
        );
        assert_eq!(
            conversation_access(None, "x"),
            ConversationAccess::ResolveWithHarness
        );
    }

    #[test]
    fn adapter_channel_extracts_channel_from_sa_name() {
        assert_eq!(
            adapter_channel(
                "system:serviceaccount:tenant-acme:adapter-slack",
                "tenant-acme"
            ),
            Some("slack".to_string())
        );
        assert_eq!(
            adapter_channel(
                "system:serviceaccount:other-ns:adapter-slack",
                "tenant-acme"
            ),
            None
        );
        assert_eq!(
            adapter_channel("system:serviceaccount:tenant-acme:harness", "tenant-acme"),
            None
        );
        assert_eq!(
            adapter_channel("https://issuer.example#alice", "tenant-acme"),
            None
        );
    }

    #[test]
    fn warn_on_undelivered_warns_only_when_not_delivered() {
        for (delivered, expect_warn) in [(true, false), (false, true)] {
            assert_eq!(
                warn_on_undelivered(delivered),
                expect_warn,
                "delivered={delivered} must warn={expect_warn}"
            );
        }
    }

    #[test]
    fn require_conversation_name_within_limit_enforces_boundary() {
        let cases = [
            (1_usize, true),
            (MAX_CONVERSATION_NAME_CHARS, true),
            (MAX_CONVERSATION_NAME_CHARS + 1, false),
        ];
        for (char_count, expect_ok) in cases {
            let name = "x".repeat(char_count);
            let result = require_conversation_name_within_limit(&name);
            assert_eq!(
                result.is_ok(),
                expect_ok,
                "{char_count} chars: expected ok={expect_ok}"
            );
            if let Err(status) = result {
                assert_eq!(status.code(), tonic::Code::InvalidArgument);
            }
        }
    }
}
