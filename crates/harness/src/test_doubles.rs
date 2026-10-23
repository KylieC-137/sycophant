//! Shared `#[cfg(test)]` test doubles reachable across the crate's unit-test
//! modules. `FakeToolset` backs the `ToolRouter<A>` toolset generic without a
//! live gRPC server; `EndlessToolset`/`EndlessSource` drive the cancellation
//! tests that run a never-terminating sub-agent stream through the router.
//! `RecordingRelay` stands in for the relay and records what the harness
//! delivers to it.

use std::sync::Arc;

use async_trait::async_trait;
use proto_common::{ContentBlock, StreamItem, TurnStateEvent};
use toolset_proto::{turn_event, ContentDelta, TurnEvent, TurnRequest};

use crate::clients::{RelayRpc, ServerRequestOutcome, ToolsetRpc, TurnSource};
use crate::instructions::Instructions;

/// The workspace name used by test routers/instructions.
pub(crate) const TEST_WS: &str = "ws";

/// An empty-workspace instructions over a throwaway temp dir. The dir is leaked so
/// the returned `Arc<Instructions>` can outlive this call; tests that need populated
/// content build their own `Instructions` directly.
pub(crate) fn test_instructions() -> Arc<Instructions> {
    let root = tempfile::TempDir::new().unwrap().keep();
    std::fs::create_dir_all(root.join(TEST_WS)).unwrap();
    Arc::new(Instructions::new(root))
}

/// A toolset stub backing the `ToolRouter<A>` generic in tests that exercise the
/// runtime and channel-stream paths. Tool dispatch runs in-process through
/// `DispatchState`, not this seam, so the tool-call RPCs are gone; only the
/// sub-agent turn surface remains.
#[derive(Clone)]
pub(crate) struct FakeToolset;

#[async_trait]
impl ToolsetRpc for FakeToolset {
    async fn turn(&mut self, _request: TurnRequest) -> Result<Box<dyn TurnSource>, String> {
        Err("FakeToolset: turn unused in these tests".into())
    }

    async fn cancel_turn(&mut self, _conversation_id: &str) -> Result<(), String> {
        Ok(())
    }
}

/// A toolset whose every turn yields a source that never terminates — used to
/// prove a fired cancel abandons an in-flight sub-agent stream instead of
/// draining it. Drives the router-level cancellation test.
pub(crate) struct EndlessToolset;

#[async_trait]
impl ToolsetRpc for EndlessToolset {
    async fn turn(&mut self, _request: TurnRequest) -> Result<Box<dyn TurnSource>, String> {
        Ok(Box::new(EndlessSource))
    }
    async fn cancel_turn(&mut self, _conversation_id: &str) -> Result<(), String> {
        Ok(())
    }
}

/// A turn source that keeps emitting content deltas forever; only a fired
/// cancel can stop a consumer reading it.
pub(crate) struct EndlessSource;

#[async_trait]
impl TurnSource for EndlessSource {
    async fn next_event(&mut self) -> Option<Result<TurnEvent, String>> {
        Some(Ok(TurnEvent {
            event: Some(turn_event::Event::ContentDelta(ContentDelta {
                text: "more".into(),
            })),
        }))
    }
}

/// Test relay that answers every call successfully and records the stream
/// items and turn-state frames (with their subject) the harness hands it.
#[derive(Default)]
pub(crate) struct RecordingRelay {
    pub(crate) stream_items: Vec<(String, StreamItem)>,
    pub(crate) turn_states: Vec<(TurnStateEvent, String)>,
}

#[async_trait]
impl RelayRpc for RecordingRelay {
    async fn send_server_notification(
        &mut self,
        _workspace: &str,
        _method: &str,
        _params_json: &str,
    ) -> Result<bool, String> {
        Ok(true)
    }
    async fn send_server_request_and_await(
        &mut self,
        _workspace: &str,
        _request_id: &str,
        _method: &str,
        _params_json: &str,
        _timeout_seconds: u32,
    ) -> Result<ServerRequestOutcome, String> {
        Ok(ServerRequestOutcome::Result(String::new()))
    }
    async fn deliver_stream_item(
        &mut self,
        channel_stream_id: &str,
        item: StreamItem,
    ) -> Result<bool, String> {
        self.stream_items
            .push((channel_stream_id.to_string(), item));
        Ok(true)
    }
    async fn deliver_reply(
        &mut self,
        _conversation_id: &str,
        _content: Vec<ContentBlock>,
    ) -> Result<bool, String> {
        Ok(true)
    }
    async fn deliver_turn_state(
        &mut self,
        turn_state: TurnStateEvent,
        subject: &str,
    ) -> Result<bool, String> {
        self.turn_states.push((turn_state, subject.to_string()));
        Ok(true)
    }
}
