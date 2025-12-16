import Combine
import Foundation
import Network
import UIKit

// UDP client for Penput iOS native mode.
//
// Packet format (big-endian):
// - HELLO: [0x01][w:u16][h:u16]
// - MOVE:  [0x02][x:u16][y:u16]
// - PING:  [0x03][t:u64]
// - ACCEPT: [0x10][remote_w:u16][remote_h:u16] (optional)
// - REJECT: [0x11]
// - BUSY:   [0x12]
// - PONG:  [0x13][t:u64]
// Input mode: absolute (touch position maps to screen position) or relative (delta movement like a trackpad).
enum InputMode: String, CaseIterable {
    case absolute
    case relative
}

final class UdpTouchClient: NSObject, ObservableObject {
    enum State: String {
        case disconnected
        case connecting
        case awaitingApproval
        case connected
        case rejected
        case busy
        case failed
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var endpoint: String = ""
    @Published private(set) var sendRate: Double = 0
    @Published private(set) var rttMs: Double? = nil
    @Published private(set) var statusText: String = "Disconnected"
    @Published private(set) var pingIntervalMs: Double? = nil
    @Published private(set) var pongIntervalMs: Double? = nil
    @Published private(set) var remoteScreenSize: CGSize = .zero
    @Published private(set) var viewportSize: CGSize = .zero

    // Current input mode (absolute vs relative).
    @Published var inputMode: InputMode = .absolute

    var rttMsText: String {
        guard let rttMs else { return "-" }
        return String(format: "%.0f ms", rttMs)
    }

    var pingIntervalMsText: String {
        guard let pingIntervalMs else { return "-" }
        return String(format: "%.0f ms", pingIntervalMs)
    }

    var pongIntervalMsText: String {
        guard let pongIntervalMs else { return "-" }
        return String(format: "%.0f ms", pongIntervalMs)
    }

