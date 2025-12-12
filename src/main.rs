mod connection;
mod http;
mod mouse;
mod udp;
mod websocket;

use crate::connection::{ApprovalBroker, ConnectionSlot, approval_worker};
use crate::mouse::MouseController;
use crate::websocket::build_ws_router;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use tokio::task::JoinSet;
use tracing::{error, info};
use tracing_subscriber::FmtSubscriber;

#[derive(Debug, Clone)]
struct Settings {
    http_port: u16,
    ws_port: u16,
    udp_port: u16,
    auto_approve: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();
    let settings = parse_args();

    let connection_slot = Arc::new(ConnectionSlot::new());
    let (approval_broker, approval_rx) = ApprovalBroker::new(settings.auto_approve);
    tokio::spawn(approval_worker(approval_rx));

    let mouse = Arc::new(MouseController::new()?);

    info!("🖱️  Penput");
    info!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    info!(
        "Server running at:\n  HTTP: http://{}:{}\n  WebSocket: ws://{}:{}/ws\n  UDP (iOS): udp://{}:{}",
        local_ip(),
        settings.http_port,
        local_ip(),
        settings.ws_port,
        local_ip(),
        settings.udp_port,
    );
    info!("Open this URL on your mobile browser.");
    info!("Press Ctrl+C to stop.");

    let mut tasks = JoinSet::new();
    {
        let state = websocket::AppState {
            slot: connection_slot.clone(),
            broker: approval_broker.clone(),
            mouse: mouse.clone(),
        };
        let ws_router = build_ws_router(state)?;
        tasks.spawn(websocket::serve_ws(ws_router, settings.ws_port));
    }

    {
        let http_router = http::build_http_router()?;
        tasks.spawn(http::serve_http(http_router, settings.http_port));
    }

    {
        let state = udp::UdpState {
            slot: connection_slot.clone(),
            broker: approval_broker.clone(),
            mouse: mouse.clone(),
        };
        tasks.spawn(udp::serve_udp(state, settings.udp_port));
    }

    while let Some(res) = tasks.join_next().await {
        if let Err(err) = res {
            error!("Server task failed: {err}");
        }
    }

    Ok(())
}

fn init_tracing() {
    let subscriber = FmtSubscriber::builder()
        .with_max_level(tracing::Level::INFO)
        .finish();
    let _ = tracing::subscriber::set_global_default(subscriber);
}

fn parse_args() -> Settings {
    let mut http_port = 8080u16;
    let mut ws_port = 9001u16;
    let mut udp_port = 9002u16;
    let mut auto_approve = false;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--port" => {
                if let Some(val) = args.next() {
                    http_port = val.parse().unwrap_or(http_port);
                }
            }
            "--ws-port" => {
                if let Some(val) = args.next() {
                    ws_port = val.parse().unwrap_or(ws_port);
                }
            }
            "--udp-port" => {
                if let Some(val) = args.next() {
                    udp_port = val.parse().unwrap_or(udp_port);
                }
            }
            "--auto-approve" => {
                auto_approve = true;
            }
            _ => {}
        }
    }

    Settings {
        http_port,
        ws_port,
        udp_port,
        auto_approve,
    }
}

fn local_ip() -> IpAddr {
    local_ip_address::local_ip().unwrap_or(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)))
}
