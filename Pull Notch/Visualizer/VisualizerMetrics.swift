import CoreGraphics
import Foundation

enum DynamicIslandVisualizerState: String, Sendable {
    case idle
    case listening
    case active
    case expanded
}

struct VisualizerMetrics: Equatable, Sendable {
    var energy: CGFloat
    var bass: CGFloat
    var mid: CGFloat
    var treble: CGFloat
    var attack: CGFloat
    var smoothedEnergy: CGFloat
    var idleLevel: CGFloat

    static let zero = VisualizerMetrics(
        energy: 0,
        bass: 0,
        mid: 0,
        treble: 0,
        attack: 0,
        smoothedEnergy: 0,
        idleLevel: 1
    )

    static let previewIdle = VisualizerMetrics(
        energy: 0.06,
        bass: 0.08,
        mid: 0.04,
        treble: 0.02,
        attack: 0.02,
        smoothedEnergy: 0.08,
        idleLevel: 0.92
    )

    static let previewActive = VisualizerMetrics(
        energy: 0.62,
        bass: 0.74,
        mid: 0.48,
        treble: 0.31,
        attack: 0.42,
        smoothedEnergy: 0.66,
        idleLevel: 0.18
    )
}
