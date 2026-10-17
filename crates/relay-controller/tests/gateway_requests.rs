//! Request validation and pass-through on the gateway, past authorization.
//!
//! Every request here is authenticated and authorized for real against the
//! mock apiserver in `common::apiserver`, so each test exercises the check it
//! names and not an earlier refusal. Forwarding tests dial the loopback mock
//! harness in `common::harness`; the rest are refused before any dial.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures::StreamExt;
use k8s_openapi::api::core::v1::ConfigMap;
use k8s_openapi::apimachinery::pkg::apis::meta::v1::ObjectMeta;
use tokio::sync::mpsc;

use proto_common::{
    channel_outbound, tool_result_frame, AwaitToolResultRequest, CallToolRequest,
    CancelToolRequest, CancelTurnRequest, ChannelIngestRequest, ChannelReceiveRequest,
    ClientResponse, DeleteConversationRequest, GetConversationHistoryRequest, GetTurnStateRequest,
    ListGrantsRequest, ListWorkspacesRequest, SetConversationNameRequest, ToolComplete,
    ToolResultFrame, TurnState, UserMessage,
};
use relay_controller::capabilities::{CapabilityGrants, GRANTS_DATA_KEY};
use relay_controller::gateway::GatewayService;
use relay_controller::state::{ChannelOpener, GatewayState};
use relay_proto::relay_gateway_server::RelayGateway;

mod common;
use common::apiserver::{
    bearer, bearer_unclassed, state_for, state_with_harness, IdentityRow, K8s, ALICE, ALICE_TOKEN,
    BOB, BOB_TOKEN,
};
use common::harness::{spawn_mock_harness, MockHarness, MOCK_CALL_ID};
use common::NAMESPACE;

const ALICE_ROW: IdentityRow<'static> = ("user-alice", ALICE, "alpha,beta", &[]);

/// Alice's token, allowed on alpha and beta.
fn alice_on_alpha_and_beta() -> Arc<K8s> {
    K8s::with_token(ALICE_TOKEN, ALICE)
        .allow("ws-alpha", Some(ALICE))
        .allow("ws-beta", Some(ALICE))
}

/// The gateway with alice bound to alpha and beta; no harness answers.
async fn service() -> (GatewayService, Arc<GatewayState>) {
    let state = state_for(&alice_on_alpha_and_beta(), &[ALICE_ROW]).await;
    (GatewayService::new(state.clone()), state)
}

/// The gateway with alice bound to alpha and beta, whose harness is `mock`.
async fn service_on(mock: MockHarness) -> (GatewayService, Arc<GatewayState>) {
    let addr = spawn_mock_harness(mock).await;
    let state = state_with_harness(&alice_on_alpha_and_beta(), &[ALICE_ROW], addr).await;
    (GatewayService::new(state.clone()), state)
}

/// Mint a person channel for alice on alpha, as ChannelReceive would.
async fn alice_channel(state: &GatewayState) -> String {
    let (tx, rx) = mpsc::channel(4);
    // Keep the receiver alive so the channel stays deliverable.
    std::mem::forget(rx);
    state
        .mint_channel(ChannelOpener::Person, ALICE.into(), "alpha".into(), tx, false)
        .await
}

fn turn_state(conversation_id: &str) -> GetTurnStateRequest {
    GetTurnStateRequest {
        conversation_id: conversation_id.into(),
        workspace: "alpha".into(),
    }
}

fn client_response(channel_id: &str, response: ClientResponse) -> ChannelIngestRequest {
    ChannelIngestRequest {
        channel_id: channel_id.into(),
        client_response: Some(response),
        ..Default::default()
    }
}

fn result_response(result_json: &str) -> ClientResponse {
    ClientResponse {
        request_id: "req-unknown".into(),
        result_json: result_json.into(),
        error: None,
    }
}

// --- GetTurnState -------------------------------------------------------------

#[tokio::test]
async fn get_turn_state_rejects_empty_conversation_id() {
    let (svc, _) = service().await;
    let err = svc
        .get_turn_state(bearer(ALICE_TOKEN, turn_state("")))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);
}