    private let queue = DispatchQueue(label: "penput.udp.client")
    private var connection: NWConnection?

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async {
                body()
            }
        }
    }

    private var helloTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var displayLink: CADisplayLink?

    private var clientW: UInt16 = 0
    private var clientH: UInt16 = 0

    private var lastPingSentMs: UInt64 = 0
    private var lastPongReceivedMs: UInt64 = 0

    private var latestX: UInt16 = 0
    private var latestY: UInt16 = 0
    private var touchActive = false
    private var needsSend = false

    // For relative mode: track last touch point to compute delta.
    private var lastTouchPoint: CGPoint? = nil
    // Accumulated sub-pixel delta for relative mode.
    private var accumulatedDeltaX: Double = 0.0
    private var accumulatedDeltaY: Double = 0.0
    // Sensitivity multiplier for relative mode.
    private let relativeSensitivity: Double = 1.5

    private var sendCount: Int = 0
    private var sendWindowStartMs: Double = CACurrentMediaTime() * 1000

    // Reusable packet buffers to reduce allocations.
    private var helloPacket = [UInt8](repeating: 0, count: 5)
    private var movePacket = [UInt8](repeating: 0, count: 5)
    private var pingPacket = [UInt8](repeating: 0, count: 9)

    private func cancelConnection() {
        stopTimers()
        if let conn = connection {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        connection = nil
    }

    func connect(host: String, port: UInt16) {
        disconnect()

        guard !host.isEmpty else {
            statusText = "Enter PC IP"
            return
        }

        endpoint = "\(host):\(port)"
        statusText = "Connecting..."
        state = .connecting

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed
            statusText = "Invalid UDP port"
            return
        }
        let conn = NWConnection(host: nwHost, port: nwPort, using: .udp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.onMain {
                    self.state = .awaitingApproval
                    self.statusText = "Awaiting approval..."
                }
                self.startReceiveLoop()
                self.startHelloLoop()

            case .failed(let err):
                self.onMain {
                    self.state = .failed
                    self.statusText = "Failed: \(err)"
                }
                self.disconnect()

            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    func disconnect() {
        cancelConnection()
        onMain {
            self.state = .disconnected
            self.statusText = "Disconnected"
            self.endpoint = self.endpoint
            self.rttMs = nil
            self.pingIntervalMs = nil
            self.pongIntervalMs = nil
            self.remoteScreenSize = .zero
            self.viewportSize = .zero
        }
        queue.async {
            self.lastPingSentMs = 0
            self.lastPongReceivedMs = 0
        }
    }

    func updateViewport(size: CGSize) {
        queue.async { [weak self] in
            guard let self else { return }
            let w = UInt16(max(1, min(65535, Int(size.width.rounded()))))
            let h = UInt16(max(1, min(65535, Int(size.height.rounded()))))
            if w == self.clientW && h == self.clientH { return }

            self.clientW = w
            self.clientH = h
            self.onMain {
                self.viewportSize = CGSize(width: CGFloat(w), height: CGFloat(h))
            }

            self.helloPacket[0] = 0x01
            self.helloPacket[1] = UInt8((w >> 8) & 0xff)
            self.helloPacket[2] = UInt8(w & 0xff)
            self.helloPacket[3] = UInt8((h >> 8) & 0xff)
            self.helloPacket[4] = UInt8(h & 0xff)

            // If we are already connected/awaiting approval, refresh hello.
            if self.state == .awaitingApproval || self.state == .connected {
                self.sendBytes(self.helloPacket)
            }
        }
    }

    func updateTouch(point: CGPoint, padSize: CGSize) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.clientW > 0, self.clientH > 0 else { return }

            let padW = max(1.0, padSize.width)
            let padH = max(1.0, padSize.height)

            // Branch based on input mode.
            if self.inputMode == .absolute {
                // Absolute mode: map touch position to screen position.
                let relX = max(0.0, min(1.0, Double(point.x / padW)))
                let relY = max(0.0, min(1.0, Double(point.y / padH)))

                let x = UInt16(min(Double(self.clientW - 1), max(0.0, (relX * Double(self.clientW)).rounded())))
                let y = UInt16(min(Double(self.clientH - 1), max(0.0, (relY * Double(self.clientH)).rounded())))

                self.latestX = x
                self.latestY = y
                self.lastTouchPoint = point
            } else {
                // Relative mode: compute delta from last touch point.
                if let last = self.lastTouchPoint {
                    let dx = Double(point.x - last.x) * self.relativeSensitivity
                    let dy = Double(point.y - last.y) * self.relativeSensitivity

                    // Accumulate sub-pixel movement.
                    self.accumulatedDeltaX += dx * Double(self.clientW) / padW
                    self.accumulatedDeltaY += dy * Double(self.clientH) / padH

                    // Extract integer part.
                    let intDx = Int(self.accumulatedDeltaX)
                    let intDy = Int(self.accumulatedDeltaY)
                    self.accumulatedDeltaX -= Double(intDx)
                    self.accumulatedDeltaY -= Double(intDy)

                    // Apply delta to current position.
                    var newX = Int(self.latestX) + intDx
                    var newY = Int(self.latestY) + intDy
                    newX = max(0, min(Int(self.clientW - 1), newX))
                    newY = max(0, min(Int(self.clientH - 1), newY))

                    self.latestX = UInt16(newX)
                    self.latestY = UInt16(newY)
                }
                self.lastTouchPoint = point
            }

            self.touchActive = true
            self.needsSend = true
        }
    }

    func endTouch() {
        queue.async { [weak self] in
            guard let self else { return }
            self.touchActive = false
            self.lastTouchPoint = nil
            self.accumulatedDeltaX = 0.0
            self.accumulatedDeltaY = 0.0
        }
    }

    private func startHelloLoop() {
        helloTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(400))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.state == .awaitingApproval else { return }
            if self.clientW == 0 || self.clientH == 0 {
                // Fallback if we never received a layout.
                self.updateViewport(size: UIScreen.main.bounds.size)
            }
            self.sendBytes(self.helloPacket)
        }
        helloTimer = timer
        timer.activate()
    }

    private func startPingLoop() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.state == .connected else { return }
            self.sendPing()
        }
        pingTimer = timer
        timer.activate()
    }

    private func startDisplayLink() {
        DispatchQueue.main.async {
            if self.displayLink != nil { return }
            let link = CADisplayLink(target: self, selector: #selector(self.onFrame))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
    }

    private func stopTimers() {
        helloTimer?.cancel()
        helloTimer = nil

        pingTimer?.cancel()
        pingTimer = nil

        DispatchQueue.main.async {
            self.displayLink?.invalidate()
            self.displayLink = nil
        }
    }

    @objc private func onFrame() {
        queue.async { [weak self] in
            self?.sendMoveIfNeeded()
        }
    }

    private func sendMoveIfNeeded() {
        guard state == .connected else { return }
        guard touchActive, needsSend else { return }
        needsSend = false

        movePacket[0] = 0x02
        movePacket[1] = UInt8((latestX >> 8) & 0xff)
        movePacket[2] = UInt8(latestX & 0xff)
        movePacket[3] = UInt8((latestY >> 8) & 0xff)
        movePacket[4] = UInt8(latestY & 0xff)

        sendBytes(movePacket)
        updateSendRateOnSend()
    }

    private func sendPing() {
        let tMs = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        let deltaMs: Double? = lastPingSentMs == 0 ? nil : Double(tMs &- lastPingSentMs)
        lastPingSentMs = tMs
        if let deltaMs {
            onMain {
                self.pingIntervalMs = deltaMs
            }
        }
        pingPacket[0] = 0x03
        for i in 0..<8 {
            let shift = UInt64(56 - (i * 8))
            pingPacket[1 + i] = UInt8((tMs >> shift) & 0xff)
        }
        sendBytes(pingPacket)
    }

    private func sendBytes(_ bytes: [UInt8]) {
        guard let connection else { return }
        let data = Data(bytes)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func startReceiveLoop() {
        guard let connection else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                self.handleIncoming(data)
            }
            if error == nil {
                self.startReceiveLoop()
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        guard let first = data.first else { return }

        switch first {
        case 0x10:
            // ACCEPT
            let remoteW = data.count >= 5 ? readU16BE(data: data, offset: 1) : 0
            let remoteH = data.count >= 5 ? readU16BE(data: data, offset: 3) : 0
            onMain {
                if remoteW > 0 && remoteH > 0 {
                    self.remoteScreenSize = CGSize(width: CGFloat(remoteW), height: CGFloat(remoteH))
                }
                self.state = .connected
                self.statusText = "Connected"
            }
            helloTimer?.cancel()
            helloTimer = nil
            startPingLoop()
            startDisplayLink()

        case 0x11:
            // REJECT
            cancelConnection()
            onMain {
                self.state = .rejected
                self.statusText = "Rejected"
            }

        case 0x12:
            // BUSY
            cancelConnection()
            onMain {
                self.state = .busy
                self.statusText = "Busy (another client connected)"
            }

        case 0x13:
            // PONG
            if data.count >= 9 {
                let t = readU64BE(data: data, offset: 1)
                let now = UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
                let deltaMs: Double? = lastPongReceivedMs == 0 ? nil : Double(now &- lastPongReceivedMs)
                lastPongReceivedMs = now
                onMain {
                    self.rttMs = Double(now &- t)
                    if let deltaMs {
                        self.pongIntervalMs = deltaMs
                    }
                }
            }

        default:
            break
        }
    }

    private func readU64BE(data: Data, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }

    private func readU16BE(data: Data, offset: Int) -> UInt16 {
        if data.count < offset + 2 { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private func updateSendRateOnSend() {
        let nowMs = CACurrentMediaTime() * 1000
        sendCount += 1

        let elapsed = max(1.0, nowMs - sendWindowStartMs)
        if elapsed >= 1000 {
            let rate = (Double(sendCount) * 1000.0) / elapsed
            onMain {
                self.sendRate = rate
            }
            sendCount = 0
            sendWindowStartMs = nowMs
        }
    }
}
