import Foundation
import Network
import SwiftUI

@MainActor
final class PluginBridgeServer {
    private struct ConnectionState {
        let connection: NWConnection
        var buffer = Data()
    }

    private enum BridgeError: LocalizedError {
        case invalidRequest
        case unsupportedMethod(String)
        case missingField(String)
        case invalidPayload(String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return "Invalid request."
            case .unsupportedMethod(let method):
                return "Unsupported method: \(method)"
            case .missingField(let name):
                return "Missing field: \(name)"
            case .invalidPayload(let message):
                return message
            }
        }
    }

    static let shared = PluginBridgeServer()
    static let defaultPort: UInt16 = 38591

    private weak var overlayModel: NotchOverlayModel?
    private let queue = DispatchQueue(label: "jp.amania.PullNotch.PluginBridgeServer")
    private var listener: NWListener?
    private var connections: [UUID: ConnectionState] = [:]

    private init() {}

    func start(using overlayModel: NotchOverlayModel) {
        self.overlayModel = overlayModel

        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.defaultPort)!)
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        print("PluginBridgeServer: listening on 127.0.0.1:\(Self.defaultPort)")
                    case .failed(let error):
                        print("PluginBridgeServer: failed - \(error.localizedDescription)")
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("PluginBridgeServer: could not start - \(error.localizedDescription)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let connectionID = UUID()
        connections[connectionID] = ConnectionState(connection: connection)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handle(state: state, connectionID: connectionID)
            }
        }

        connection.start(queue: queue)
        receiveNext(on: connection, connectionID: connectionID)
    }

    private func handle(state: NWConnection.State, connectionID: UUID) {
        switch state {
        case .ready:
            if !isLoopbackConnection(connectionID: connectionID) {
                sendEnvelope(["event": "error", "message": "Only localhost clients are allowed."], to: connectionID)
                close(connectionID: connectionID)
            }
        case .failed(let error):
            print("PluginBridgeServer: connection failed - \(error.localizedDescription)")
            close(connectionID: connectionID)
        case .cancelled:
            close(connectionID: connectionID)
        default:
            break
        }
    }

    private func isLoopbackConnection(connectionID: UUID) -> Bool {
        guard let state = connections[connectionID] else { return false }
        let description = String(describing: state.connection.endpoint)
        return description.contains("127.0.0.1") || description.contains("::1") || description.contains("localhost")
    }

    private func receiveNext(on connection: NWConnection, connectionID: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                if let data, !data.isEmpty {
                    self.append(data: data, to: connectionID)
                }

                if isComplete || error != nil {
                    self.close(connectionID: connectionID)
                    return
                }

                self.receiveNext(on: connection, connectionID: connectionID)
            }
        }
    }

    private func append(data: Data, to connectionID: UUID) {
        guard var state = connections[connectionID] else { return }
        state.buffer.append(data)

        while let newlineRange = state.buffer.firstRange(of: Data([0x0A])) {
            let line = state.buffer.subdata(in: state.buffer.startIndex ..< newlineRange.lowerBound)
            state.buffer.removeSubrange(state.buffer.startIndex ... newlineRange.lowerBound)

            guard !line.isEmpty else { continue }
            handle(line: line, connectionID: connectionID)
        }

        connections[connectionID] = state
    }

    private func handle(line: Data, connectionID: UUID) {
        let requestID: String

        do {
            guard
                let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                let method = object["method"] as? String
            else {
                throw BridgeError.invalidRequest
            }

            requestID = object["id"] as? String ?? UUID().uuidString
            let result = try handle(method: method, payload: object)
            sendEnvelope([
                "id": requestID,
                "ok": true,
                "result": result
            ], to: connectionID)
        } catch {
            let bridgeError = error as? BridgeError
            sendEnvelope([
                "id": requestIDOrFallback(from: line),
                "ok": false,
                "error": bridgeError?.errorDescription ?? error.localizedDescription
            ], to: connectionID)
        }
    }

    private func handle(method: String, payload: [String: Any]) throws -> [String: Any] {
        guard let overlayModel else {
            throw BridgeError.invalidPayload("Overlay model is unavailable.")
        }

        switch method {
        case "ping":
            return [
                "pong": true,
                "port": Int(Self.defaultPort)
            ]
        case "getState":
            return try encodeToJSONObject(overlayModel.bridgeStateSnapshot())
        case "showStatus":
            guard let message = payload["message"] as? String else {
                throw BridgeError.missingField("message")
            }
            let duration = payload["duration"] as? Double ?? 3
            overlayModel.showPluginStatus(message: message, duration: duration)
            return ["shown": true]
        case "setWidget":
            guard let clientID = payload["clientID"] as? String else {
                throw BridgeError.missingField("clientID")
            }
            let widget = try decodePayload(BridgeWidgetPayload.self, from: payload["widget"], field: "widget")
            try overlayModel.bridgeUpsertWidget(widget, clientID: clientID)
            return ["updated": true]
        case "removeWidget":
            guard let clientID = payload["clientID"] as? String else {
                throw BridgeError.missingField("clientID")
            }
            guard let widgetID = payload["widgetID"] as? String else {
                throw BridgeError.missingField("widgetID")
            }
            overlayModel.bridgeRemoveWidget(id: widgetID, clientID: clientID)
            return ["removed": true]
        case "setPage":
            guard let clientID = payload["clientID"] as? String else {
                throw BridgeError.missingField("clientID")
            }
            let page = try decodePayload(BridgePagePayload.self, from: payload["page"], field: "page")
            overlayModel.bridgeUpsertPage(page, clientID: clientID)
            return ["updated": true]
        case "removePage":
            guard let clientID = payload["clientID"] as? String else {
                throw BridgeError.missingField("clientID")
            }
            guard let pageID = payload["pageID"] as? String else {
                throw BridgeError.missingField("pageID")
            }
            overlayModel.bridgeRemovePage(id: pageID, clientID: clientID)
            return ["removed": true]
        case "clearClient":
            guard let clientID = payload["clientID"] as? String else {
                throw BridgeError.missingField("clientID")
            }
            overlayModel.bridgeClearContent(clientID: clientID)
            return ["cleared": true]
        case "openSettings":
            overlayModel.openSettingsWindow()
            return ["opened": "settings"]
        case "openPlayer":
            overlayModel.bridgeOpenMusicPlayer()
            return ["opened": "player"]
        case "closePlayer":
            overlayModel.dismissExpandedPanel()
            return ["closed": "player"]
        case "togglePlayer":
            overlayModel.toggleMusicPlayer()
            return ["toggled": "player"]
        case "selectExpandedPage":
            guard let pageID = payload["pageID"] as? String else {
                throw BridgeError.missingField("pageID")
            }
            if let clientID = payload["clientID"] as? String {
                overlayModel.selectExpandedWidgetPage(id: "bridge.\(clientID.replacingOccurrences(of: "::", with: "--"))::\(pageID)")
            } else {
                overlayModel.selectExpandedWidgetPage(id: pageID)
            }
            return ["selectedPageID": pageID]
        case "setPluginEnabled":
            guard let pluginID = payload["pluginID"] as? String else {
                throw BridgeError.missingField("pluginID")
            }
            guard let enabled = payload["enabled"] as? Bool else {
                throw BridgeError.missingField("enabled")
            }
            overlayModel.setPluginEnabled(pluginID, isEnabled: enabled)
            return ["pluginID": pluginID, "enabled": enabled]
        default:
            throw BridgeError.unsupportedMethod(method)
        }
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from value: Any?, field: String) throws -> T {
        guard let value else {
            throw BridgeError.missingField(field)
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func encodeToJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.invalidPayload("Could not encode response.")
        }
        return object
    }

    private func requestIDOrFallback(from line: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let requestID = object["id"] as? String
        else {
            return UUID().uuidString
        }
        return requestID
    }

    private func sendEnvelope(_ object: [String: Any], to connectionID: UUID) {
        guard let state = connections[connectionID] else { return }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }

        var payload = data
        payload.append(0x0A)
        state.connection.send(content: payload, completion: .contentProcessed { error in
            if let error {
                print("PluginBridgeServer: send failed - \(error.localizedDescription)")
            }
        })
    }

    private func close(connectionID: UUID) {
        guard let state = connections.removeValue(forKey: connectionID) else { return }
        state.connection.cancel()
    }
}
