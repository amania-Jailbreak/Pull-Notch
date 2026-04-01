import Foundation
import PullNotchPluginKit

@MainActor
final class PluginManager {
    private struct LoadedPluginRuntime {
        let bundle: Bundle
        let manifest: PluginManifest
        let plugin: PullNotchPlugin
        let context: PluginContext
    }

    private weak var overlayModel: NotchOverlayModel?
    private var runtimes: [String: LoadedPluginRuntime] = [:]
    private var discoveredBundles: [String: Bundle] = [:]
    private var runtimeInfos: [String: PluginRuntimeInfo] = [:]

    private static let enabledPluginKeyPrefix = "PullNotch.plugin.enabled."

    func start(using overlayModel: NotchOverlayModel) {
        self.overlayModel = overlayModel
        overlayModel.attachPluginManager(self)
        loadPlugins()
    }

    func setPluginEnabled(id: String, isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: Self.enabledPluginKeyPrefix + id)

        if isEnabled {
            activatePluginIfPossible(id: id)
        } else {
            Task { await deactivatePlugin(id: id) }
        }
    }

    private func loadPlugins() {
        runtimes.removeAll()
        discoveredBundles.removeAll()
        runtimeInfos.removeAll()

        let fileManager = FileManager.default
        guard let pluginsDirectoryURL = pluginsDirectoryURL() else {
            publishRuntimeInfos()
            return
        }

        let bundleURLs = (try? fileManager.contentsOfDirectory(
            at: pluginsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension == "bundle" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            ?? []

        for bundleURL in bundleURLs {
            discoverPlugin(at: bundleURL)
        }

        publishRuntimeInfos()
    }

    private func discoverPlugin(at bundleURL: URL) {
        let bundle = Bundle(url: bundleURL)
        guard let bundle else { return }

        guard
            let principalClass = bundle.principalClass as? PullNotchPlugin.Type
        else {
            let fallbackID = bundle.bundleIdentifier ?? bundleURL.deletingPathExtension().lastPathComponent
            runtimeInfos[fallbackID] = PluginRuntimeInfo(
                id: fallbackID,
                displayName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? fallbackID,
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                capabilities: [],
                state: .failed,
                errorMessage: "Principal class is missing or does not conform to PullNotchPlugin.",
                bundlePath: bundleURL.path
            )
            return
        }

        let manifest = principalClass.manifest
        discoveredBundles[manifest.id] = bundle

        guard isPluginEnabled(manifest.id) else {
            runtimeInfos[manifest.id] = PluginRuntimeInfo(
                id: manifest.id,
                displayName: manifest.displayName,
                version: manifest.version,
                capabilities: manifest.capabilities,
                state: .disabled,
                errorMessage: nil,
                bundlePath: bundleURL.path
            )
            return
        }

        activatePlugin(bundle: bundle, principalClass: principalClass)
    }

    private func activatePluginIfPossible(id: String) {
        guard runtimes[id] == nil, let bundle = discoveredBundles[id] else {
            publishRuntimeInfos()
            return
        }

        guard let principalClass = bundle.principalClass as? PullNotchPlugin.Type else {
            runtimeInfos[id] = PluginRuntimeInfo(
                id: id,
                displayName: runtimeInfos[id]?.displayName ?? id,
                version: runtimeInfos[id]?.version ?? "unknown",
                capabilities: runtimeInfos[id]?.capabilities ?? [],
                state: .failed,
                errorMessage: "Principal class is missing or does not conform to PullNotchPlugin.",
                bundlePath: bundle.bundleURL.path
            )
            publishRuntimeInfos()
            return
        }

        activatePlugin(bundle: bundle, principalClass: principalClass)
    }

    private func activatePlugin(bundle: Bundle, principalClass: PullNotchPlugin.Type) {
        guard let overlayModel else { return }

        let plugin = principalClass.init()
        let manifest = principalClass.manifest
        let context = overlayModel.makePluginContext(for: manifest)

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await plugin.activate(context: context)
                self.runtimes[manifest.id] = LoadedPluginRuntime(
                    bundle: bundle,
                    manifest: manifest,
                    plugin: plugin,
                    context: context
                )
                self.runtimeInfos[manifest.id] = PluginRuntimeInfo(
                    id: manifest.id,
                    displayName: manifest.displayName,
                    version: manifest.version,
                    capabilities: manifest.capabilities,
                    state: .loaded,
                    errorMessage: nil,
                    bundlePath: bundle.bundleURL.path
                )
            } catch {
                overlayModel.unregisterPluginContent(for: manifest.id)
                self.runtimeInfos[manifest.id] = PluginRuntimeInfo(
                    id: manifest.id,
                    displayName: manifest.displayName,
                    version: manifest.version,
                    capabilities: manifest.capabilities,
                    state: .failed,
                    errorMessage: error.localizedDescription,
                    bundlePath: bundle.bundleURL.path
                )
            }

            self.publishRuntimeInfos()
        }
    }

    private func deactivatePlugin(id: String) async {
        guard let runtime = runtimes.removeValue(forKey: id) else {
            if let info = runtimeInfos[id] {
                runtimeInfos[id] = PluginRuntimeInfo(
                    id: info.id,
                    displayName: info.displayName,
                    version: info.version,
                    capabilities: info.capabilities,
                    state: .disabled,
                    errorMessage: nil,
                    bundlePath: info.bundlePath
                )
                publishRuntimeInfos()
            }
            return
        }

        await runtime.plugin.deactivate()
        overlayModel?.unregisterPluginContent(for: id)

        runtimeInfos[id] = PluginRuntimeInfo(
            id: runtime.manifest.id,
            displayName: runtime.manifest.displayName,
            version: runtime.manifest.version,
            capabilities: runtime.manifest.capabilities,
            state: .disabled,
            errorMessage: nil,
            bundlePath: runtime.bundle.bundleURL.path
        )
        publishRuntimeInfos()
    }

    private func publishRuntimeInfos() {
        overlayModel?.updatePluginRuntimeInfos(
            runtimeInfos.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        )
    }

    private func pluginsDirectoryURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Pull Notch", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    private func isPluginEnabled(_ id: String) -> Bool {
        let key = Self.enabledPluginKeyPrefix + id
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }
}
