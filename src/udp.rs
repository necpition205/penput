use crate::connection::{ApprovalBroker, ConnectionSlot};
use crate::mouse::MouseController;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::time::{self, Duration, Instant};
use tracing::{info, warn};

// UDP packet types (client -> server)
const MSG_HELLO: u8 = 0x01; // [type=1][w:u16be][h:u16be]
const MSG_MOVE: u8 = 0x02; // [type=2][x:u16be][y:u16be]
const MSG_PING: u8 = 0x03; // [type=3][t:u64be]

// UDP packet types (server -> client)
const MSG_ACCEPT: u8 = 0x10; // [type=0x10][remote_w:u16be][remote_h:u16be]
const MSG_REJECT: u8 = 0x11; // [type=0x11]
const MSG_BUSY: u8 = 0x12; // [type=0x12]
const MSG_PONG: u8 = 0x13; // [type=0x13][t:u64be]

const SESSION_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone)]
pub struct UdpState {
    pub slot: Arc<ConnectionSlot>,
    pub broker: ApprovalBroker,
    pub mouse: Arc<MouseController>,
}

struct UdpSession {
    addr: SocketAddr,
    client_w: u16,
    client_h: u16,
    last_seen: Instant,
}

/// Start UDP server on given port.
///
/// This path is intended for the iOS native client to avoid WebKit-induced stutter.
/// The server enforces a single active client using the shared ConnectionSlot.
pub async fn serve_udp(state: UdpState, port: u16) -> anyhow::Result<()> {
    let socket = UdpSocket::bind(("0.0.0.0", port)).await?;
    info!("UDP server listening on 0.0.0.0:{}", port);

    let mut buf = [0u8; 64];
    let mut tick = time::interval(Duration::from_secs(1));
    let mut session: Option<UdpSession> = None;

    loop {
        tokio::select! {
            res = socket.recv_from(&mut buf) => {
                let (len, addr) = match res {
                    Ok(v) => v,
                    Err(err) => {
                        warn!("UDP recv error: {err}");
                        continue;
                    }
                };

                if len == 0 {
                    continue;
                }

                let now = Instant::now();
                let pkt = &buf[..len];

                match pkt[0] {
                    MSG_HELLO => {
                        if len < 5 {
                            continue;
                        }

                        let w = u16::from_be_bytes([pkt[1], pkt[2]]);
                        let h = u16::from_be_bytes([pkt[3], pkt[4]]);

                        let (screen_w, screen_h) = state.mouse.screen_size();
                        let screen_w_be = screen_w.to_be_bytes();
                        let screen_h_be = screen_h.to_be_bytes();
                        let accept = [MSG_ACCEPT, screen_w_be[0], screen_w_be[1], screen_h_be[0], screen_h_be[1]];

                        match session.as_mut() {
                            Some(s) if s.addr == addr => {
                                s.client_w = w;
                                s.client_h = h;
                                s.last_seen = now;
                                let _ = socket.send_to(&accept, addr).await;
                            }
                            Some(_) => {
                                let _ = socket.send_to(&[MSG_BUSY], addr).await;
                            }
                            None => {
                                if !state.slot.try_claim(addr).await {
                                    let _ = socket.send_to(&[MSG_BUSY], addr).await;
                                    continue;
                                }

                                let approved = state.broker.request_approval(addr).await;
                                if !approved {
                                    state.slot.release().await;
                                    let _ = socket.send_to(&[MSG_REJECT], addr).await;
                                    continue;
                                }

                                session = Some(UdpSession {
                                    addr,
                                    client_w: w,
                                    client_h: h,
                                    last_seen: now,
                                });

                                info!("✓ UDP client approved: {} ({}x{})", addr, w, h);
                                let _ = socket.send_to(&accept, addr).await;
                            }
                        }
                    }
                    MSG_MOVE => {
                        if len < 5 {
                            continue;
                        }

                        let Some(s) = session.as_mut() else {
                            continue;
                        };
                        if s.addr != addr {
                            continue;
                        }

                        s.last_seen = now;
                        let x = u16::from_be_bytes([pkt[1], pkt[2]]);
                        let y = u16::from_be_bytes([pkt[3], pkt[4]]);

                        if s.client_w > 0 && s.client_h > 0 {
                            let _ = state.mouse.move_absolute(s.client_w, s.client_h, x, y);
                        }
                    }
                    MSG_PING => {
                        if len < 9 {
                            continue;
                        }

                        let Some(s) = session.as_mut() else {
                            continue;
                        };
                        if s.addr != addr {
                            continue;
                        }

                        s.last_seen = now;

                        // Echo the timestamp back for RTT measurement.
                        let mut out = [0u8; 9];
                        out[0] = MSG_PONG;
                        out[1..9].copy_from_slice(&pkt[1..9]);
                        let _ = socket.send_to(&out, addr).await;
                    }
                    _ => {}
                }
            }
            _ = tick.tick() => {
                if let Some(s) = &session {
                    if s.last_seen.elapsed() > SESSION_TIMEOUT {
                        info!("✗ UDP client timed out: {}", s.addr);
                        session = None;
                        state.slot.release().await;
                    }
                }
            }
        }
    }
}
