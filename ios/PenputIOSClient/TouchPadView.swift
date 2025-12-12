import SwiftUI

// Fullscreen touch surface. Uses UIKit touch callbacks for lowest overhead.
struct TouchPadView: View {
    @ObservedObject var client: UdpTouchClient

    var body: some View {
        TouchPadRepresentable(
            onTouch: { point, size in
                client.updateTouch(point: point, in: size)
            },
            onEnd: {
                client.endTouch()
            },
            onLayout: { size in
                client.updateViewport(size: size)
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
        // Keep layout callback updated.
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
