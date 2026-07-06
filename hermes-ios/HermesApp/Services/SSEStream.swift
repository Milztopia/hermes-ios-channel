import Foundation

// MARK: - SSEStream
// Reads a server-sent events stream using URLSession async bytes.
// Handles two formats:
//   1. Standard SSE:  event: message_delta\ndata: {...}\n\n
//   2. Embedded JSON: data: {"event": "message_delta", ...}\n\n

struct SSEStream {
    let urlRequest: URLRequest

    func events() -> AsyncThrowingStream<RunEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let (asyncBytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish(throwing: HermesError.invalidResponse)
                        return
                    }

                    var currentEventType = ""
                    var dataLines: [String] = []

                    for try await line in asyncBytes.lines {
                        guard !Task.isCancelled else { break }

                        if line.hasPrefix("event:") {
                            currentEventType = line.dropPrefix("event:").trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let chunk = line.dropPrefix("data:").trimmingCharacters(in: .whitespaces)
                            dataLines.append(chunk)

                            // Eager parse: try each data: line as a self-contained event.
                            // asyncBytes.lines omits empty separator lines on iOS 26, so the
                            // empty-line trigger below may never fire for embedded-JSON servers.
                            let eagerData = dataLines.joined(separator: "\n")
                            if let event = RunEvent.parse(eventType: currentEventType, data: eagerData) {
                                continuation.yield(event)
                                dataLines = []
                                currentEventType = ""
                                switch event {
                                case .runCompleted, .runFailed, .runStopped:
                                    continuation.finish()
                                    return
                                default:
                                    break
                                }
                            }
                        } else if line.isEmpty {
                            // Standard SSE empty-line event delimiter (fallback for multi-line data).
                            let dataString = dataLines.joined(separator: "\n")
                            dataLines = []

                            if let event = RunEvent.parse(eventType: currentEventType, data: dataString) {
                                continuation.yield(event)
                                switch event {
                                case .runCompleted, .runFailed, .runStopped:
                                    continuation.finish()
                                    return
                                default:
                                    break
                                }
                            }
                            currentEventType = ""
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
