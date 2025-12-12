import SwiftUI

// Root UI: connect/disconnect + touchpad + metrics.
struct ContentView: View {
    @StateObject private var client = UdpTouchClient()

    @State private var host: String = ""
    @State private var portText: String = "9002"

    var body: some View {
        ZStack {
            TouchPadView(client: client)
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
            Text("Send: \(String(format: "%.1f", client.sendRate)) /s")
            Text("RTT: \(client.rttMsText)")
        }
        .font(.caption2)
        .padding(10)
        .background(.black.opacity(0.45))
        .foregroundStyle(.white.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
