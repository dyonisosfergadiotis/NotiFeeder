import SwiftUI

private struct ArticleCardAppearModifier: ViewModifier {
    enum Phase {
        case initial
        case arrival
        case settled
    }

    let delay: Double
    let glowColor: Color
    let trigger: AnyHashable
    let speedFactor: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Phase = .initial
    @State private var didAnimate = false
    @State private var lastTrigger: AnyHashable?

    private var scale: CGFloat {
        switch phase {
        case .initial: return 0.992
        case .arrival: return 1.004
        case .settled: return 1.0
        }
    }

    private var offsetY: CGFloat {
        switch phase {
        case .initial: return 10
        case .arrival, .settled: return 0
        }
    }

    private var blurRadius: CGFloat {
        0
    }

    private var opacity: Double {
        switch phase {
        case .initial: return 0.0
        case .arrival, .settled: return 1.0
        }
    }

    private var glowOpacity: Double {
        switch phase {
        case .initial: return 0.0
        case .arrival: return 0.08
        case .settled: return 0.0
        }
    }

    private var glowRadius: CGFloat {
        switch phase {
        case .initial: return 0
        case .arrival: return 12
        case .settled: return 0
        }
    }

    private var glowYOffset: CGFloat {
        switch phase {
        case .initial: return 0
        case .arrival: return 4
        case .settled: return 0
        }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(y: offsetY)
            .blur(radius: blurRadius)
            .opacity(opacity)
            .shadow(color: glowColor.opacity(glowOpacity),
                    radius: glowRadius,
                    x: 0,
                    y: glowYOffset)
            .onAppear {
                guard !didAnimate else { return }
                lastTrigger = trigger
                runAnimation(reset: false)
            }
            .onChange(of: trigger) { _, newValue in
                guard lastTrigger != newValue else { return }
                lastTrigger = newValue
                didAnimate = false
                runAnimation(reset: true)
            }
    }

    private func runAnimation(reset: Bool) {
        if reduceMotion {
            phase = .settled
            didAnimate = true
            return
        }
        if reset {
            phase = .initial
        }
        didAnimate = true
        let clamped = max(0.2, min(1.0, speedFactor))
        let arrival = Animation.easeOut(duration: 0.16 * clamped).delay(delay)
        let settle = Animation.spring(response: 0.24 * clamped,
                                      dampingFraction: 0.88,
                                      blendDuration: 0.1 * clamped)
        withAnimation(arrival) {
            phase = .arrival
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (0.16 * clamped) + delay) {
            withAnimation(settle) {
                phase = .settled
            }
        }
    }
}

extension View {
    func articleCardAppear(trigger: AnyHashable,
                           delay: Double = 0,
                           glowColor: Color = .white,
                           speedFactor: Double = 1.0) -> some View {
        modifier(ArticleCardAppearModifier(delay: delay,
                                           glowColor: glowColor,
                                           trigger: trigger,
                                           speedFactor: speedFactor))
    }
}
