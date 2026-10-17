//! `RelayInternal` service — the in-cluster-only surface.
//!
//! Reachable only by SA-token holders. The harness dials `Subscribe`,
//! the server-request methods, and `DeliverOutbound`. The listener
//! verifies the bearer SA token via TokenReview before any handler runs.

use std::sync::Arc;

use proto_common::{
    channel_outbound, ChannelOutbound, ChannelSend, SendServerNotificationRequest,
    SendServerNotificationResponse, SendServerRequestAndAwaitRequest,
    SendServerRequestAndAwaitResponse, SubscribeRequest, TurnState, TurnStateEvent, UserMessage,
};
use relay_proto::relay_internal_server::RelayInternal;
use relay_proto::{
    DeliverStreamItemRequest, DeliverStreamItemResponse,
};
use shared::auth::{extract_bearer_token, TokenVerifier};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status};

use crate::state::GatewayState;

/// Default server-side wait cap for `SendServerRequestAndAwait` when the
/// caller passes 0.
const DEFAULT_AWAIT_SECS: u32 = 30;
/// Hard ceiling for the caller-supplied wait cap.
const MAX_AWAIT_SECS: u32 = 300;

pub struct InternalService {
    state: Arc<GatewayState>,
    /// Verifies the inbound SA token via TokenReview. `None` → no kube
    /// client is available and every authed RPC fails closed with
    /// FailedPrecondition.
    verifier: Option<Arc<dyn TokenVerifier>>,
}

impl InternalService {
    pub fn new(state: Arc<GatewayState>, verifier: Option<Arc<dyn TokenVerifier>>) -> Self {
        Self { state, verifier }
    }

    /// Verify the caller's SA token and return its workspace. The internal
    /// listener authenticates by the bearer SA token alone.
    async fn verify_caller<T>(&self, request: &Request<T>) -> Result<String, Status> {
        let verifier = self.verifier.as_ref().ok_or_else(|| {
            Status::failed_precondition(
                "no token verifier configured: caller identity cannot be established",
            )
        })?;
        let token = extract_bearer_token(request)?;
        verifier.verify_token(token).await
    }
}

#[tonic::async_trait]
impl RelayInternal for InternalService {
    type SubscribeStream =
        std::pin::Pin<Box<dyn futures::Stream<Item = Result<UserMessage, Status>> + Send>>;

    async fn subscribe(
        &self,
        request: Request<SubscribeRequest>,
    ) -> Result<Response<Self::SubscribeStream>, Status> {
        let workspace = self.verify_caller(&request).await?;
        let mut rx = self.state.subscribe_or_create(&workspace).await;
        let (tx, stream_rx) = mpsc::channel(16);
        tokio::spawn(async move {
            while let Ok(msg) = rx.recv().await {
                if tx.send(Ok(msg)).await.is_err() {
                    break;
                }
            }
        });
        Ok(Response::new(Box::pin(ReceiverStream::new(stream_rx))))
    }

    async fn send_server_notification(
        &self,
        request: Request<SendServerNotificationRequest>,
    ) -> Result<Response<SendServerNotificationResponse>, Status> {
        let workspace = self.verify_caller(&request).await?;
        let req = request.into_inner();
        if req.method.is_empty() {
            return Err(Status::invalid_argument("method required"));
        }
        let workspace_seq = if req.workspace_seq > 0 { Some(req.workspace_seq) } else { None };
        let delivered = match self
            .state
            .send_server_notification(&workspace, &req.method, req.params_json, workspace_seq)
            .await
        {
            Ok(()) => true,
            Err(_) => false,
        };
        Ok(Response::new(SendServerNotificationResponse { delivered }))
    }

