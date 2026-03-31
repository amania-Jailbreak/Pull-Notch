import Foundation

final class MediaRemoteAdapterBridge {
    private let queue = DispatchQueue(label: "PullNotch.MediaRemote")

    private(set) var lastDiagnostics: String?
    private(set) var lastStatus: Int32 = 0

    func currentPayload() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = self.run(command: "get", arguments: ["--now", "--micros"])
                self.lastStatus = result.status
                self.lastDiagnostics = result.combinedOutput

                guard result.status == 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !output.isEmpty, output != "null" else {
                    continuation.resume(returning: #"{"title":null}"#)
                    return
                }

                continuation.resume(returning: output)
            }
        }
    }

    func send(_ command: MediaControlCommand) {
        queue.async {
            let result = self.run(command: "send", arguments: ["\(command.rawValue)"])
            self.lastStatus = result.status
            self.lastDiagnostics = result.combinedOutput
        }
    }

    private func run(command: String, arguments extraArguments: [String] = []) -> AdapterCommandResult {
        guard let executable = adapterScriptPath() else {
            return .init(status: -1, stdout: "", stderr: "mediaremote-adapter.pl not found", command: command)
        }

        guard let frameworkPath = adapterFrameworkPath() else {
            return .init(status: -2, stdout: "", stderr: "MediaRemoteAdapter.framework not found", command: command)
        }

        let helperPath = adapterHelperPath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")

        var arguments = [executable, frameworkPath]
        if command == "test", let helperPath {
            arguments.append(helperPath)
        }
        arguments.append(command)
        arguments.append(contentsOf: extraArguments)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutData = Data()
        var stderrData = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stdoutData.append(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrData.append(chunk)
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return .init(status: -3, stdout: "", stderr: error.localizedDescription, command: command)
        }

        if finished.wait(timeout: .now() + .seconds(4)) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + .seconds(1))
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .init(
                status: -4,
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: "adapter process timed out while running \(command)",
                command: command
            )
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        return .init(status: process.terminationStatus, stdout: stdout, stderr: stderr, command: command)
    }

    private func adapterScriptPath() -> String? {
        resourceCandidates(
            filename: "mediaremote-adapter.pl",
            subdirectory: "MediaRemoteAdapter"
        ).first { FileManager.default.fileExists(atPath: $0) }
    }

    private func adapterFrameworkPath() -> String? {
        resourceCandidates(
            filename: "MediaRemoteAdapter.framework",
            subdirectory: "MediaRemoteAdapter"
        ).first { FileManager.default.fileExists(atPath: $0) }
    }

    private func adapterHelperPath() -> String? {
        resourceCandidates(
            filename: "MediaRemoteAdapterTestClient",
            subdirectory: "MediaRemoteAdapter"
        ).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func resourceCandidates(filename: String, subdirectory: String) -> [String] {
        let currentDirectory = FileManager.default.currentDirectoryPath
        let bundleResourcePath = Bundle.main.resourcePath ?? ""

        return [
            "\(bundleResourcePath)/\(subdirectory)/\(filename)",
            "\(bundleResourcePath)/\(filename)",
            "\(currentDirectory)/Resources/\(subdirectory)/\(filename)",
            "\(currentDirectory)/\(filename)"
        ]
    }
}

struct AdapterCommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let command: String

    var combinedOutput: String {
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (trimmedStdout.isEmpty, trimmedStderr.isEmpty) {
        case (false, false):
            return "[\(command)] stdout:\n\(trimmedStdout)\n\nstderr:\n\(trimmedStderr)"
        case (false, true):
            return "[\(command)] stdout:\n\(trimmedStdout)"
        case (true, false):
            return "[\(command)] stderr:\n\(trimmedStderr)"
        case (true, true):
            return "[\(command)] no output"
        }
    }

    var summary: String {
        status == 0 ? "success" : "failed"
    }
}