#[tokio::test]
async fn get_turn_state_returns_idle_for_unknown_conversation() {
    let (svc, _) = service().await;
    let resp = svc
        .get_turn_state(bearer(ALICE_TOKEN, turn_state("conv-1")))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(resp.state, TurnState::Idle as i32);
    // The IDLE reply echoes the polled conversation_id so the client can
    // correlate it.
    assert_eq!(resp.conversation_id, "conv-1");
    // No phantom failure text.
    assert!(resp.reason.is_empty());
    assert!(resp.code.is_empty());
}

#[tokio::test]
async fn get_turn_state_reflects_recorded_failed_with_reason() {
    let (svc, state) = service().await;
    let id = alice_channel(&state).await;
    state
        .set_and_broadcast_turn_failed(&id, ALICE, "conv-7", "boom", "13")
        .await;
    let resp = svc
        .get_turn_state(bearer(ALICE_TOKEN, turn_state("conv-7")))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(resp.state, TurnState::Failed as i32);
    assert_eq!(resp.conversation_id, "conv-7");
    assert_eq!(resp.reason, "boom");
    assert_eq!(resp.code, "13");
}

/// A turn recorded under alice is invisible to bob polling the same
/// conversation_id on the same workspace.
#[tokio::test]
async fn get_turn_state_does_not_leak_across_subjects() {
    let k8s = K8s::with_tokens(&[(ALICE_TOKEN, ALICE), (BOB_TOKEN, BOB)])
        .allow("ws-alpha", Some(ALICE))
        .allow("ws-alpha", Some(BOB));
    let state = state_for(
        &k8s,
        &[
            ("user-alice", ALICE, "alpha", &[]),
            ("user-bob", BOB, "alpha", &[]),
        ],
    )
    .await;
    let svc = GatewayService::new(state.clone());
    let id = alice_channel(&state).await;
    state
        .set_and_broadcast_turn_state(&id, ALICE, "conv", TurnState::Working)
        .await;

    let resp = svc
        .get_turn_state(bearer(BOB_TOKEN, turn_state("conv")))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(resp.state, TurnState::Idle as i32);
}

// --- The listener class -------------------------------------------------------

/// A request that bypassed the per-listener layer carries no class and is
/// refused, valid bearer or not.
#[tokio::test]
async fn get_turn_state_rejects_missing_extension() {
    let (svc, _) = service().await;
    let err = svc
        .get_turn_state(bearer_unclassed(ALICE_TOKEN, turn_state("conv")))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::PermissionDenied);
    assert!(err.message().contains("listener class"), "{err:?}");
}

#[tokio::test]
async fn list_workspaces_rejects_missing_extension() {
    let (svc, _) = service().await;
    let err = svc
        .list_workspaces(bearer_unclassed(ALICE_TOKEN, ListWorkspacesRequest {}))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::PermissionDenied);
    assert!(err.message().contains("listener class"), "{err:?}");
}

// --- ChannelIngest ------------------------------------------------------------

#[tokio::test]
async fn channel_ingest_rejects_empty_channel_id() {
    let (svc, _) = service().await;
    let err = svc
        .channel_ingest(bearer(ALICE_TOKEN, ChannelIngestRequest::default()))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);
}

