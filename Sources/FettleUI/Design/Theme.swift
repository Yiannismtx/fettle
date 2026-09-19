import SwiftUI

/// Design tokens. Every spacing, radius and duration in Fettle comes from here
/// rather than being typed inline, so the app reads as one system.
enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    /// Critically damped by default (no overshoot) — the resting state for UI
    /// that wasn't thrown by a gesture.
    static let standardSpring = Animation.spring(response: 0.34, dampingFraction: 1.0)
    /// Slight bounce, reserved for motion that follows a deliberate commit.
    static let livelySpring = Animation.spring(response: 0.36, dampingFraction: 0.82)
    static let quickFade = Animation.easeOut(duration: 0.18)

    enum Palette {
        static let danger = Color.red
        static let caution = Color.orange
        static let safe = Color.green
        static let accent = Color.accentColor
    }
}

extension View {
    /// Honours Reduce Motion: the animation still happens, it just becomes a
    /// cross-fade instead of a spring.
    func fettleAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReducedMotionAnimation(animation: animation, value: value))
    }
}

private struct ReducedMotionAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? Theme.quickFade : animation, value: value)
    }
}
