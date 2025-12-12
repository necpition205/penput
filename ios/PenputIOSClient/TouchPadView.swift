import SwiftUI
import UIKit

// Fullscreen touch surface. Uses UIKit touch callbacks for lowest overhead.
struct TouchPadView: View {
    @ObservedObject var client: UdpTouchClient
    let padScalePct: Double

    // Match the web client's pad sizing: scale by min side and preserve remote aspect ratio.
    private func computePadSize(containerSize: CGSize) -> CGSize {
        let pct = CGFloat(max(10.0, min(100.0, padScalePct)))
        let base = max(1.0, min(containerSize.width, containerSize.height))
        let maxSide = max(1.0, (base * (pct / 100.0)).rounded())

        let remote = client.remoteScreenSize
        let rawAspect = remote.width > 0.0 && remote.height > 0.0 ? (remote.width / remote.height) : 1.0
        let aspect = min(1_000_000.0, max(0.000_001, rawAspect))

        var w = maxSide
        var h = maxSide
        if aspect >= 1.0 {
            w = maxSide
            h = max(1.0, (maxSide / aspect).rounded())
        } else {
            h = maxSide
            w = max(1.0, (maxSide * aspect).rounded())
        }

        return CGSize(width: w, height: h)
    }

    var body: some View {
        TouchPadRepresentable(
            onTouch: { point, size in
                let padSize = computePadSize(containerSize: size)

                let offsetX = max(0.0, (size.width - padSize.width) * 0.5)
                let offsetY = max(0.0, (size.height - padSize.height) * 0.5)

                let localX = min(padSize.width, max(0.0, point.x - offsetX))
                let localY = min(padSize.height, max(0.0, point.y - offsetY))

                client.updateTouch(
                    point: CGPoint(x: localX, y: localY),
                    padSize: padSize
                )
            },
            onEnd: {
                client.endTouch()
            },
            onLayout: { size in
                let padSize = computePadSize(containerSize: size)
                client.updateViewport(size: padSize)
            }
        )
        .background(Color.clear)
    }
}

private struct TouchPadRepresentable: UIViewRepresentable {
    let onTouch: (CGPoint, CGSize) -> Void
    let onEnd: () -> Void
    let onLayout: (CGSize) -> Void

    func makeUIView(context: Context) -> TouchPadUIView {
        let view = TouchPadUIView()
        view.onTouch = onTouch
        view.onEnd = onEnd
        view.onLayout = onLayout
        return view
    }

    func updateUIView(_ uiView: TouchPadUIView, context: Context) {
        uiView.onTouch = onTouch
        uiView.onEnd = onEnd
        uiView.onLayout = onLayout
        onLayout(uiView.bounds.size)
    }
}

private final class TouchPadUIView: UIView {
    var onTouch: ((CGPoint, CGSize) -> Void)?
    var onEnd: (() -> Void)?
    var onLayout: ((CGSize) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        handleTouches(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        handleTouches(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onEnd?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onEnd?()
    }

    private func handleTouches(_ touches: Set<UITouch>) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        onTouch?(point, bounds.size)
    }
}
