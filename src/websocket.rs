use crate::connection::{ApprovalBroker, ConnectionSlot};
use crate::mouse::MouseController;
use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::{ConnectInfo, State},
    response::IntoResponse,
    routing::get,
    Router,
};
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
use std::net::SocketAddr;
use std::sync::Arc;
use tracing::{info, warn};

#[derive(Clone)]
pub struct AppState {
    pub slot: Arc<ConnectionSlot>,
    pub broker: ApprovalBroker,
    pub mouse: Arc<MouseController>,
}

#[derive(Default)]
struct ClientCtx {
    width: u16,
    height: u16,
}

#[derive(Deserialize)]
struct InitMsg {
    #[serde(rename = "type")]
    msg_type: String,
    width: u16,
    height: u16,
}

#[derive(Deserialize)]
struct PingMsg {
    #[serde(rename = "type")]
    msg_type: String,
    t: u64,
}

/// Build router exposing /ws endpoint.
pub fn build_ws_router(state: AppState) -> anyhow::Result<Router> {
    let router = Router::new()
        .route("/ws", get(ws_handler))
        .with_state(state);
    Ok(router)
}

/// Start websocket server on given port.
pub async fn serve_ws(app: Router, port: u16) -> anyhow::Result<()> {
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    let svc = app.into_make_service_with_connect_info::<SocketAddr>();
    axum::serve(listener, svc).await?;
    Ok(())
}

async fn ws_handler(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, addr, state))
}

async fn handle_socket(stream: WebSocket, addr: SocketAddr, state: AppState) {
    if !state.slot.try_claim(addr).await {
        warn!("Rejecting {}: already connected client present", addr);
        let _ = send_one(stream, Message::Text("Already connected".into())).await;
        return;
    }

    let approved = state.broker.request_approval(addr).await;
    if !approved {
        let _ = send_one(stream, Message::Text("rejected".into())).await;
        state.slot.release().await;
        return;
    }

    let (mut sender, mut receiver) = stream.split();
    if sender.send(Message::Text("connected".into())).await.is_err() {
        state.slot.release().await;
        return;
    }

    // This handler runs on a single async task, so no locking is needed.
    let mut ctx = ClientCtx::default();
    let mouse = state.mouse.clone();
    let slot = state.slot.clone();

    {
        let (w, h) = mouse.screen_size();
        let msg = serde_json::json!({"type":"remote_screen","width":w,"height":h}).to_string();
        if sender.send(Message::Text(msg.into())).await.is_err() {
            slot.release().await;
            return;
        }
    }

    while let Some(msg) = receiver.next().await {
        match msg {
            Ok(Message::Text(text)) => {
                if let Ok(init) = serde_json::from_str::<InitMsg>(&text) {
                    if init.msg_type == "init" {
                        ctx.width = init.width;
                        ctx.height = init.height;
                        info!("📡 Screen size: {}x{} from {}", init.width, init.height, addr);
                        continue;
                    }
                }

                // App-level ping/pong for RTT measurement.
                if let Ok(ping) = serde_json::from_str::<PingMsg>(&text) {
                    if ping.msg_type == "ping" {
                        let pong = serde_json::json!({"type":"pong","t":ping.t}).to_string();
                        if sender.send(Message::Text(pong.into())).await.is_err() {
                            break;
                        }
                    }
                }
            }
            Ok(Message::Binary(bin)) => {
                if bin.len() >= 4 {
                    let x = u16::from_be_bytes([bin[0], bin[1]]);
                    let y = u16::from_be_bytes([bin[2], bin[3]]);
                    if ctx.width > 0 && ctx.height > 0 {
                        let _ = mouse.move_absolute(ctx.width, ctx.height, x, y);
                    }
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(err) => {
                warn!("WebSocket error from {}: {}", addr, err);
                break;
            }
        }
    }

    slot.release().await;
    info!("✗ Client disconnected: {}", addr);
}

async fn send_one(mut stream: WebSocket, msg: Message) -> Result<(), axum::Error> {
    stream.send(msg).await
}
