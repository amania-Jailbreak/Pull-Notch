import SwiftUI

struct ReactiveWaveform: View {
    var metrics: VisualizerMetrics
    var tint: Color = .white
    var glow: Color = .white.opacity(0.45)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let upperWave = waveformPath(in: size, time: time, mirrored: false)
                let lowerWave = waveformPath(in: size, time: time + 0.38, mirrored: true)

                context.addFilter(.shadow(color: glow.opacity(0.16 + (metrics.attack * 0.22)), radius: 8, x: 0, y: 0))
                context.stroke(
                    upperWave,
                    with: .linearGradient(
                        Gradient(colors: [glow.opacity(0.1), tint.opacity(0.95), glow.opacity(0.12)]),
                        startPoint: .init(x: 0, y: size.height * 0.4),
                        endPoint: .init(x: size.width, y: size.height * 0.6)
                    ),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )

                context.stroke(
                    lowerWave,
                    with: .color(tint.opacity(0.42 + (metrics.smoothedEnergy * 0.22))),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .drawingGroup()
    }

    private func waveformPath(in size: CGSize, time: TimeInterval, mirrored: Bool) -> Path {
        let sampleCount = 32
        let baseLine = size.height * (mirrored ? 0.58 : 0.42)
        let amplitude = max(2, size.height * (0.08 + (metrics.smoothedEnergy * 0.18) + (metrics.attack * 0.08)))
        let bassSwell = 1 + (metrics.bass * 0.65)
        let trebleJitter = 0.35 + (metrics.treble * 1.2)
        let attackBump = metrics.attack * 0.22

        var path = Path()

        for index in 0...sampleCount {
            let x = size.width * CGFloat(index) / CGFloat(sampleCount)
            let progress = CGFloat(index) / CGFloat(sampleCount)
            let asymmetry = mirrored ? 0.82 : 1.0
            let slowWave = sin((time * 2.2) + Double(progress * 6.4)) * Double(amplitude * bassSwell * asymmetry)
            let fastWave = sin((time * 7.6) + Double(progress * 16.0) + Double(metrics.mid * 1.4)) * Double(amplitude * 0.22 * trebleJitter)
            let ripple = cos((time * 3.4) + Double(progress * 11.0)) * Double(amplitude * 0.16 * (0.4 + metrics.treble))
            let centerLift = sin(Double(progress * .pi)) * Double(size.height * attackBump)
            let y = baseLine + CGFloat(slowWave + fastWave + ripple - centerLift)

            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path
    }
}
