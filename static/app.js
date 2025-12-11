const statusText = document.getElementById("status-text");
const indicator = document.getElementById("touch-indicator");
const exitBtn = document.getElementById("exit-btn");
const connectBtn = document.getElementById("connect-btn");
const pad = document.getElementById("pad");

let ws;
let touchPoint = { x: 0, y: 0 };
let frameRequested = false;
let connected = false;
let connecting = false;

function connect() {
  if (connecting || connected) return;
  const loc = window.location;
  const params = new URLSearchParams(loc.search);
  const explicitPort = params.get("ws");
  const httpPort = loc.port || "";
  const tryPorts = [explicitPort, "9001", httpPort].filter(Boolean);
  const wsScheme = loc.protocol === "https:" ? "wss" : "ws";
  let attempt = 0;

  connecting = true;
  connectBtn.disabled = true;
  statusText.textContent = "Connecting...";

  const tryConnect = () => {
    if (attempt >= tryPorts.length) {
      statusText.textContent = "Connection failed";
      connectBtn.disabled = false;
      connecting = false;
      return;
    }
    const port = tryPorts[attempt];
    const wsUrl = `${wsScheme}://${loc.hostname}:${port}/ws`;
    statusText.textContent = `Connecting ${wsUrl}`;

    ws = new WebSocket(wsUrl);
    ws.binaryType = "arraybuffer";

    const cleanup = () => {
      ws?.removeEventListener("open", onOpen);
      ws?.removeEventListener("message", onMsg);
      ws?.removeEventListener("close", onClose);
      ws?.removeEventListener("error", onErr);
    };

    const onOpen = () => {
      statusText.textContent = "Authorizing...";
      sendInit();
    };

    const onMsg = (event) => {
      const msg = event.data;
      if (msg === "connected") {
        connected = true;
        connecting = false;
        statusText.textContent = "Connected";
        statusText.classList.add("ready");
        connectBtn.classList.add("hidden");
        connectBtn.disabled = false;
        cleanup();
      } else if (msg === "rejected" || msg === "Already connected") {
        statusText.textContent = msg;
        statusText.classList.remove("ready");
        disconnect();
      }
    };

    const onClose = () => {
      cleanup();
      if (connected) {
        connected = false;
        statusText.textContent = "Disconnected";
        statusText.classList.remove("ready");
        indicator.classList.remove("active");
        connectBtn.classList.remove("hidden");
        connectBtn.disabled = false;
        connecting = false;
      } else {
        attempt += 1;
        tryConnect();
      }
    };

    const onErr = () => {
      cleanup();
      attempt += 1;
      tryConnect();
    };

    ws.addEventListener("open", onOpen);
    ws.addEventListener("message", onMsg);
    ws.addEventListener("close", onClose);
    ws.addEventListener("error", onErr);
  };

  tryConnect();
}

function sendInit() {
  const payload = JSON.stringify({
    type: "init",
    width: window.innerWidth,
    height: window.innerHeight,
  });
  ws?.send(payload);
}

function requestFullscreen() {
  if (document.fullscreenElement) return Promise.resolve();
  return pad.requestFullscreen?.() ?? Promise.resolve();
}

function scheduleSend() {
  if (frameRequested || !connected) return;
  frameRequested = true;
  requestAnimationFrame(() => {
    frameRequested = false;
    const buf = new ArrayBuffer(4);
    const view = new DataView(buf);
    view.setUint16(0, touchPoint.x, false); // big-endian
    view.setUint16(2, touchPoint.y, false);
    ws?.send(buf);
  });
}

function onTouchStart(e) {
  if (e.target === connectBtn || e.target === exitBtn) return;
  e.preventDefault();
  if (!connected) return;
  indicator.classList.add("active");
  updatePoint(e);
}

function onTouchMove(e) {
  if (e.target === connectBtn || e.target === exitBtn) return;
  e.preventDefault();
  if (!connected) return;
  updatePoint(e);
}

function onTouchEnd(e) {
  if (e.target === connectBtn || e.target === exitBtn) return;
  e.preventDefault();
  indicator.classList.remove("active");
}

function updatePoint(e) {
  const touch = e.touches[0];
  if (!touch) return;
  const rect = pad.getBoundingClientRect();
  const relX = Math.max(0, Math.min(1, (touch.clientX - rect.left) / rect.width));
  const relY = Math.max(0, Math.min(1, (touch.clientY - rect.top) / rect.height));
  const clientW = Math.max(1, Math.min(65535, Math.round(window.innerWidth)));
  const clientH = Math.max(1, Math.min(65535, Math.round(window.innerHeight)));
  const pxX = Math.min(clientW - 1, Math.max(0, Math.round(relX * clientW)));
  const pxY = Math.min(clientH - 1, Math.max(0, Math.round(relY * clientH)));
  touchPoint.x = pxX;
  touchPoint.y = pxY;
  scheduleSend();
}

function disconnect() {
  ws?.close();
  ws = undefined;
}

function startConnectFlow() {
  requestFullscreen()
    .catch(() => {}) // ignore fullscreen failures
    .finally(() => connect());
}

pad.addEventListener("touchstart", onTouchStart, { passive: false });
pad.addEventListener("touchmove", onTouchMove, { passive: false });
pad.addEventListener("touchend", onTouchEnd, { passive: false });
pad.addEventListener("touchcancel", onTouchEnd, { passive: false });

connectBtn.addEventListener("click", () => {
  startConnectFlow();
});

// Mobile Safari often doesn't fire click on touch; handle touchstart as well.
connectBtn.addEventListener("touchstart", (e) => {
  e.preventDefault();
  startConnectFlow();
});

exitBtn.addEventListener("click", () => {
  if (document.fullscreenElement) {
    document.exitFullscreen?.();
  }
  disconnect();
});

window.addEventListener("resize", () => {
  if (connected) sendInit();
});