    async fn send_server_request_and_await(
        &self,
        request: Request<SendServerRequestAndAwaitRequest>,
    ) -> Result<Response<SendServerRequestAndAwaitResponse>, Status> {
        let workspace = self.verify_caller(&request).await?;
        let req = request.into_inner();
        if req.request_id.is_empty() {
            return Err(Status::invalid_argument(
                "request_id required (notifications use SendServerNotification)",
            ));
        }
        if req.method.is_empty() {
            return Err(Status::invalid_argument("method required"));
        }
        let timeout_secs = clamp_await_secs(req.timeout_seconds);
        match self
            .state
            .send_server_request_and_await(
                &workspace,
                &req.request_id,
                &req.method,
                req.params_json,
                std::time::Duration::from_secs(timeout_secs as u64),
            )
            .await
        {
            Ok(crate::state::ServerRequestOutcome::Result(result_json)) => {
                Ok(Response::new(SendServerRequestAndAwaitResponse {
                    result_json,
                    error: None,
                    timed_out: false,
                    unknown_channel: false,
                    unsupported_method: false,
                }))
            }
            Ok(crate::state::ServerRequestOutcome::Error(e)) => {
                Ok(Response::new(SendServerRequestAndAwaitResponse {
                    result_json: String::new(),
                    error: Some(e),
                    timed_out: false,
                    unknown_channel: false,
                    unsupported_method: false,
                }))
            }
            Err(crate::state::ServerRequestError::UnsupportedMethod) => {
                Ok(Response::new(SendServerRequestAndAwaitResponse {
                    result_json: String::new(),
                    error: None,
                    timed_out: false,
                    unknown_channel: false,
                    unsupported_method: true,
                }))
            }
            Err(crate::state::ServerRequestError::Timeout) => {
                Ok(Response::new(SendServerRequestAndAwaitResponse {
                    result_json: String::new(),
                    error: None,
                    timed_out: true,
                    unknown_channel: false,
                    unsupported_method: false,
                }))
            }
            Err(crate::state::ServerRequestError::UnknownChannel) | Err(_) => {
                Ok(Response::new(SendServerRequestAndAwaitResponse {
                    result_json: String::new(),
                    error: None,
                    timed_out: false,
                    unknown_channel: true,
                    unsupported_method: false,
                }))
            }
        }
    }

    async fn deliver_reply(
        &self,
        request: Request<relay_proto::DeliverReplyRequest>,
    ) -> Result<Response<relay_proto::DeliverReplyResponse>, Status> {
        let workspace = self.verify_caller(&request).await?;
        let req = request.into_inner();
        let send = ChannelOutbound {
            command: Some(channel_outbound::Command::SendMessage(ChannelSend {
                content: req.content,
                conversation_id: req.conversation_id.clone(),
            })),
            workspace_seq: if req.workspace_seq > 0 { Some(req.workspace_seq) } else { None },
        };
        let delivered = self.state.send_to_workspace(&workspace, send).await > 0;
        Ok(Response::new(relay_proto::DeliverReplyResponse { delivered }))
    }

    async fn deliver_turn_state(
        &self,
        request: Request<relay_proto::DeliverTurnStateRequest>,
    ) -> Result<Response<relay_proto::DeliverTurnStateResponse>, Status> {
        let workspace = self.verify_caller(&request).await?;
        let req = request.into_inner();
        let Some(turn_state) = req.turn_state else {
            return Err(Status::invalid_argument("turn_state required"));
        };
        let subject = if req.subject.is_empty() {
            // Backward compat: resolve subject from channel_id if provided
            match self.state.channel_binding(&req.channel_id).await {
                Some((_, subject, bound)) if bound == workspace => subject,
                _ => String::new(),
            }
        } else {
            req.subject
        };
        let state = TurnState::try_from(turn_state.state).unwrap_or(TurnState::Unspecified);
        let ws_seq = if req.workspace_seq > 0 { Some(req.workspace_seq) } else { None };

        // Record the turn state for poll recovery.
        if state == TurnState::Failed {
            self.state
                .record_turn_state(
                    &subject,
                    &turn_state.conversation_id,
                    crate::state::TurnStateRecord {
                        state,
                        reason: turn_state.reason.clone(),
                        code: turn_state.code.clone(),
                    },
                )
                .await;
        } else if !subject.is_empty() {
            self.state
                .record_turn_state(
                    &subject,
                    &turn_state.conversation_id,
                    crate::state::TurnStateRecord {
                        state,
                        reason: String::new(),
                        code: String::new(),
                    },
                )
                .await;
        }

        // Build the outbound frame and fan out to all workspace channels.
        let msg = ChannelOutbound {
            command: Some(channel_outbound::Command::TurnState(TurnStateEvent {
                state: turn_state.state,
                conversation_id: turn_state.conversation_id,
                reason: turn_state.reason,
                code: turn_state.code,
                ..Default::default()
            })),
            workspace_seq: ws_seq,
        };
        let delivered = self.state.send_to_workspace(&workspace, msg).await > 0;
        Ok(Response::new(relay_proto::DeliverTurnStateResponse { delivered }))
    }

    // deliver_outbound is kept for backward compatibility but no longer called
    // by the harness. It's removed from the service trait so this is dead code.

