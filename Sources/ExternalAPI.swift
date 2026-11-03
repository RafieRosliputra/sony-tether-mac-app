import Foundation
import Network

/// Local JSON-over-TCP API, so scripts, Stream Deck or a Lightroom plugin can
/// drive the app.
///
/// * event port   (default 54643): server pushes one JSON object per line:
///   `{"event":"photo","photo":{...}}`, `{"event":"connected","model":"…"}`,
///   `{"event":"disconnected"}`, `{"event":"script","name":"…","status":"…"}`
/// * reply port   (default 54644): client sends one JSON object per line and
///   gets one line back, e.g. `{"cmd":"capture"}` → `{"ok":true,"photo":{…}}`
final class ExternalAPI {
    private var eventListener: NWListener?
    private var replyListener: NWListener?
    private var eventClients: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.johorstudio.sonytether.api")

    var onCommand: (([String: Any]) -> [String: Any])?
    var isRunning: Bool { eventListener != nil || replyListener != nil }
    private(set) var eventPort = 0
    private(set) var replyPort = 0

    func start(eventPort: Int, replyPort: Int) {
        stop()
        self.eventPort = eventPort
        self.replyPort = replyPort
        eventListener = makeListener(port: eventPort) { [weak self] connection in
            self?.eventClients[ObjectIdentifier(connection)] = connection
            Logger.shared.info("API: event client connected")
            self?.sendWelcome(connection)
        }
        replyListener = makeListener(port: replyPort) { [weak self] connection in
            self?.handleReplyClient(connection)
        }
        if eventListener == nil || replyListener == nil {
            Logger.shared.warn("API: could not listen on \(eventPort)/\(replyPort)")
        } else {
            Logger.shared.info("API: events on 127.0.0.1:\(eventPort), commands on 127.0.0.1:\(replyPort)")
        }
    }

    func stop() {
        eventListener?.cancel()
        replyListener?.cancel()
        eventListener = nil
        replyListener = nil
        for (_, c) in eventClients { c.cancel() }
        eventClients.removeAll()
    }

    func broadcast(_ payload: [String: Any]) {
        guard !eventClients.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        let text = line + "\n"
        for (id, conn) in eventClients {
            conn.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
                if error != nil { self?.eventClients.removeValue(forKey: id) }
            })
        }
    }

    // MARK: - Internals

    private func makeListener(port: Int, onNew: @escaping (NWConnection) -> Void) -> NWListener? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                          port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 1)
        guard let listener = try? NWListener(using: params) else { return nil }
        listener.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            onNew(connection)
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                Logger.shared.warn("API listener failed on \(port): \(error.localizedDescription)")
            }
        }
        listener.start(queue: queue)
        return listener
    }

    private func sendWelcome(_ connection: NWConnection) {
        send(["event": "hello", "app": AppInfo.name, "version": AppInfo.version], to: connection)
    }

    private func send(_ payload: [String: Any], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        connection.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
    }

    private func handleReplyClient(_ connection: NWConnection) {
        Logger.shared.info("API: command client connected")
        receiveLines(on: connection)
    }

    private func receiveLines(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    self.handleLine(String(line), on: connection)
                }
            }
            if error == nil && !isComplete {
                self.receiveLines(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func handleLine(_ line: String, on connection: NWConnection) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(["ok": false, "error": "invalid json"], to: connection)
            return
        }
        let reply = onCommand?(object) ?? ["ok": false, "error": "no handler"]
        send(reply, to: connection)
    }
}
