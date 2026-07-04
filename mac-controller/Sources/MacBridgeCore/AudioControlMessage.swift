import Foundation

public enum AudioBridgeMode: String, Codable, Equatable {
    case lowLatency
    case stable
}

public struct AudioControlMessage: Codable, Equatable {
    public let type: String
    public let enabled: Bool
    public let mode: AudioBridgeMode
    public let volume: Double
    public let muted: Bool

    public init(enabled: Bool, mode: AudioBridgeMode, volume: Double, muted: Bool) {
        self.type = "audioControl"
        self.enabled = enabled
        self.mode = mode
        self.volume = min(max(volume, 0), 1)
        self.muted = muted
    }

    public func jsonLine() throws -> String {
        #"{"type":"\#(type)","enabled":\#(enabled),"mode":"\#(mode.rawValue)","volume":\#(volume),"muted":\#(muted)}"# + "\n"
    }
}
