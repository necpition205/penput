import {
  InputMode,
  computePadSize,
  mapToPadCoordinates,
  absoluteToScreen,
  RelativeTracker,
} from "./touchpad.js";

const statusText = document.getElementById("status-text");
const indicator = document.getElementById("touch-indicator");
const exitBtn = document.getElementById("exit-btn");
const connectBtn = document.getElementById("connect-btn");
const pad = document.getElementById("pad");
const padSurface = document.getElementById("pad-surface");
const padControls = document.getElementById("pad-controls");
const padSizeInput = document.getElementById("pad-size");
const padSizeValue = document.getElementById("pad-size-value");
const modeSelect = document.getElementById("input-mode");

function setUiConnected(isConnected) {
  if (isConnected) {
    exitBtn?.classList.remove("hidden");
    connectBtn?.classList.add("hidden");
    if (connectBtn) connectBtn.disabled = false;
  } else {
    exitBtn?.classList.add("hidden");
    connectBtn?.classList.remove("hidden");
    if (connectBtn) connectBtn.disabled = false;
  }
}

let ws;
let touchPoint = { x: 0, y: 0 };
let frameRequested = false;
let connected = false;
let connecting = false;

// Reuse the same buffer to avoid periodic GC pauses on mobile.
const moveBuf = new ArrayBuffer(4);
const moveView = new DataView(moveBuf);

// Cache layout values for the hot path.
let padRect = null;
let clientW = Math.max(1, Math.min(65535, Math.round(window.innerWidth)));
let clientH = Math.max(1, Math.min(65535, Math.round(window.innerHeight)));

let padScalePct = Number(padSizeInput?.value ?? 100);

let remoteW = 0;
let remoteH = 0;

// Input mode: absolute or relative.
let inputMode = InputMode.ABSOLUTE;
const relativeTracker = new RelativeTracker(1.5);

// Computed pad size (cached).
let padW = 0;
let padH = 0;

// Metrics (shown on-screen so mobile can debug without console)
let wsUrlInUse = "";
let lastRttMs = null;
let lastPongAt = 0;
let pingTimer = null;
let metricsTimer = null;
let sendCount = 0;
let sendCountWindowStart = performance.now();
let sendRate = 0;

const metricsEl = document.createElement("div");
metricsEl.id = "metrics";
document.body.appendChild(metricsEl);

function refreshClientSize() {
  const rect = padRect || padSurface.getBoundingClientRect();
  clientW = Math.max(1, Math.min(65535, Math.round(rect.width)));
  clientH = Math.max(1, Math.min(65535, Math.round(rect.height)));
}

function refreshPadRect() {
  padRect = padSurface.getBoundingClientRect();
}

function applyPadSize() {
  const pct = Math.max(10, Math.min(100, Math.round(padScalePct)));
  padScalePct = pct;
  if (padSizeInput) padSizeInput.value = String(pct);
  if (padSizeValue) padSizeValue.textContent = `${pct}%`;

  // Use pure function from touchpad.js.
  const size = computePadSize(
    window.innerWidth,
    window.innerHeight,
    remoteW,
    remoteH,
    pct
  );
  padW = size.width;
  padH = size.height;

  padSurface.style.width = `${padW}px`;
  padSurface.style.height = `${padH}px`;

  refreshPadRect();
  refreshClientSize();
}

function startMetricsLoop() {
  if (metricsTimer) return;
  metricsTimer = window.setInterval(() => {
    const rtt = lastRttMs == null ? "-" : `${Math.round(lastRttMs)}ms`;
    const pongAge = lastPongAt ? `${Math.round(performance.now() - lastPongAt)}ms ago` : "-";
    metricsEl.textContent =
      `WS: ${connected ? "connected" : connecting ? "connecting" : "disconnected"}\n` +
      `URL: ${wsUrlInUse || "-"}\n` +
      `Client: ${clientW}x${clientH}\n` +
      `Mode: ${inputMode}\n` +
      `Touch: ${touchPoint.x},${touchPoint.y}\n` +
      `Send: ${sendRate.toFixed(1)}/s\n` +
      `RTT: ${rtt} (pong ${pongAge})`;
  }, 250);
}

function stopMetricsLoop() {
  if (metricsTimer) {
    window.clearInterval(metricsTimer);
    metricsTimer = null;
  }
}

