import Accelerate
import AVFAudio
import Foundation
import Observation

@MainActor
@Observable
final class AudioAnalyzer {
    private let engine = AVAudioEngine()
    private let fftSize = 2_048
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    private let analysisQueue = DispatchQueue(label: "jp.amania.pullnotch.audio-analyzer")

    private(set) var metrics: VisualizerMetrics = .zero
    private(set) var state: DynamicIslandVisualizerState = .idle
    private(set) var isRunning = false

    private var previousEnergy: CGFloat = 0
    private var smoothedBass: CGFloat = 0
    private var smoothedMid: CGFloat = 0
    private var smoothedTreble: CGFloat = 0
    private var smoothedEnergy: CGFloat = 0
    private var smoothedAttack: CGFloat = 0
    private var smoothedIdleLevel: CGFloat = 1

    init() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func start() {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer, format: format)
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        update(metrics: .previewIdle, forceIdle: true)
    }

    private func process(buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        analysisQueue.async { [weak self] in
            guard
                let self,
                let samples = self.monoSamples(from: buffer, channelCount: Int(format.channelCount)),
                !samples.isEmpty
            else {
                return
            }

            let energy = self.normalizedRMS(samples)
            let bands = self.frequencyBands(from: samples, sampleRate: Float(format.sampleRate))
            let delta = max(0, energy - self.previousEnergy)
            self.previousEnergy = energy

            let nextEnergy = self.riseFall(self.smoothedEnergy, energy, rise: 0.38, fall: 0.12)
            let nextBass = self.riseFall(self.smoothedBass, bands.bass, rise: 0.34, fall: 0.14)
            let nextMid = self.riseFall(self.smoothedMid, bands.mid, rise: 0.28, fall: 0.12)
            let nextTreble = self.riseFall(self.smoothedTreble, bands.treble, rise: 0.24, fall: 0.1)
            let nextAttack = self.riseFall(self.smoothedAttack, min(delta * 4, 1), rise: 0.55, fall: 0.18)
            let idleTarget = max(0, 1 - (nextEnergy * 1.5))
            let nextIdle = self.riseFall(self.smoothedIdleLevel, idleTarget, rise: 0.12, fall: 0.32)

            self.smoothedEnergy = nextEnergy
            self.smoothedBass = nextBass
            self.smoothedMid = nextMid
            self.smoothedTreble = nextTreble
            self.smoothedAttack = nextAttack
            self.smoothedIdleLevel = nextIdle

            let metrics = VisualizerMetrics(
                energy: energy,
                bass: nextBass,
                mid: nextMid,
                treble: nextTreble,
                attack: nextAttack,
                smoothedEnergy: nextEnergy,
                idleLevel: nextIdle
            )

            Task { @MainActor [weak self] in
                self?.update(metrics: metrics, forceIdle: false)
            }
        }
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

    private func monoSamples(from buffer: AVAudioPCMBuffer, channelCount: Int) -> [Float]? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

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

    private func normalizedRMS(_ samples: [Float]) -> CGFloat {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return CGFloat(min(1, sqrt(rms) * 3.2))
    }

    private func frequencyBands(from samples: [Float], sampleRate: Float) -> (bass: CGFloat, mid: CGFloat, treble: CGFloat) {
        let frame = Array(samples.prefix(fftSize))
        var padded = frame
        if padded.count < fftSize {
            padded += Array(repeating: 0, count: fftSize - padded.count)
        }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(padded, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)

                windowed.withUnsafeBufferPointer { samplePointer in
                    samplePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }

                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        var scale = Float(1.0 / Float(fftSize))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(magnitudes.count))

        return (
            bass: normalizedBandEnergy(magnitudes, sampleRate: sampleRate, range: 32...180),
            mid: normalizedBandEnergy(magnitudes, sampleRate: sampleRate, range: 180...2_000),
            treble: normalizedBandEnergy(magnitudes, sampleRate: sampleRate, range: 2_000...8_000)
        )
    }

    private func normalizedBandEnergy(_ magnitudes: [Float], sampleRate: Float, range: ClosedRange<Float>) -> CGFloat {
        let selected = magnitudes.enumerated().compactMap { index, magnitude -> Float? in
            let frequency = Float(index) * sampleRate / Float(fftSize)
            guard range.contains(frequency) else { return nil }
            return magnitude
        }

        let peak = selected.max() ?? 0
        let normalized = log10f(1 + (peak * 24)) / 1.8
        return CGFloat(min(1, max(0, normalized)))
    }

    private func riseFall(_ current: CGFloat, _ target: CGFloat, rise: CGFloat, fall: CGFloat) -> CGFloat {
        let blend = target > current ? rise : fall
        return current + ((target - current) * blend)
    }
}
