import Accelerate
import AVFAudio
import CoreAudio
import CoreGraphics
import CoreLocation
import CoreMedia
import Foundation
import IOKit.ps
import Observation
import ScreenCaptureKit

@MainActor
final class AppleMusicNowPlayingMonitor {
    private var pollingTask: Task<Void, Never>?
    private let mediaRemote = MediaRemoteAdapterBridge()

    func start(using overlayModel: NotchOverlayModel) {
        pollingTask?.cancel()

        pollingTask = Task {
            while !Task.isCancelled {
                await updateOverlay(using: overlayModel)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func send(_ command: MediaControlCommand) {
        mediaRemote.send(command)
    }

    private func updateOverlay(using overlayModel: NotchOverlayModel) async {
        let result = await currentTrackInfo()

        switch result {
        case .success(let track):
            overlayModel.updateNowPlaying(track: track)
        case .notPlaying:
            overlayModel.clearNowPlaying()
        case .failure:
            overlayModel.clearNowPlaying()
        }
    }

    private func currentTrackInfo() async -> AppleMusicPollResult {
        guard let rawPayload = await mediaRemote.currentPayload() else {
            return .failure
        }

        guard let payload = try? JSONDecoder().decode(MediaRemotePayload.self, from: Data(rawPayload.utf8)) else {
            return .failure
        }

        if payload.title == nil {
            return .notPlaying
        }

        guard let title = payload.title else {
            return .failure
        }

        let isPlaying = payload.playing ?? ((payload.playbackRate ?? 0) > 0)
        let artist = payload.artist?.isEmpty == false
            ? payload.artist ?? ""
            : statusTitle(for: isPlaying)
        let artworkData = payload.artworkData.flatMap { Data(base64Encoded: $0) }
        let durationSeconds = payload.durationMicros.map { $0 / 1_000_000 } ?? payload.duration
        let playbackPositionSeconds =
            payload.elapsedTimeNowMicros.map { $0 / 1_000_000 }
            ?? payload.elapsedTimeNow
            ?? payload.elapsedTimeMicros.map { $0 / 1_000_000 }
            ?? payload.elapsedTime

        return .success(
            .init(
                title: title,
                album: payload.album ?? "",
                artist: artist,
                isPlaying: isPlaying,
                bundleIdentifier: payload.bundleIdentifier ?? "unknown",
                artworkData: artworkData,
                durationSeconds: durationSeconds,
                playbackPositionSeconds: playbackPositionSeconds
            )
        )
    }

    private func statusTitle(for isPlaying: Bool) -> String {
        switch isPlaying {
        case true:
            return "Playing"
        case false:
            return "Paused"
        }
    }
}

private enum AppleMusicPollResult {
    case success(AppleMusicTrack)
    case notPlaying
    case failure
}

final class ScreenAudioVisualizerMonitor: NSObject, SCStreamOutput {
    private static let visualizerBandRanges: [ClosedRange<Float>] = {
        [
            40...120,
            120...280,
            280...640,
            640...900,
            900...4_800,
            4_800...6_000
        ]
    }()
    private static let fftSize = 2048
    private static let fftLog2n = vDSP_Length(log2(Float(fftSize)))
    private weak var overlayModel: NotchOverlayModel?
    private let sampleHandlerQueue = DispatchQueue(label: "jp.amania.Pull-Notch.visualizer-audio")
    private let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2))
    private lazy var fftWindow: [Float] = {
        var window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        return window
    }()
    private var stream: SCStream?
    private var mode: NowPlayingVisualizerMode = .fake

    func start(using overlayModel: NotchOverlayModel) {
        self.overlayModel = overlayModel
        setMode(overlayModel.nowPlayingVisualizerMode, using: overlayModel)
    }

    func setMode(_ mode: NowPlayingVisualizerMode, using overlayModel: NotchOverlayModel?) {
        self.mode = mode
        if let overlayModel {
            self.overlayModel = overlayModel
        }

        Task {
            if mode == .real {
                await restartCapture()
            } else {
                await stopCapture()
            }
        }
    }

    private func restartCapture() async {
        await stopCapture()

        guard mode == .real else { return }
        guard await requestScreenCaptureAccessIfNeeded() else {
            await MainActor.run {
                overlayModel?.updateLiveVisualizerLevels(Self.restingLevels, isAvailable: false)
            }
            return
        }

        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = shareableContent.displays.first else {
                await MainActor.run {
                    overlayModel?.updateLiveVisualizerLevels(Self.restingLevels, isAvailable: false)
                }
                return
            }

            let excludedApplications = shareableContent.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.captureMicrophone = false
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 2
            configuration.width = 2
            configuration.height = 2
            configuration.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
            try await stream.startCapture()
            self.stream = stream

            await MainActor.run {
                overlayModel?.updateLiveVisualizerLevels(Self.restingLevels, isAvailable: true)
            }
        } catch {
            await MainActor.run {
                overlayModel?.updateLiveVisualizerLevels(Self.restingLevels, isAvailable: false)
            }
        }
    }

