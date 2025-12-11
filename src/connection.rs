use std::io::Write;
use std::net::SocketAddr;

use tokio::sync::{mpsc, oneshot, Mutex};
use tracing::warn;

/// Shared slot to enforce a single active client.
#[derive(Debug)]
pub struct ConnectionSlot {
    inner: Mutex<Option<SocketAddr>>,
}

impl ConnectionSlot {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(None),
        }
    }

    /// Try to claim the slot for a new client. Returns true if claimed.
    pub async fn try_claim(&self, addr: SocketAddr) -> bool {
        let mut guard = self.inner.lock().await;
        if guard.is_some() {
            return false;
        }
        *guard = Some(addr);
        true
    }

    /// Release the slot (called on disconnect).
    pub async fn release(&self) {
        let mut guard = self.inner.lock().await;
        *guard = None;
    }
}

#[derive(Debug)]
pub struct PendingApproval {
    pub ip: SocketAddr,
    pub respond: oneshot::Sender<bool>,
}

#[derive(Clone)]
pub struct ApprovalBroker {
    auto_approve: bool,
    tx: mpsc::Sender<PendingApproval>,
}

impl ApprovalBroker {
    pub fn new(auto_approve: bool) -> (Self, mpsc::Receiver<PendingApproval>) {
        let (tx, rx) = mpsc::channel(16);
        (Self { auto_approve, tx }, rx)
    }

    /// Enqueue approval and wait for CLI decision.
    pub async fn request_approval(&self, ip: SocketAddr) -> bool {
        if self.auto_approve {
            return true;
        }

        let (tx, rx) = oneshot::channel();
        if let Err(err) = self.tx.send(PendingApproval { ip, respond: tx }).await {
            warn!("Failed to enqueue approval request: {err}");
            return false;
        }
        rx.await.unwrap_or(false)
    }
}

/// CLI worker that handles approve/deny prompts.
pub async fn approval_worker(mut rx: mpsc::Receiver<PendingApproval>) {
    use tokio::io::{stdin, AsyncBufReadExt, BufReader};

    let reader = BufReader::new(stdin());
    let mut lines = reader.lines();

    while let Some(pending) = rx.recv().await {
        let ip = pending.ip;
        let respond = pending.respond;

        if respond.is_closed() {
            continue;
        }

        print!("[{}] 📱 Connection request from {}\n", timestamp(), ip);
        print!("           Approve? (y/n): ");
        let _ = std::io::stdout().flush();

        let mut approved = false;
        match lines.next_line().await {
            Ok(Some(line)) => {
                let trimmed = line.trim().to_lowercase();
                approved = trimmed == "y" || trimmed == "yes";
            }
            Ok(None) => {}
            Err(err) => warn!("Failed to read input: {}", err),
        }

        match respond.send(approved) {
            Ok(_) if approved => println!("[{}] ✓ Client approved: {}", timestamp(), ip),
            Ok(_) => println!("[{}] ✗ Client rejected: {}", timestamp(), ip),
            Err(_) => warn!("Approval channel closed before sending decision"),
        }
    }
}

fn timestamp() -> String {
    use chrono::Local;
    Local::now().format("%H:%M:%S").to_string()
}