function updateSendRate() {
  const now = performance.now();
  const elapsed = Math.max(1, now - sendCountWindowStart);
  sendRate = (sendCount * 1000) / elapsed;
  if (elapsed >= 1000) {
    sendCount = 0;
    sendCountWindowStart = now;
  }
}

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
  startMetricsLoop();

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
    wsUrlInUse = wsUrl;

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

      if (pingTimer) window.clearInterval(pingTimer);
      pingTimer = window.setInterval(() => {
        if (!connected) return;
        const t = Math.floor(performance.now());
        try {
          ws?.send(JSON.stringify({ type: "ping", t }));
        } catch (_) {
          // ignore
        }
      }, 1000);
    };

    const onMsg = (event) => {
      const msg = event.data;
      if (msg === "connected") {
        connected = true;
        connecting = false;
        statusText.textContent = "Connected";
        statusText.classList.add("ready");
        setUiConnected(true);
        refreshClientSize();
        refreshPadRect();
      } else if (msg === "rejected" || msg === "Already connected") {
        statusText.textContent = msg;
        statusText.classList.remove("ready");
        disconnect();
      } else if (typeof msg === "string" && msg.startsWith("{")) {
        // App-level pong for RTT measurement.
        try {
          const obj = JSON.parse(msg);
          if (obj && obj.type === "remote_screen" && typeof obj.width === "number" && typeof obj.height === "number") {
            remoteW = obj.width;
            remoteH = obj.height;
            applyPadSize();
            if (connected) sendInit();
            return;
          }
          if (obj && obj.type === "pong" && typeof obj.t === "number") {
            lastRttMs = performance.now() - obj.t;
            lastPongAt = performance.now();
          }
        } catch (_) {
          // ignore
        }
      }
    };

    const onClose = () => {
      cleanup();
      if (pingTimer) {
        window.clearInterval(pingTimer);
        pingTimer = null;
      }
      if (connected) {
        connected = false;
        statusText.textContent = "Disconnected";
        statusText.classList.remove("ready");
        indicator.classList.remove("active");
        connectBtn.classList.remove("hidden");
        connectBtn.disabled = false;
        connecting = false;
        wsUrlInUse = "";
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
  refreshPadRect();
  refreshClientSize();
  const payload = JSON.stringify({
    type: "init",
    width: clientW,
    height: clientH,
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
    moveView.setUint16(0, touchPoint.x, false); // big-endian
    moveView.setUint16(2, touchPoint.y, false);
    ws?.send(moveBuf);
    sendCount += 1;
    updateSendRate();
  });
}

function onTouchStart(e) {
  if (e.target === connectBtn || e.target === exitBtn) return;
  e.preventDefault();
  if (!connected) return;
  refreshPadRect();
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
  // Reset relative tracker on touch end.
  relativeTracker.reset();
}

function updatePoint(e) {
  const touch = e.touches[0];
  if (!touch) return;
  const rect = padRect || padSurface.getBoundingClientRect();

  // Map to local pad coordinates using pure function.
  const local = mapToPadCoordinates(
    touch.clientX - rect.left,
    touch.clientY - rect.top,
    rect.width,
    rect.height,
    padW,
    padH
  );

  let screenPos;
  if (inputMode === InputMode.ABSOLUTE) {
    screenPos = absoluteToScreen(local.x, local.y, padW, padH, clientW, clientH);
  } else {
    screenPos = relativeTracker.update(local.x, local.y, padW, padH, clientW, clientH);
  }

  touchPoint.x = screenPos.x;
  touchPoint.y = screenPos.y;
  scheduleSend();
}

function disconnect() {
  ws?.close();
  ws = undefined;
  connected = false;
  connecting = false;
  wsUrlInUse = "";
  setUiConnected(false);
  if (pingTimer) {
    window.clearInterval(pingTimer);
    pingTimer = null;
  }
}

function startConnectFlow() {
  requestFullscreen()
    .catch(() => {}) // ignore fullscreen failures
    .finally(() => connect());
}

padSurface.addEventListener("touchstart", onTouchStart, { passive: false });
padSurface.addEventListener("touchmove", onTouchMove, { passive: false });
padSurface.addEventListener("touchend", onTouchEnd, { passive: false });
padSurface.addEventListener("touchcancel", onTouchEnd, { passive: false });

padControls?.addEventListener(
  "touchstart",
  (e) => {
    e.stopPropagation();
  },
  { passive: true }
);

padControls?.addEventListener(
  "touchmove",
  (e) => {
    e.stopPropagation();
  },
  { passive: true }
);

function onPadSizeChanged() {
  if (!padSizeInput) return;
  padScalePct = Number(padSizeInput.value);
  applyPadSize();
  if (connected) sendInit();
}

padSizeInput?.addEventListener("input", onPadSizeChanged);
padSizeInput?.addEventListener("change", onPadSizeChanged);

// Input mode toggle handler.
function onModeChanged() {
  if (!modeSelect) return;
  inputMode = modeSelect.value === "relative" ? InputMode.RELATIVE : InputMode.ABSOLUTE;
  // Sync relative tracker position with current touch point.
  relativeTracker.setPosition(touchPoint.x, touchPoint.y);
  relativeTracker.reset();
}
modeSelect?.addEventListener("change", onModeChanged);

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

let resizeTimer = null;
window.addEventListener("resize", () => {
  if (resizeTimer) window.clearTimeout(resizeTimer);
  resizeTimer = window.setTimeout(() => {
    resizeTimer = null;
    applyPadSize();
    // Debounced to avoid resize storms (mobile URL bar / rotation).
    if (connected) sendInit();
  }, 150);
});

document.addEventListener("fullscreenchange", () => {
  applyPadSize();
  if (connected) sendInit();
});

setUiConnected(false);
applyPadSize();
startMetricsLoop();
