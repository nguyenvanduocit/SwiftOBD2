import Foundation

actor BLEMessageProcessor {
    private var buffer = Data()
    private var messageCompletion: (([String]?, Error?) -> Void)?

    func processReceivedData(_ data: Data) {
        buffer.append(data)

        guard let string = String(data: buffer, encoding: .utf8) else {
            // Only clear if buffer is getting too large
            if buffer.count > BLEConstants.maxBufferSize {
                obdWarning("Buffer exceeded max size, clearing", category: .communication)
                buffer.removeAll()
            }
            return
        }

        // Check for end of response marker
        if string.contains(">") {
            let response = parseResponse(from: string)
            handleParsedResponse(response)
            buffer.removeAll()
        }
    }

    private func parseResponse(from string: String) -> [String] {
        // Split by newlines and clean up
        let lines = string
            .replacingOccurrences(of: ">", with: "") // Remove prompt marker
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        obdDebug("Parsed response: \(lines)", category: .communication)
        return lines
    }

    private func handleParsedResponse(_ lines: [String]) {
        let completion = messageCompletion
        messageCompletion = nil

        guard let completion = completion else {
            obdWarning("Received response with no pending completion", category: .communication)
            return
        }

        if let firstLine = lines.first, firstLine.uppercased().contains("NO DATA") {
            completion(nil, BLEManagerError.noData)
        } else if lines.isEmpty {
            completion(nil, BLEManagerError.noData)
        } else {
            completion(lines, nil)
        }
    }

    func waitForResponse(timeout: TimeInterval) async throws -> [String] {
        // Timeout task calls back into actor to cancel the pending response
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.cancelPendingResponse(error: BLEMessageProcessorError.responseTimeout)
        }

        defer { timeoutTask.cancel() }

        // Called directly from actor method → closure runs on actor executor → safe
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            if messageCompletion != nil {
                obdError("Concurrent command detected - previous command still pending", category: .communication)
                messageCompletion?(nil, BLEMessageProcessorError.responseTimeout)
                messageCompletion = nil
            }

            messageCompletion = { response, error in
                if let response {
                    continuation.resume(returning: response)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: BLEMessageProcessorError.responseTimeout)
                }
            }
        }
    }

    private func cancelPendingResponse(error: Error) {
        guard let completion = messageCompletion else { return }
        messageCompletion = nil
        completion(nil, error)
    }

    func reset() {
        buffer.removeAll()
        let completion = messageCompletion
        messageCompletion = nil

        // Call completion with error if it exists
        completion?(nil, BLEManagerError.peripheralNotConnected)
    }
}

// MARK: - Error Types

enum BLEMessageProcessorError: Error, LocalizedError {
    case responseTimeout

    var errorDescription: String? {
        switch self {
        case .responseTimeout:
            return "Timeout waiting for BLE response"
        }
    }
}
