import Foundation
import MacBridgeCore

enum AudioRuntimeLog {
    private static let outputLock = NSLock()

    static func write(_ message: String, at date: Date = Date()) {
        let timestamp = AudioEvidenceClock.timestamp(date)
        outputLock.lock()
        print("[\(timestamp)] \(message)")
        outputLock.unlock()
    }
}
