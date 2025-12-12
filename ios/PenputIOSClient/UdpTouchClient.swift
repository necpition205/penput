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
    @Published private(set) var remoteScreenSize: CGSize = .zero
    @Published private(set) var viewportSize: CGSize = .zero

    var rttMsText: String {
        guard let rttMs else { return "-" }
        return String(format: "%.0f ms", rttMs)
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

    private var latestX: UInt16 = 0
    private var latestY: UInt16 = 0
    private var touchActive = false
    private var needsSend = false

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
            self.remoteScreenSize = .zero
            self.viewportSize = .zero
        }
    }

    func updateViewport(size: CGSize) {
        let w = UInt16(max(1, min(65535, Int(size.width.rounded()))))
        let h = UInt16(max(1, min(65535, Int(size.height.rounded()))))
        if w == clientW && h == clientH { return }

        clientW = w
        clientH = h
        onMain {
            self.viewportSize = CGSize(width: CGFloat(w), height: CGFloat(h))
        }

        helloPacket[0] = 0x01
        helloPacket[1] = UInt8((w >> 8) & 0xff)
        helloPacket[2] = UInt8(w & 0xff)
        helloPacket[3] = UInt8((h >> 8) & 0xff)
        helloPacket[4] = UInt8(h & 0xff)

        // If we are already connected/awaiting approval, refresh hello.
        if state == .awaitingApproval || state == .connected {
            sendBytes(helloPacket)
        }
    }

    func updateTouch(point: CGPoint, padSize: CGSize) {
        guard clientW > 0, clientH > 0 else { return }

        let padW = max(1.0, padSize.width)
        let padH = max(1.0, padSize.height)

        let relX = max(0.0, min(1.0, Double(point.x / padW)))
        let relY = max(0.0, min(1.0, Double(point.y / padH)))

        let x = UInt16(min(Double(clientW - 1), max(0.0, (relX * Double(clientW)).rounded())))
        let y = UInt16(min(Double(clientH - 1), max(0.0, (relY * Double(clientH)).rounded())))

        latestX = x
        latestY = y
        touchActive = true
        needsSend = true
    }

    func endTouch() {
        touchActive = false
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
                onMain {
                    self.rttMs = Double(now &- t)
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
