# Penput

Penput turns your mobile/tablet into a wireless touchpad for your PC. The app serves a minimal UI over HTTP, streams touch coordinates via WebSocket, and maps them to absolute mouse positions on the host machine.

## Features
- **Low-latency absolute mouse movement** from mobile touch
- **Single client guard**: only one active connection at a time
- **Approval flow**: CLI prompt to approve/reject new connections
- **Fullscreen connect**: user taps Connect → fullscreen entry
- **Connection state feedback**: Connected / Disconnected / Failed
- **Automated release**: commit messages containing `release` trigger GitHub Actions to run `cargo build --release`, create a GitHub Release, and upload the binary

## Stack
- Rust (tokio, axum, tokio-tungstenite, enigo, display-info, tracing)
- Frontend: static HTML/CSS/JS
- CI: GitHub Actions (`.github/workflows/release-build.yml`)

## How it works
1) **HTTP server** (`--port`, default 8080): serves HTML/JS/CSS.
2) **WebSocket server** (`--ws-port`, default 9001):  
   - receives `init` JSON → captures client screen size  
   - receives 4-byte big-endian binary (`x:u16 | y:u16`) → maps to host absolute mouse position
3) **UDP server (iOS native)** (`--udp-port`, default 9002):
   - receives `HELLO`/`MOVE`/`PING` binary packets from the iOS native client
   - enforces the same single-client + CLI approval flow as WebSocket
3) **Approval**: new connections require CLI `y/n`.
4) **Mouse movement**: computed and executed on a dedicated worker thread to keep WS handling lean.

## Install
```bash
rustup default stable
cargo build

# or
cargo install penput
```

## Run
```bash
cargo run -- --port 8080 --ws-port 9001 --udp-port 9002
```
- `--auto-approve`: skip manual approval

## iOS Native (UDP) mode
This project now supports an **iOS native UDP client** (recommended when WebKit-based browsers stutter).

### Server endpoint
- UDP: `udp://<PC_IP>:9002` by default

### UDP packet protocol (big-endian)
Client → Server:
- `HELLO` (0x01): `[0x01][w:u16][h:u16]`
- `MOVE`  (0x02): `[0x02][x:u16][y:u16]`
- `PING`  (0x03): `[0x03][t:u64]` (client timestamp in ms)

Server → Client:
- `ACCEPT` (0x10): `[0x10]`
- `REJECT` (0x11): `[0x11]`
- `BUSY`   (0x12): `[0x12]` (another client is already connected)
- `PONG`   (0x13): `[0x13][t:u64]` (echoed timestamp)

Notes:
- The server keeps only **one active UDP session** at a time.
- If the server doesn't receive traffic for ~5 seconds, the session is released.

### iOS client skeleton
The repository contains an iOS SwiftUI skeleton under:
- `ios/PenputIOSClient/`

It uses:
- `Network.framework` (`NWConnection` over UDP)
- a `UIViewRepresentable` touch surface for low-overhead touch capture
- `CADisplayLink` to pace sends (latest-value only)

### iOS Local Network permission
iOS requires a local network usage prompt for LAN UDP/TCP traffic.
Add `NSLocalNetworkUsageDescription` to `Info.plist` in your Xcode project, e.g.:
- "Penput needs local network access to send touchpad data to your PC."

## Low-cost iOS install workflow (7-day)
iOS apps must be signed. Without the paid Apple Developer Program you can still test, but usually **the app expires every ~7 days**.

Practical approach while you don't have a Mac:
1) Build the iOS app using a remote macOS environment (later: your own MacBook).
2) Install on iPad using a Windows sideload tool (e.g. Sideloadly/AltStore).
3) Re-sign / refresh weekly.

## Using (mobile)
1) Start the server and note the URL (e.g., `http://192.168.0.10:8080`).
2) On mobile (same LAN), open `http://<PC_IP>:8080/?ws=9001`.
3) Tap **Connect** → fullscreen → approve in PC CLI → state turns **Connected**.
4) Move the mouse by touching the pad. Use **Exit (✕)** to leave fullscreen and disconnect.

## Coordinate protocol
- Init (JSON): `{"type":"init","width":<u16>,"height":<u16>}`
- Move (Binary): 4 bytes, big-endian, `x:u16`, `y:u16` (client viewport absolute coords)

## Approval (CLI)
- Shows `[HH:MM:SS] 📱 Connection request from <IP>`
- `y`/`yes` → approve, anything else/EOF → reject

## Latency / performance notes
- WS loop: parse coords and enqueue to channel (minimal locking)
- Mouse moves: dedicated worker thread calls enigo; avoids blocking WS handler
- Frontend: `requestAnimationFrame`-bounded sends; normalized coords packed to `u16`

## GitHub Actions (auto release)
Workflow: `.github/workflows/release-build.yml`
- Trigger: **push with commit message containing `release`**
- Steps: checkout → install Rust → cache → `cargo build --release` → create GitHub Release (tag `release-<sha>`) → upload `target/release/penput`
- Secrets: uses default `GITHUB_TOKEN`

## Troubleshooting
- **Mobile cannot reach**: ensure same LAN; open 8080/9001 in firewall.
- **Connection failed**: check `?ws=<port>` matches actual WS port.
- **No approval prompt**: check server terminal, focus the CLI window.
- **Choppy movement**: verify network quality. Worker thread + RAF already minimize jitter.

## Dev notes
- Single-client slot: new connections are rejected while one is active.
- Coordinates are absolute only (no gestures/relative moves).
- Current build target assumes Windows host (enigo on Windows).