    async fn deliver_stream_item(
        &self,
        request: Request<DeliverStreamItemRequest>,
    ) -> Result<Response<DeliverStreamItemResponse>, Status> {
        let workspace = self.verify_caller(&request).await?;
        let req = request.into_inner();
        let Some(item) = req.item else {
            return Err(Status::invalid_argument("item required"));
        };
        // Pure relay: wrap the StreamItem verbatim, no payload inspection or
        // collapsing. The harness is the sole egress authority.
        let frame = ChannelOutbound {
            command: Some(channel_outbound::Command::StreamItem(item)),
            workspace_seq: if req.workspace_seq > 0 { Some(req.workspace_seq) } else { None },
        };
        let delivered = self.state.send_to_workspace(&workspace, frame).await > 0;
        Ok(Response::new(DeliverStreamItemResponse { delivered }))
    }
}

/// Clamp the caller-supplied wait cap: 0 → default; otherwise capped at
/// the ceiling. Extracted so the clamping is unit-testable.
fn clamp_await_secs(requested: u32) -> u32 {
    if requested == 0 {
        DEFAULT_AWAIT_SECS
    } else {
        requested.min(MAX_AWAIT_SECS)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use proto_common::{ContentBlock, TurnStateEvent};

    use crate::state::test_support::{make_state, mint_person};

    /// Stub verifier that always authenticates the caller as a fixed
    /// workspace, so handler tests exercise the post-auth path without a
    /// kube client.
    struct FixedVerifier(String);

    #[async_trait]
    impl TokenVerifier for FixedVerifier {
        async fn verify_token(&self, _token: &str) -> Result<String, Status> {
            Ok(self.0.clone())
        }
    }

    fn service_for(state: Arc<GatewayState>, workspace: &str) -> InternalService {
        InternalService::new(state, Some(Arc::new(FixedVerifier(workspace.to_string()))))
    }

    fn authed<T>(message: T) -> Request<T> {
        let mut req = Request::new(message);
        req.metadata_mut()
            .insert("authorization", "Bearer token".parse().unwrap());
        req
    }

    #[test]
    fn clamp_await_zero_returns_default() {
        assert_eq!(clamp_await_secs(0), DEFAULT_AWAIT_SECS);
    }

    #[test]
    fn clamp_await_caps_at_ceiling() {
        assert_eq!(clamp_await_secs(10_000), MAX_AWAIT_SECS);
    }

    #[test]
    fn clamp_await_passes_through_in_range() {
        assert_eq!(clamp_await_secs(42), 42);
    }

    /// `subscribe` returns a streaming `Response` whose Ok variant is not
    /// `Debug`, so `unwrap_err` won't compile. Extract the error directly.
    fn subscribe_err(
        result: Result<Response<<InternalService as RelayInternal>::SubscribeStream>, Status>,
    ) -> Status {
        match result {
            Ok(_) => panic!("expected an error from subscribe"),
            Err(s) => s,
        }
    }

    #[tokio::test]
    async fn subscribe_without_verifier_fails_precondition() {
        let service = InternalService::new(make_state(), None);
        let err = subscribe_err(service.subscribe(authed(SubscribeRequest {})).await);
        assert_eq!(err.code(), tonic::Code::FailedPrecondition);
    }

    #[tokio::test]
    async fn subscribe_missing_bearer_token_is_permission_denied() {
        let service = service_for(make_state(), "ws");
        // No authorization metadata.
        let err = subscribe_err(service.subscribe(Request::new(SubscribeRequest {})).await);
        assert_eq!(err.code(), tonic::Code::PermissionDenied);
    }

    #[tokio::test]
    async fn subscribe_delivers_notified_message() {
        let state = make_state();
        let service = service_for(state.clone(), "ws");
        let resp = service
            .subscribe(authed(SubscribeRequest {}))
            .await
            .unwrap();
        let mut stream = resp.into_inner();
        state
            .notify_subscriber(
                "ws",
                UserMessage {
                    content: vec![],
                    sender: "u".into(),
                    reply_channel: Some("chan".into()),
                    conversation_id: "ws.c".into(),
                    grants: vec![],
                },
            )
            .await;
        let msg = futures::StreamExt::next(&mut stream)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(msg.sender, "u");
    }

    #[tokio::test]
    async fn send_server_notification_unknown_channel_reports_not_delivered() {
        let service = service_for(make_state(), "ws");
        let resp = service
            .send_server_notification(authed(SendServerNotificationRequest {
                method: "RevealPath".into(),
                params_json: "{}".into(),
                workspace: "ws".into(),
                workspace_seq: 0,
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(!resp.delivered);
    }

    #[tokio::test]
    async fn send_server_notification_cross_workspace_channel_denied() {
        let state = make_state();
        let (tx, _rx) = mpsc::channel(4);
        // Channel owned by "other".
        let _id = mint_person(&state, "subject-other", "other", tx).await;
        let service = service_for(state, "ws");
        // With workspace-scoped fan-out, the notification goes to all workspace channels.
        // The verifier authenticates as "ws" so this just reports not delivered (no channels).
        let resp = service
            .send_server_notification(authed(SendServerNotificationRequest {
                method: "RevealPath".into(),
                params_json: "{}".into(),
                workspace: "ws".into(),
                workspace_seq: 0,
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(!resp.delivered);
    }

    #[tokio::test]
    async fn send_server_request_unknown_channel_sets_unknown_flag() {
        let service = service_for(make_state(), "ws");
        let resp = service
            .send_server_request_and_await(authed(SendServerRequestAndAwaitRequest {
                request_id: "r".into(),
                method: "AskUser".into(),
                params_json: "{}".into(),
                timeout_seconds: 1,
                workspace: "ws".into(),
                workspace_seq: 0,
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(resp.unknown_channel);
    }

    #[tokio::test]
    async fn send_server_request_cross_workspace_channel_denied() {
        let state = make_state();
        let (tx, _rx) = mpsc::channel(4);
        // Channel owned by "other"; caller authenticates as "ws".
        let _id = mint_person(&state, "subject-other", "other", tx).await;
        let service = service_for(state, "ws");
        // Now workspace-scoped: the request goes to workspace "ws" channels.
        // There are none, so it returns unknown_channel.
        let resp = service
            .send_server_request_and_await(authed(SendServerRequestAndAwaitRequest {
                request_id: "r".into(),
                method: "AskUser".into(),
                params_json: "{}".into(),
                timeout_seconds: 1,
                workspace: "ws".into(),
                workspace_seq: 0,
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(resp.unknown_channel);
    }

    #[tokio::test]
    async fn deliver_reply_fans_out_to_workspace() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(8);
        let _id = mint_person(&state, "subject-ws", "ws", tx).await;
        let service = service_for(state, "ws");
        let resp = service
            .deliver_reply(authed(relay_proto::DeliverReplyRequest {
                conversation_id: "ws.conv".into(),
                content: vec![ContentBlock {
                    block: Some(proto_common::content_block::Block::Text(
                        proto_common::TextBlock { text: "hi".into() },
                    )),
                }],
                workspace_seq: 42,
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(resp.delivered);
        let frame = rx.recv().await.unwrap();
        assert!(matches!(
            frame.command,
            Some(channel_outbound::Command::SendMessage(_))
        ));
        assert_eq!(frame.workspace_seq, Some(42));
    }

    #[tokio::test]
    async fn deliver_reply_no_channels_reports_not_delivered() {
        let state = make_state();
        let service = service_for(state, "ws");
        let resp = service
            .deliver_reply(authed(relay_proto::DeliverReplyRequest {
                conversation_id: "ws.conv".into(),
                content: vec![],
                workspace_seq: 1,
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(!resp.delivered);
    }

    #[tokio::test]
    async fn deliver_turn_state_applies_working() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(8);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        let service = service_for(state.clone(), "ws");
        let resp = service
            .deliver_turn_state(authed(relay_proto::DeliverTurnStateRequest {
                channel_id: id.clone(),
                turn_state: Some(TurnStateEvent {
                    state: TurnState::Working as i32,
                    conversation_id: "ws.conv".into(),
                    reason: String::new(),
                    code: String::new(),
                    ..Default::default()
                }),
                workspace_seq: 0,
                subject: "subject-ws".into(),
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(resp.delivered);
        let frame = rx.recv().await.unwrap();
        assert!(matches!(
            frame.command,
            Some(channel_outbound::Command::TurnState(_))
        ));
        let rec = state
            .turn_state_record("subject-ws", "ws.conv")
            .await
            .unwrap();
        assert_eq!(rec.state, TurnState::Working);
    }

    #[tokio::test]
    async fn deliver_turn_state_failed_carries_reason_and_code() {
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(8);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        let service = service_for(state.clone(), "ws");
        service
            .deliver_turn_state(authed(relay_proto::DeliverTurnStateRequest {
                channel_id: id.clone(),
                turn_state: Some(TurnStateEvent {
                    state: TurnState::Failed as i32,
                    conversation_id: "ws.conv".into(),
                    reason: "inference job died".into(),
                    code: "14".into(),
                    ..Default::default()
                }),
                workspace_seq: 0,
                subject: "subject-ws".into(),
            }))
            .await
            .unwrap();
        let frame = rx.recv().await.unwrap();
        match frame.command {
            Some(channel_outbound::Command::TurnState(e)) => {
                assert_eq!(e.state, TurnState::Failed as i32);
                assert_eq!(e.reason, "inference job died");
                assert_eq!(e.code, "14");
            }
            other => panic!("expected failed TurnState, got {other:?}"),
        }
        let rec = state
            .turn_state_record("subject-ws", "ws.conv")
            .await
            .unwrap();
        assert_eq!(rec.reason, "inference job died");
        assert_eq!(rec.code, "14");
    }

    #[tokio::test]
    async fn deliver_turn_state_records_even_without_channel() {
        let state = make_state();
        let service = service_for(state.clone(), "ws");
        let resp = service
            .deliver_turn_state(authed(relay_proto::DeliverTurnStateRequest {
                channel_id: String::new(),
                turn_state: Some(TurnStateEvent {
                    state: TurnState::Idle as i32,
                    conversation_id: "ws.conv".into(),
                    reason: String::new(),
                    code: String::new(),
                    ..Default::default()
                }),
                workspace_seq: 0,
                subject: "subject-ws".into(),
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(!resp.delivered); // no channels minted, so nothing delivered
        let rec = state
            .turn_state_record("subject-ws", "ws.conv")
            .await
            .unwrap();
        assert_eq!(rec.state, TurnState::Idle);
    }

    #[tokio::test]
    async fn deliver_stream_item_wraps_verbatim_unchanged() {
        use proto_common::{item_start, stream_item, ItemStart, StreamItem, ToolUseItem};
        let state = make_state();
        let (tx, mut rx) = mpsc::channel(8);
        let id = mint_person(&state, "subject-ws", "ws", tx).await;
        let service = service_for(state, "ws");
        // A tool-use start frame with a distinctive envelope; the gateway must
        // forward the StreamItem's bytes unchanged (no inspection/collapsing).
        let item = StreamItem {
            workspace_seq: 7,
            event_id: "ev-1".into(),
            item_id: "tc-1".into(),
            conversation_id: "ws.conv".into(),
            parent_conversation_id: String::new(),
            phase: Some(stream_item::Phase::Start(ItemStart {
                kind: Some(item_start::Kind::ToolUse(ToolUseItem {
                    name: "Bash".into(),
                })),
            })),
            agent_name: String::new(),
        };
        let resp = service
            .deliver_stream_item(authed(DeliverStreamItemRequest {
                channel_id: id,
                item: Some(item.clone()),
                workspace_seq: 7,
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(resp.delivered);
        let frame = rx.recv().await.unwrap();
        match frame.command {
            Some(channel_outbound::Command::StreamItem(got)) => {
                // Round-trip unchanged: the relayed item equals the input.
                assert_eq!(got, item);
            }
            other => panic!("expected StreamItem command, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn deliver_stream_item_no_channels_reports_not_delivered() {
        let service = service_for(make_state(), "ws");
        let resp = service
            .deliver_stream_item(authed(DeliverStreamItemRequest {
                channel_id: String::new(),
                item: Some(proto_common::StreamItem::default()),
                workspace_seq: 0,
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(!resp.delivered);
    }

    #[tokio::test]
    async fn deliver_stream_item_fans_out_to_workspace_not_cross_workspace() {
        let state = make_state();
        let (tx_other, mut rx_other) = mpsc::channel(4);
        // Channel owned by "other" workspace.
        let _id = mint_person(&state, "subject-other", "other", tx_other).await;
        let service = service_for(state, "ws");
        // Verifier authenticates as "ws", so fan-out goes to "ws" channels only.
        // There are none, so nothing is delivered.
        let resp = service
            .deliver_stream_item(authed(DeliverStreamItemRequest {
                channel_id: String::new(),
                item: Some(proto_common::StreamItem::default()),
                workspace_seq: 0,
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(!resp.delivered);
        assert!(rx_other.try_recv().is_err(), "other workspace channel must not receive");
    }

    #[tokio::test]
    async fn deliver_turn_state_cross_workspace_channel_isolated() {
        let state = make_state();
        let (tx_other, mut rx_other) = mpsc::channel(4);
        let _id = mint_person(&state, "subject-other", "other", tx_other).await;
        let service = service_for(state, "ws");
        // The verifier authenticates as "ws". With fan-out, the turn state
        // goes to "ws" channels only. "other" channel must not receive.
        let resp = service
            .deliver_turn_state(authed(relay_proto::DeliverTurnStateRequest {
                channel_id: String::new(),
                turn_state: Some(TurnStateEvent {
                    state: TurnState::Working as i32,
                    conversation_id: "ws.c".into(),
                    ..Default::default()
                }),
                workspace_seq: 0,
                subject: "subject-ws".into(),
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(!resp.delivered); // no channels in "ws", so nothing delivered
        assert!(rx_other.try_recv().is_err(), "other workspace channel must not receive");
    }
}
