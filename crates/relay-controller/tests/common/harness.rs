//! An in-process harness stand-in on a loopback port, for the gateway's
//! forwarding paths.

use std::sync::{Arc, Mutex};

use harness_proto::harness_control_server::{HarnessControl, HarnessControlServer};
use proto_common::{
    AwaitToolResultRequest, CallToolRequest, CancelToolRequest, CancelToolResponse,
    CancelTurnRequest, CancelTurnResponse, ConversationSummary, DeleteConversationRequest,
    DeleteConversationResponse, DispatchToolResponse, GetConversationHistoryRequest,
    GetConversationHistoryResponse, ListConversationsRequest, ListConversationsResponse,
    MintConversationRequest, MintConversationResponse, SetConversationNameRequest,
    SetConversationNameResponse, ToolListUpdate, ToolResultFrame, WatchToolsRequest,
};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status};

/// The call_id the mock harness mints for every dispatch.
pub(crate) const MOCK_CALL_ID: &str = "call-42";

/// `list_conversations` answers from `conversations`. The tool forwarders
/// record the request they were handed, so a test can assert the relay passed
/// it through untouched; `watch_tools` and `await_tool_result` stream whatever
/// the test sends on the matching channel. Every other method is
/// unimplemented, so a test that reaches one has escaped the check it meant to
/// exercise and fails on the wrong status.
#[derive(Default)]
pub(crate) struct MockHarness {
    pub(crate) conversations: Vec<String>,
    pub(crate) tool_updates: Mutex<Option<mpsc::Receiver<Result<ToolListUpdate, Status>>>>,
    pub(crate) result_frames: Mutex<Option<mpsc::Receiver<Result<ToolResultFrame, Status>>>>,
    pub(crate) seen_dispatch: Arc<Mutex<Option<CallToolRequest>>>,
    pub(crate) seen_await: Arc<Mutex<Option<AwaitToolResultRequest>>>,
    pub(crate) seen_cancel: Arc<Mutex<Option<CancelToolRequest>>>,
}

/// Take the stream a test armed, or refuse when it armed none.
#[allow(clippy::result_large_err)]
fn armed<T>(slot: &Mutex<Option<mpsc::Receiver<T>>>) -> Result<ReceiverStream<T>, Status> {
    slot.lock()
        .unwrap()
        .take()
        .map(ReceiverStream::new)
        .ok_or_else(|| Status::unimplemented("mock harness: no stream armed"))
}

#[tonic::async_trait]
impl HarnessControl for MockHarness {
    type WatchToolsStream = ReceiverStream<Result<ToolListUpdate, Status>>;
    type AwaitToolResultStream = ReceiverStream<Result<ToolResultFrame, Status>>;

    async fn list_conversations(
        &self,
        _request: Request<ListConversationsRequest>,
    ) -> Result<Response<ListConversationsResponse>, Status> {
        Ok(Response::new(ListConversationsResponse {
            conversations: self
                .conversations
                .iter()
                .map(|id| ConversationSummary {
                    conversation_id: id.clone(),
                    ..Default::default()
                })
                .collect(),
        }))
    }

    async fn watch_tools(
        &self,
        _request: Request<WatchToolsRequest>,
    ) -> Result<Response<Self::WatchToolsStream>, Status> {
        armed(&self.tool_updates).map(Response::new)
    }

    async fn dispatch_tool(
        &self,
        request: Request<CallToolRequest>,
    ) -> Result<Response<DispatchToolResponse>, Status> {
        *self.seen_dispatch.lock().unwrap() = Some(request.into_inner());
        Ok(Response::new(DispatchToolResponse {
            call_id: MOCK_CALL_ID.into(),
        }))
    }

    async fn await_tool_result(
        &self,
        request: Request<AwaitToolResultRequest>,
    ) -> Result<Response<Self::AwaitToolResultStream>, Status> {
        *self.seen_await.lock().unwrap() = Some(request.into_inner());
        armed(&self.result_frames).map(Response::new)
    }

    async fn cancel_tool(
        &self,
        request: Request<CancelToolRequest>,
    ) -> Result<Response<CancelToolResponse>, Status> {
        *self.seen_cancel.lock().unwrap() = Some(request.into_inner());
        Ok(Response::new(CancelToolResponse { cancelled: true }))
    }

    async fn mint_conversation(
        &self,
        _request: Request<MintConversationRequest>,
    ) -> Result<Response<MintConversationResponse>, Status> {
        Err(Status::unimplemented("mock harness"))
    }

    async fn delete_conversation(
        &self,
        _request: Request<DeleteConversationRequest>,
    ) -> Result<Response<DeleteConversationResponse>, Status> {
        Err(Status::unimplemented("mock harness"))
    }

    async fn set_conversation_name(
        &self,
        _request: Request<SetConversationNameRequest>,
    ) -> Result<Response<SetConversationNameResponse>, Status> {
        Err(Status::unimplemented("mock harness"))
    }

    async fn get_conversation_history(
        &self,
        _request: Request<GetConversationHistoryRequest>,
    ) -> Result<Response<GetConversationHistoryResponse>, Status> {
        Err(Status::unimplemented("mock harness"))
    }

    async fn cancel_turn(
        &self,
        _request: Request<CancelTurnRequest>,
    ) -> Result<Response<CancelTurnResponse>, Status> {
        Err(Status::unimplemented("mock harness"))
    }
}

/// Serve `mock` on an ephemeral loopback port and return its address.
pub(crate) async fn spawn_mock_harness(mock: MockHarness) -> std::net::SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(
        tonic::transport::Server::builder()
            .add_service(HarnessControlServer::new(mock))
            .serve_with_incoming(tokio_stream::wrappers::TcpListenerStream::new(listener)),
    );
    addr
}