#[tokio::test]
async fn channel_ingest_rejects_unregistered_channel() {
    let (svc, _) = service().await;
    let err = svc
        .channel_ingest(bearer(
            ALICE_TOKEN,
            ChannelIngestRequest {
                channel_id: "never-minted".into(),
                user_message: Some(UserMessage {
                    sender: "u".into(),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::NotFound);
}

#[tokio::test]
async fn channel_ingest_rejects_both_payloads_set() {
    let (svc, state) = service().await;
    let id = alice_channel(&state).await;
    let err = svc
        .channel_ingest(bearer(
            ALICE_TOKEN,
            ChannelIngestRequest {
                channel_id: id,
                user_message: Some(UserMessage {
                    sender: "u".into(),
                    ..Default::default()
                }),
                client_response: Some(ClientResponse {
                    request_id: "r".into(),
                    result_json: "{}".into(),
                    error: None,
                }),
                ..Default::default()
            },
        ))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);
}

#[tokio::test]
async fn channel_ingest_client_response_rejects_neither_result_nor_error() {
    let (svc, state) = service().await;
    let id = alice_channel(&state).await;
    let err = svc
        .channel_ingest(bearer(
            ALICE_TOKEN,
            client_response(&id, result_response("")),
        ))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);
}

/// A client_response for an unknown request is benign: the handler still
/// acks, with an empty conversation_id since no conversation was routed.
#[tokio::test]
async fn channel_ingest_client_response_delivers_to_awaiter_and_acks_empty_conversation() {
    let (svc, state) = service().await;
    let id = alice_channel(&state).await;
    let ack = svc
        .channel_ingest(bearer(
            ALICE_TOKEN,
            client_response(&id, result_response("{\"ok\":true}")),
        ))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(ack.channel_id, id);
    assert!(
        ack.conversation_id.is_empty(),
        "client_response path acks an empty conversation_id"
    );
}

/// A method advertised on an ingest becomes dispatchable to the channel;
/// otherwise send_server_notification refuses it as unsupported.
#[tokio::test]
async fn channel_ingest_advertised_supported_methods_become_usable() {
    let (svc, state) = service().await;
    let id = alice_channel(&state).await;
    let mut req = client_response(&id, result_response("{}"));
    req.supported_methods = vec!["RevealPath".into()];
    svc.channel_ingest(bearer(ALICE_TOKEN, req)).await.unwrap();
    assert!(
        state
            .send_server_notification("alpha", "RevealPath", "{}".into(), None)
            .await
            .is_ok(),
        "advertised method must be usable"
    );
}

/// An ingest carrying no supported_methods keeps the set advertised before.
#[tokio::test]
async fn channel_ingest_empty_supported_methods_does_not_clobber() {
    let (svc, state) = service().await;
    let id = alice_channel(&state).await;
    state
        .update_supported_methods(&id, vec!["RevealPath".into()])
        .await;
    svc.channel_ingest(bearer(
        ALICE_TOKEN,
        client_response(&id, result_response("{}")),
    ))
    .await
    .unwrap();
    assert!(
        state
            .send_server_notification("alpha", "RevealPath", "{}".into(), None)
            .await
            .is_ok(),
        "empty supported_methods must not clobber prior set"
    );
}

// --- ChannelReceive -----------------------------------------------------------

#[tokio::test]
async fn channel_receive_emits_ack_then_idle_replay() {
    let (svc, _) = service().await;
    let mut stream = svc
        .channel_receive(bearer(
            ALICE_TOKEN,
            ChannelReceiveRequest {
                adapter_hint: Some("cli:test".into()),
                workspace: "alpha".into(),
                sender: String::new(),
                resume_after_seq: None,
            },
        ))
        .await
        .unwrap()
        .into_inner();
    let first = stream.next().await.unwrap().unwrap();
    let channel_id = match first.command {
        Some(channel_outbound::Command::Ack(a)) => a.channel_id,
        other => panic!("first frame must be Ack, got {other:?}"),
    };
    assert!(!channel_id.is_empty());
    let second = stream.next().await.unwrap().unwrap();
    match second.command {
        Some(channel_outbound::Command::TurnState(e)) => {
            assert_eq!(e.state, TurnState::Idle as i32);
            assert!(
                e.conversation_id.is_empty(),
                "replay frame carries empty conversation_id"
            );
        }
        other => panic!("second frame must be a TurnState replay, got {other:?}"),
    }
}

// --- Conversation lifecycle guards -------------------------------------------

#[tokio::test]
async fn set_conversation_name_rejects_over_max_chars() {
    let (svc, _) = service().await;
    let req = SetConversationNameRequest {
        conversation_id: "conv".into(),
        name: "x".repeat(201),
        workspace: "alpha".into(),
    };
    let err = tokio::time::timeout(
        Duration::from_secs(1),
        svc.set_conversation_name(bearer(ALICE_TOKEN, req)),
    )
    .await
    .expect("over-limit name must be rejected without dialing the harness")
    .unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);
}

#[tokio::test]
async fn set_conversation_name_rejects_empty_id() {
    let (svc, _) = service().await;
    let req = SetConversationNameRequest {
        conversation_id: String::new(),
        name: "fine".into(),
        workspace: "alpha".into(),
    };
    let err = svc
        .set_conversation_name(bearer(ALICE_TOKEN, req))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);
}

