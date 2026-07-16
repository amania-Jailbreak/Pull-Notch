import Accelerate
import Foundation

/// Owns all mutable DSP state on a dedicated serial queue.
nonisolated final class AudioMetricsProcessor: @unchecked Sendable {
    private let fftSize = 2_048
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    private let queue = DispatchQueue(label: "jp.amania.pullnotch.audio-analyzer")

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
        window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: fftSize,
            isHalfWindow: false
        )
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func submit(
        samples: [Float],
        sampleRate: Float,
        onMetrics: @escaping @MainActor @Sendable (VisualizerMetrics) -> Void
    ) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            let metrics = analyze(samples: samples, sampleRate: sampleRate)
            Task { @MainActor in
                onMetrics(metrics)
            }
        }
    }

    func reset() {
        queue.async { [self] in
            previousEnergy = 0
            smoothedBass = 0
            smoothedMid = 0
            smoothedTreble = 0
            smoothedEnergy = 0
            smoothedAttack = 0
            smoothedIdleLevel = 1
        }
    }

    private func analyze(samples: [Float], sampleRate: Float) -> VisualizerMetrics {
        let energy = normalizedRMS(samples)
        let bands = frequencyBands(from: samples, sampleRate: sampleRate)
        let delta = max(0, energy - previousEnergy)
        previousEnergy = energy

        smoothedEnergy = riseFall(smoothedEnergy, energy, rise: 0.38, fall: 0.12)
        smoothedBass = riseFall(smoothedBass, bands.bass, rise: 0.34, fall: 0.14)
        smoothedMid = riseFall(smoothedMid, bands.mid, rise: 0.28, fall: 0.12)
        smoothedTreble = riseFall(smoothedTreble, bands.treble, rise: 0.24, fall: 0.1)
        smoothedAttack = riseFall(smoothedAttack, min(delta * 4, 1), rise: 0.55, fall: 0.18)
        let idleTarget = max(0, 1 - (smoothedEnergy * 1.5))
        smoothedIdleLevel = riseFall(smoothedIdleLevel, idleTarget, rise: 0.12, fall: 0.32)

        return VisualizerMetrics(
            energy: energy,
            bass: smoothedBass,
            mid: smoothedMid,
            treble: smoothedTreble,
            attack: smoothedAttack,
            smoothedEnergy: smoothedEnergy,
            idleLevel: smoothedIdleLevel
        )
    }

    private func normalizedRMS(_ samples: [Float]) -> CGFloat {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return CGFloat(min(1, sqrt(rms) * 3.2))
    }

    private func frequencyBands(
        from samples: [Float],
        sampleRate: Float
    ) -> (bass: CGFloat, mid: CGFloat, treble: CGFloat) {
        var padded = Array(samples.prefix(fftSize))
        if padded.count < fftSize {
            padded += Array(repeating: 0, count: fftSize - padded.count)
        }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(padded, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )

                windowed.withUnsafeBufferPointer { samplePointer in
                    samplePointer.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: fftSize / 2
                    ) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }

                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )
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

    private func normalizedBandEnergy(
        _ magnitudes: [Float],
        sampleRate: Float,
        range: ClosedRange<Float>
    ) -> CGFloat {
        let selected = magnitudes.enumerated().compactMap { index, magnitude -> Float? in
            let frequency = Float(index) * sampleRate / Float(fftSize)
            return range.contains(frequency) ? magnitude : nil
        }

        let peak = selected.max() ?? 0
        let normalized = log10f(1 + (peak * 24)) / 1.8
        return CGFloat(min(1, max(0, normalized)))
    }

    private func riseFall(
        _ current: CGFloat,
        _ target: CGFloat,
        rise: CGFloat,
        fall: CGFloat
    ) -> CGFloat {
        let blend = target > current ? rise : fall
        return current + ((target - current) * blend)
    }
}
