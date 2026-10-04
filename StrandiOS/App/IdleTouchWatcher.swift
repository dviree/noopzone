#if os(iOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import StrandDesign

/// Reports every touch on the app's window to `NoopMotionState`, which poses NOOP's decorative motion
/// still after `idleSeconds` without one. That is what lets a ProMotion display follow its adaptive
/// refresh rate: the per-frame loops (the sky, the liquid tubes, the pulsing dots) otherwise hold the
/// panel at their own rate for as long as a screen is open, touched or not.
///
/// The recognizer only observes. It never recognizes, never cancels or delays a touch, and runs beside
/// every other recognizer, so buttons, scrolling and swipes behave exactly as without it.
struct IdleTouchWatcher: UIViewRepresentable {
    /// Seconds without a touch before the decorative motion poses still. Long enough that reading a card
    /// does not freeze it mid-glance, short enough that a phone left on a table stops drawing quickly.
    static let idleSeconds: TimeInterval = 10

    func makeUIView(context: Context) -> WatcherView { WatcherView() }
    func updateUIView(_ uiView: WatcherView, context: Context) {}

    final class WatcherView: UIView {
        private let recognizer = PassiveTouchRecognizer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            guard let window else { return }
            window.addGestureRecognizer(recognizer)
            NoopMotionState.shared.enableIdleTracking(after: IdleTouchWatcher.idleSeconds)
        }
    }
}

/// A gesture recognizer that never recognizes: it notes each touch's start and end, and fails when the
/// finger lifts, so it takes nothing from the touches the app's own controls receive. It waits in the
/// `.possible` state while the finger is down; with `cancelsTouchesInView` off and simultaneous
/// recognition allowed, that blocks no other recognizer.
private final class PassiveTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        NoopMotionState.shared.noteInteraction()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        // The idle clock restarts when the finger lifts too, so a long scroll is timed from its end.
        NoopMotionState.shared.noteInteraction()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        NoopMotionState.shared.noteInteraction()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