#[tokio::test]
async fn delete_conversation_rejects_empty_id() {
    let (svc, _) = service().await;
    let req = DeleteConversationRequest {
        conversation_id: String::new(),
        workspace: "alpha".into(),
    };
    let err = svc
        .delete_conversation(bearer(ALICE_TOKEN, req))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);
}

#[tokio::test]
async fn get_conversation_history_rejects_empty_id() {
    let (svc, _) = service().await;
    let req = GetConversationHistoryRequest {
        conversation_id: String::new(),
        limit: None,
        owner: String::new(),
        workspace: "alpha".into(),
    };
    let err = svc
        .get_conversation_history(bearer(ALICE_TOKEN, req))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);
}

/// A CancelTurn with no conversation_id is rejected at the gateway, never
/// forwarded blind.
#[tokio::test]
async fn cancel_turn_rejects_empty_conversation_id() {
    let (svc, _) = service().await;
    let req = CancelTurnRequest {
        conversation_id: String::new(),
        workspace: "alpha".into(),
    };
    let err = svc.cancel_turn(bearer(ALICE_TOKEN, req)).await.unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);
}

/// Alice owns a conversation, just not this one. A cold cache must deny on
/// the harness's answer rather than on the mere presence of a listing, so an
/// equality slip that turns the membership test into a non-membership test
/// hands her a neighbour's conversation.
#[tokio::test]
async fn cold_cache_resolve_denies_a_conversation_the_harness_lists_for_other_ids() {
    let (svc, _) = service_on(MockHarness {
        conversations: vec!["other".into()],
        ..Default::default()
    })
    .await;
    let req = DeleteConversationRequest {
        conversation_id: "conv-1".into(),
        workspace: "alpha".into(),
    };
    let err = svc
        .delete_conversation(bearer(ALICE_TOKEN, req))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::PermissionDenied);
}

// --- Tool forwarding ----------------------------------------------------------

/// The relay is a pipe for tool dispatch: the request reaches the harness
/// field-for-field and the harness's call_id comes back unaltered.
#[tokio::test]
async fn dispatch_tool_forwards_request_unmodified_and_returns_harness_call_id() {
    let seen_dispatch: Arc<Mutex<Option<CallToolRequest>>> = Arc::default();
    let (svc, state) = service_on(MockHarness {
        seen_dispatch: seen_dispatch.clone(),
        ..Default::default()
    })
    .await;
    state.record_conversation_owner("conv", ALICE).await;
    let sent = CallToolRequest {
        name: "Bash".into(),
        input_json: r#"{"cmd":"ls"}"#.into(),
        conversation_id: "conv".into(),
        workspace: "alpha".into(),
    };
    let resp = svc
        .dispatch_tool(bearer(ALICE_TOKEN, sent.clone()))
        .await
        .unwrap();
    assert_eq!(resp.into_inner().call_id, MOCK_CALL_ID);
    assert_eq!(*seen_dispatch.lock().unwrap(), Some(sent));
}

