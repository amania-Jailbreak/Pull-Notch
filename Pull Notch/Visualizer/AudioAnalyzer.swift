@preconcurrency import AVFAudio
import Foundation
import Observation

nonisolated private enum AudioSampleExtractor {
    static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return nil }

        if let channels = buffer.floatChannelData {
            return (0..<frameLength).map { frameIndex in
                let sum = (0..<channelCount).reduce(Float(0)) { partial, channel in
                    partial + channels[channel][frameIndex]
                }
                return sum / Float(channelCount)
            }
        }

        if let channels = buffer.int16ChannelData {
            let normalizer = Float(Int16.max)
            return (0..<frameLength).map { frameIndex in
                let sum = (0..<channelCount).reduce(Float(0)) { partial, channel in
                    partial + (Float(channels[channel][frameIndex]) / normalizer)
                }
                return sum / Float(channelCount)
            }
        }

        return nil
    }
}

@MainActor
@Observable
final class AudioAnalyzer {
    private let engine = AVAudioEngine()
    private let fftSize = 2_048
    private let processor = AudioMetricsProcessor()

    private(set) var metrics: VisualizerMetrics = .zero
    private(set) var state: DynamicIslandVisualizerState = .idle
    private(set) var isRunning = false

    private var analysisGeneration = 0

    deinit {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func start() {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }

        analysisGeneration += 1
        let generation = analysisGeneration

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: format) { [weak self, processor] buffer, _ in
            guard let samples = AudioSampleExtractor.monoSamples(from: buffer) else { return }
            let sampleRate = Float(buffer.format.sampleRate)
            processor.submit(samples: samples, sampleRate: sampleRate) { [weak self] metrics in
                guard let self, self.isRunning, self.analysisGeneration == generation else { return }
                self.update(metrics: metrics, forceIdle: false)
            }
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        analysisGeneration += 1
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        processor.reset()
        update(metrics: .previewIdle, forceIdle: true)
    }

    private func update(metrics: VisualizerMetrics, forceIdle: Bool) {
        self.metrics = metrics

        if forceIdle {
            state = .idle
            return
        }

        switch metrics.smoothedEnergy {
        case ..<0.05:
            state = .idle
        case ..<0.18:
            state = .listening
        default:
            state = .active
        }
    }
}