    private func stopCapture() async {
        let currentStream = stream
        stream = nil

        if let currentStream {
            try? await currentStream.stopCapture()
        }

        await MainActor.run {
            overlayModel?.updateLiveVisualizerLevels(Self.restingLevels, isAvailable: false)
        }
    }

    private func requestScreenCaptureAccessIfNeeded() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        return await MainActor.run {
            CGRequestScreenCaptureAccess()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid else { return }
        handleAudioSampleBuffer(sampleBuffer)
    }

    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let streamDescription = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }

        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            let levels = self.levels(
                from: audioBufferList.unsafePointer,
                streamDescription: streamDescription
            )

            Task { @MainActor [weak self] in
                self?.overlayModel?.updateLiveVisualizerLevels(levels, isAvailable: true)
            }
        }
    }

    private func levels(
        from audioBufferList: UnsafePointer<AudioBufferList>,
        streamDescription: AudioStreamBasicDescription
    ) -> [CGFloat] {
        guard
            let monoSamples = monoSamples(from: audioBufferList, streamDescription: streamDescription),
            let fftSetup
        else {
            return Self.restingLevels
        }

        let bandCount = Self.visualizerBandRanges.count
        let bucketWeights: [CGFloat] = [0.62, 0.76, 1.8, 2.08, 2.04, 3.50]
        let timePhase = CGFloat(Date().timeIntervalSinceReferenceDate)
        let frequencyBandPeaks = fftBandPeaks(
            from: monoSamples,
            sampleRate: Float(streamDescription.mSampleRate),
            setup: fftSetup
        )
        let weightedEnergies = (0..<bandCount).map { index in
            min(1, frequencyBandPeaks[index] * bucketWeights[index])
        }

        return (0..<bandCount).map { index in
            let peak = frequencyBandPeaks[index]
            let weighted = weightedEnergies[index]
            let target = pow(min(1, weighted), 1.3)
            let flutter = max(0, sin((timePhase * 10.5) + CGFloat(index) * 0.92)) * target * 0.05
            let dynamicLift = peak > 0.82 ? min(0.05, (peak - 0.82) * 0.16) : 0
            return 5 + (min(1, target + flutter + dynamicLift) * 10.5)
        }
    }

    private func monoSamples(
        from audioBufferList: UnsafePointer<AudioBufferList>,
        streamDescription: AudioStreamBasicDescription
    ) -> [Float]? {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer<AudioBufferList>(mutating: audioBufferList)
        )
        let usesFloat = (streamDescription.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bytesPerSample = max(Int(streamDescription.mBitsPerChannel / 8), 1)

        if buffers.count > 1 {
            let perBufferSamples: [[Float]] = buffers.compactMap { audioBuffer in
                guard let mData = audioBuffer.mData else { return nil }

                if usesFloat && bytesPerSample == MemoryLayout<Float>.size {
                    let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = UnsafeRawPointer(mData).bindMemory(to: Float.self, capacity: sampleCount)
                    return Array(UnsafeBufferPointer(start: samples, count: sampleCount))
                }

                if bytesPerSample == MemoryLayout<Int16>.size {
                    let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                    let normalizer = Float(Int16.max)
                    let samples = UnsafeRawPointer(mData).bindMemory(to: Int16.self, capacity: sampleCount)
                    return (0..<sampleCount).map { Float(samples[$0]) / normalizer }
                }

                return nil
            }

            guard let frameCount = perBufferSamples.map(\.count).min(), frameCount > 0 else {
                return nil
            }

            return (0..<frameCount).map { frameIndex in
                let sum = perBufferSamples.reduce(Float(0)) { partial, channelSamples in
                    partial + channelSamples[frameIndex]
                }
                return sum / Float(perBufferSamples.count)
            }
        }

        guard let firstBuffer = buffers.first, let mData = firstBuffer.mData else {
            return nil
        }

        let channelCount = max(Int(streamDescription.mChannelsPerFrame), 1)

        if usesFloat && bytesPerSample == MemoryLayout<Float>.size {
            let sampleCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let frameCount = sampleCount / channelCount
            let samples = UnsafeRawPointer(mData).bindMemory(to: Float.self, capacity: sampleCount)
            return (0..<frameCount).map { frameIndex in
                let channelOffset = frameIndex * channelCount
                let sum = (0..<channelCount).reduce(Float(0)) { partial, channel in
                    partial + samples[channelOffset + channel]
                }
                return sum / Float(channelCount)
            }
        }

        if bytesPerSample == MemoryLayout<Int16>.size {
            let sampleCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Int16>.size
            let frameCount = sampleCount / channelCount
            let normalizer = Float(Int16.max)
            let samples = UnsafeRawPointer(mData).bindMemory(to: Int16.self, capacity: sampleCount)
            return (0..<frameCount).map { frameIndex in
                let channelOffset = frameIndex * channelCount
                let sum = (0..<channelCount).reduce(Float(0)) { partial, channel in
                    partial + (Float(samples[channelOffset + channel]) / normalizer)
                }
                return sum / Float(channelCount)
            }
        }

        return nil
    }

    private func fftBandPeaks(from monoSamples: [Float], sampleRate: Float, setup: FFTSetup) -> [CGFloat] {
        let fftSize = Self.fftSize
        var paddedSamples = [Float](repeating: 0, count: fftSize)
        let sampleSlice = monoSamples.suffix(fftSize)
        let startIndex = fftSize - sampleSlice.count
        paddedSamples.replaceSubrange(startIndex..<fftSize, with: sampleSlice)
        vDSP_vmul(paddedSamples, 1, fftWindow, 1, &paddedSamples, 1, vDSP_Length(fftSize))

        var splitReal = [Float](repeating: 0, count: fftSize / 2)
        var splitImag = [Float](repeating: 0, count: fftSize / 2)

        splitReal.withUnsafeMutableBufferPointer { realBuffer in
            splitImag.withUnsafeMutableBufferPointer { imagBuffer in
                var splitComplex = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                paddedSamples.withUnsafeMutableBufferPointer { sampleBuffer in
                    sampleBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &splitComplex, 1, Self.fftLog2n, FFTDirection(FFT_FORWARD))
            }
        }

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        splitReal.withUnsafeMutableBufferPointer { realBuffer in
            splitImag.withUnsafeMutableBufferPointer { imagBuffer in
                var splitComplex = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        var normalizedMagnitudes = [Float](repeating: 0, count: magnitudes.count)
        var scale = Float(1.0 / Float(fftSize))
        vDSP_vsmul(magnitudes, 1, &scale, &normalizedMagnitudes, 1, vDSP_Length(magnitudes.count))

        return Self.visualizerBandRanges.map { range in
            let matchingBins = normalizedMagnitudes.enumerated().compactMap { index, magnitude -> Float? in
                let frequency = (Float(index) * sampleRate) / Float(fftSize)
                guard range.contains(frequency) else { return nil }
                return magnitude
            }

            let peak = matchingBins.max() ?? 0
            let normalizedPeak = min(1, log10f(1 + (peak * 8)) / 1.5)
            return CGFloat(normalizedPeak)
        }
    }

    private static let restingLevels = Array(repeating: CGFloat(5), count: 6)
}

@MainActor
final class SystemVolumeMonitor {
    private var pollingTask: Task<Void, Never>?
    private var lastObservedVolume: Double?

    func start(using overlayModel: NotchOverlayModel) {
        pollingTask?.cancel()

        pollingTask = Task {
            lastObservedVolume = currentSystemVolume(deviceID: defaultOutputDeviceID())

            while !Task.isCancelled {
                let deviceID = defaultOutputDeviceID()
                let volume = currentSystemVolume(deviceID: deviceID)
                if let volume, let lastObservedVolume, abs(volume - lastObservedVolume) > 0.005 {
                    overlayModel.showVolume(level: volume, outputDeviceName: outputDeviceName(for: deviceID))
                }
                if let volume {
                    lastObservedVolume = volume
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func currentSystemVolume(deviceID: AudioDeviceID?) -> Double? {
        guard let deviceID else {
            return nil
        }

        if let masterVolume = scalarVolume(for: deviceID, channel: kAudioObjectPropertyElementMain) {
            return masterVolume
        }

        let left = scalarVolume(for: deviceID, channel: 1)
        let right = scalarVolume(for: deviceID, channel: 2)

        switch (left, right) {
        case let (left?, right?):
            return (left + right) / 2
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr else { return nil }
        return deviceID
    }

    private func scalarVolume(for deviceID: AudioDeviceID, channel: UInt32) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return Double(volume)
    }

    private func outputDeviceName(for deviceID: AudioDeviceID?) -> String? {
        guard let deviceID else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name as String
    }
}

@MainActor
final class SystemBatteryMonitor {
    private var pollingTask: Task<Void, Never>?
    private var lastStatus: (level: Int, isCharging: Bool, chargingWatts: Double?)?

    func start(using overlayModel: NotchOverlayModel) {
        pollingTask?.cancel()

        pollingTask = Task {
            while !Task.isCancelled {
                let status = currentBatteryStatus()
                overlayModel.updateBattery(
                    level: status?.level,
                    isCharging: status?.isCharging ?? false,
                    chargingWatts: status?.chargingWatts,
                    previousStatus: lastStatus
                )
                lastStatus = status
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func currentBatteryStatus() -> (level: Int, isCharging: Bool, chargingWatts: Double?)? {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sourceList = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
            let source = sourceList.first,
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
            let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
            let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
            maxCapacity > 0
        else {
            return nil
        }

        let isChargingFlag = (description[kIOPSIsChargingKey] as? Bool) ?? false
        let powerSourceState = description[kIOPSPowerSourceStateKey] as? String
        let isCharging = isChargingFlag || powerSourceState == kIOPSACPowerValue
        let level = Int((Double(currentCapacity) / Double(maxCapacity)) * 100.0)
        let chargingWatts = externalAdapterWatts(isCharging: isCharging)
        return (level, isCharging, chargingWatts)
    }

    private func externalAdapterWatts(isCharging: Bool) -> Double? {
        guard isCharging else { return nil }
        guard
            let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        else {
            return nil
        }

        if let watts = details["Watts"] as? Double {
            return watts
        }
        if let watts = details["Watts"] as? Int {
            return Double(watts)
        }
        return nil
    }
}

@MainActor
final class WeatherMonitor: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private weak var overlayModel: NotchOverlayModel?
    private var refreshTask: Task<Void, Never>?
    private var latestCoordinate: CLLocationCoordinate2D?
    private var manualLocationQuery: String?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func start(using overlayModel: NotchOverlayModel) {
        self.overlayModel = overlayModel
        manualLocationQuery = overlayModel.manualWeatherLocation

        if manualLocationQuery != nil {
            startRefreshLoop()
            Task { await resolveManualLocationAndFetch() }
        } else {
            startAutomaticLocationFlow()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manualLocationQuery == nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
            startRefreshLoop()
        case .denied, .restricted:
            overlayModel?.updateWeather(temperatureText: nil, symbolName: nil)
            overlayModel?.updateWeatherLocationStatus(message: "位置情報が使えないため天気を取得できませんでした。", isError: true)
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latestCoordinate = locations.last?.coordinate
        Task {
            await fetchWeather()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manualLocationQuery == nil else { return }
        overlayModel?.updateWeather(temperatureText: nil, symbolName: nil)
        overlayModel?.updateWeatherLocationStatus(message: "現在地の取得に失敗しました。", isError: true)
    }

    func setManualLocation(_ query: String?) {
        manualLocationQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        latestCoordinate = nil
        refreshTask?.cancel()
        refreshTask = nil

        if let manualLocationQuery, !manualLocationQuery.isEmpty {
            startRefreshLoop()
            Task { await resolveManualLocationAndFetch() }
        } else {
            manualLocationQuery = nil
            startAutomaticLocationFlow()
        }
    }

    func refreshNow() {
        Task { @MainActor in
            if manualLocationQuery != nil {
                latestCoordinate = nil
                await resolveManualLocationAndFetch()
            } else if latestCoordinate == nil {
                startAutomaticLocationFlow()
            } else {
                await fetchWeather()
            }
        }
    }

    private func startRefreshLoop() {
        guard refreshTask == nil else { return }

        refreshTask = Task {
            while !Task.isCancelled {
                if manualLocationQuery != nil {
                    if latestCoordinate == nil {
                        await resolveManualLocationAndFetch()
                    } else {
                        await fetchWeather()
                    }
                } else if latestCoordinate == nil {
                    locationManager.requestLocation()
                } else {
                    await fetchWeather()
                }
                try? await Task.sleep(for: .seconds(900))
            }
        }
    }

    private func startAutomaticLocationFlow() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
            startRefreshLoop()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            overlayModel?.updateWeather(temperatureText: nil, symbolName: nil)
        }
    }

    private func resolveManualLocationAndFetch() async {
        guard let manualLocationQuery, !manualLocationQuery.isEmpty else { return }

        do {
            let placemarks = try await geocoder.geocodeAddressString(manualLocationQuery)
            latestCoordinate = placemarks.first?.location?.coordinate
            guard latestCoordinate != nil else {
                overlayModel?.updateWeather(temperatureText: nil, symbolName: nil)
                overlayModel?.updateWeatherLocationStatus(message: "'\(manualLocationQuery)' の場所を見つけられませんでした。", isError: true)
                return
            }
            await fetchWeather()
        } catch {
            overlayModel?.updateWeather(temperatureText: nil, symbolName: nil)
            overlayModel?.updateWeatherLocationStatus(message: "'\(manualLocationQuery)' の場所検索に失敗しました。", isError: true)
        }
    }

    private func fetchWeather() async {
        guard let coordinate = latestCoordinate else { return }
        guard let overlayModel else { return }

        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code&temperature_unit=celsius"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let temperature = Int(response.current.temperature2m.rounded())
            overlayModel.updateWeather(
                temperatureText: "\(temperature)°",
                symbolName: weatherSymbolName(for: response.current.weatherCode)
            )
            if let manualLocationQuery, !manualLocationQuery.isEmpty {
                overlayModel.updateWeatherLocationStatus(
                    message: "'\(manualLocationQuery)' の天気を取得できました。 \(temperature)°",
                    isError: false
                )
            }
        } catch {
            overlayModel.updateWeather(temperatureText: nil, symbolName: nil)
            if let manualLocationQuery, !manualLocationQuery.isEmpty {
                overlayModel.updateWeatherLocationStatus(
                    message: "'\(manualLocationQuery)' の天気取得に失敗しました。",
                    isError: true
                )
            }
        }
    }

    private func weatherSymbolName(for code: Int) -> String {
        switch code {
        case 0:
            return "sun.max.fill"
        case 1, 2:
            return "cloud.sun.fill"
        case 3:
            return "cloud.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51...67, 80...82:
            return "cloud.rain.fill"
        case 71...77, 85, 86:
            return "cloud.snow.fill"
        case 95...99:
            return "cloud.bolt.rain.fill"
        default:
            return "cloud.fill"
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct OpenMeteoResponse: Decodable {
    let current: Current

    struct Current: Decodable {
        let temperature2m: Double
        let weatherCode: Int

        private enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }
}