/// Result frames are relayed 1:1, in order, with no filtering, truncation,
/// or reordering, and the await request itself reaches the harness untouched.
#[tokio::test]
async fn await_tool_result_streams_harness_frames_unmodified() {
    let frames = vec![
        ToolResultFrame {
            frame: Some(tool_result_frame::Frame::Stdout("out".into())),
        },
        ToolResultFrame {
            frame: Some(tool_result_frame::Frame::Complete(ToolComplete::default())),
        },
    ];
    let (frames_tx, frames_rx) = mpsc::channel(4);
    for frame in &frames {
        frames_tx.send(Ok(frame.clone())).await.unwrap();
    }
    drop(frames_tx);
    let seen_await: Arc<Mutex<Option<AwaitToolResultRequest>>> = Arc::default();
    let (svc, state) = service_on(MockHarness {
        result_frames: Mutex::new(Some(frames_rx)),
        seen_await: seen_await.clone(),
        ..Default::default()
    })
    .await;
    state.record_conversation_owner("conv", ALICE).await;
    state
        .record_dispatched_call(MOCK_CALL_ID, ALICE, "alpha")
        .await;
    let sent = AwaitToolResultRequest {
        call_id: MOCK_CALL_ID.into(),
        conversation_id: "conv".into(),
        workspace: "alpha".into(),
    };
    let stream = svc
        .await_tool_result(bearer(ALICE_TOKEN, sent.clone()))
        .await
        .unwrap()
        .into_inner();
    let got: Vec<ToolResultFrame> = stream.map(|f| f.unwrap()).collect().await;
    assert_eq!(
        got, frames,
        "every harness frame reaches the caller in order and unaltered"
    );
    assert_eq!(*seen_await.lock().unwrap(), Some(sent));
}

/// Cancel forwards on the call_id alone and reports the harness's answer.
#[tokio::test]
async fn cancel_tool_forwards_call_id_and_returns_harness_cancelled() {
    let seen_cancel: Arc<Mutex<Option<CancelToolRequest>>> = Arc::default();
    let (svc, state) = service_on(MockHarness {
        seen_cancel: seen_cancel.clone(),
        ..Default::default()
    })
    .await;
    state
        .record_dispatched_call(MOCK_CALL_ID, ALICE, "alpha")
        .await;
    let sent = CancelToolRequest {
        call_id: MOCK_CALL_ID.into(),
    };
    let resp = svc
        .cancel_tool(bearer(ALICE_TOKEN, sent.clone()))
        .await
        .unwrap();
    assert!(resp.into_inner().cancelled);
    assert_eq!(*seen_cancel.lock().unwrap(), Some(sent));
}

// --- ListGrants ---------------------------------------------------------------

/// Load alpha's toolset-grants ConfigMap into the live ListGrants table, as
/// the toolset-grants watcher does.
async fn load_alpha_grants(state: &GatewayState) {
    let cm = ConfigMap {
        metadata: ObjectMeta {
            name: Some("ws-alpha-relay-grants".into()),
            namespace: Some(NAMESPACE.into()),
            ..Default::default()
        },
        data: Some(
            [(
                GRANTS_DATA_KEY.to_string(),
                "alpha:\n  - name: ssh-credentials\n    grants:\n      github:\n        secret: k\n"
                    .to_string(),
            )]
            .into(),
        ),
        ..Default::default()
    };
    let (grants, errors) = CapabilityGrants::merge_configmaps([&cm]);
    assert!(errors.is_empty(), "fixture grants must parse: {errors:?}");
    *state.capabilities().write().await = grants;
}

#[tokio::test]
async fn list_grants_answers_the_verified_workspace_menu() {
    let (svc, state) = service().await;
    load_alpha_grants(&state).await;
    let resp = svc
        .list_grants(bearer(
            ALICE_TOKEN,
            ListGrantsRequest {
                workspace: "alpha".into(),
            },
        ))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(resp.toolsets.len(), 1);
    assert_eq!(resp.toolsets[0].toolset, "ssh-credentials");
    assert_eq!(resp.toolsets[0].grants, vec!["github".to_string()]);
}

#[tokio::test]
async fn list_grants_for_a_menuless_workspace_is_empty_not_an_error() {
    let (svc, state) = service().await;
    load_alpha_grants(&state).await;
    let resp = svc
        .list_grants(bearer(
            ALICE_TOKEN,
            ListGrantsRequest {
                workspace: "beta".into(),
            },
        ))
        .await
        .unwrap()
        .into_inner();
    assert!(resp.toolsets.is_empty());
}
