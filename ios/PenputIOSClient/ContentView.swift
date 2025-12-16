import SwiftUI

// Root UI: connect/disconnect + touchpad + metrics.
struct ContentView: View {
    @StateObject private var client = UdpTouchClient()

    @State private var host: String = ""
    @State private var portText: String = "9002"
    @State private var padScalePct: Double = 100
    @AppStorage("stylusOnly") private var stylusOnly: Bool = false

    var body: some View {
        ZStack {
            TouchPadView(client: client, padScalePct: padScalePct, stylusOnly: stylusOnly)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField("PC IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)

                    TextField("UDP", text: $portText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    if client.state == .connected || client.state == .awaitingApproval || client.state == .connecting {
                        Button("Disconnect") {
                            client.disconnect()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Connect") {
                            let port = UInt16(portText) ?? 9002
                            client.connect(host: host, port: port)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                HStack(spacing: 10) {
                    Text("Pad")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $padScalePct, in: 30...100, step: 5)
                    Text("\(Int(padScalePct))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                Toggle("Stylus only", isOn: $stylusOnly)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Mode", selection: $client.inputMode) {
                    ForEach(InputMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                MetricsView(client: client)

                Spacer()

                Text(client.statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .onAppear {
            // Pre-fill host with last used value if needed.
        }
    }
}

private struct MetricsView: View {
    @ObservedObject var client: UdpTouchClient

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("State: \(client.state.rawValue)")
            Text("Endpoint: \(client.endpoint)")
            Text("Remote: \(Int(client.remoteScreenSize.width))x\(Int(client.remoteScreenSize.height))")
            Text("Viewport: \(Int(client.viewportSize.width))x\(Int(client.viewportSize.height))")
            Text("Send: \(String(format: "%.1f", client.sendRate)) /s")
            Text("RTT: \(client.rttMsText)")
            Text("Ping Δ: \(client.pingIntervalMsText)")
            Text("Pong Δ: \(client.pongIntervalMsText)")
        }
        .font(.caption2)
        .padding(10)
        .background(.black.opacity(0.45))
        .foregroundStyle(.white.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
