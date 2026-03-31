import SwiftUI

struct DynamicIslandVisualizer: View {
    var metrics: VisualizerMetrics
    var state: DynamicIslandVisualizerState
    var title: String?
    var subtitle: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let breathing = breathingOffset(at: timeline.date)
            let layout = islandLayout(breathing: breathing)

            ZStack {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.97))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06 + (metrics.attack * 0.08)), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
                    .overlay {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.04 + (metrics.attack * 0.04)),
                                        Color.white.opacity(0.008)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                HStack(spacing: 14) {
                    indicatorCluster

                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                        }

                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.46 + (metrics.smoothedEnergy * 0.24)))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 120, alignment: .leading)
                    .opacity(state == .idle ? 0.82 : 1)

                    ReactiveWaveform(
                        metrics: metrics,
                        tint: .white.opacity(0.95),
                        glow: .white.opacity(0.72)
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: layout.waveHeight)
                    .padding(.trailing, 4)
                }
                .padding(.horizontal, 16)
            }
            .frame(width: layout.width, height: layout.height)
            .scaleEffect(layout.scale)
            .animation(.spring(response: 0.34, dampingFraction: 0.8), value: metrics.smoothedEnergy)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: metrics.attack)
        }
    }

    private var indicatorCluster: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: 6, height: 6)
                .scaleEffect(1 + (metrics.attack * 0.35))

            Circle()
                .fill(Color.white.opacity(0.18 + (metrics.bass * 0.38)))
                .frame(width: 4, height: 4)

            Circle()
                .fill(Color.white.opacity(0.12 + (metrics.treble * 0.28)))
                .frame(width: 3, height: 3)
        }
        .frame(width: 24, alignment: .leading)
    }

    private func islandLayout(breathing: CGFloat) -> (width: CGFloat, height: CGFloat, scale: CGFloat, waveHeight: CGFloat) {
        let widthBase: CGFloat
        let heightBase: CGFloat

        switch state {
        case .expanded:
            widthBase = 270
            heightBase = 64
        case .active:
            widthBase = 216
            heightBase = 46
        case .listening:
            widthBase = 204
            heightBase = 42
        case .idle:
            widthBase = 196
            heightBase = 40
        }

        let width = widthBase + (metrics.bass * 18) + (metrics.attack * 10) + breathing
        let height = heightBase + (metrics.smoothedEnergy * 7) + (metrics.attack * 5) + (breathing * 0.4)
        let scale = 1 + (metrics.smoothedEnergy * 0.016) + (metrics.attack * 0.024)
        let waveHeight = max(14, height - 18)

        return (width, height, scale, waveHeight)
    }

    private func breathingOffset(at date: Date) -> CGFloat {
        let time = date.timeIntervalSinceReferenceDate
        let idleBreathing = (sin(time * 1.15) * 0.5) + 0.5
        return idleBreathing * max(1.4, metrics.idleLevel * 3.2)
    }
}
