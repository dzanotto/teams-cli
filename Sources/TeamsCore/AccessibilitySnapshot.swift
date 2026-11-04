public struct ControlSnapshot: Codable, Equatable {
    public let role: String
    public let identifier: String
    public let label: String
    /// Additional accessible action descriptions, when exposed separately from the title.
    public let detailLabels: [String]?

    public init(role: String, identifier: String, label: String, detailLabels: [String]? = nil) {
        self.role = role
        self.identifier = identifier
        self.label = label
        self.detailLabels = detailLabels
    }
}

public struct WindowSnapshot: Codable, Equatable {
    public let index: Int
    public let controls: [ControlSnapshot]

    public init(index: Int, controls: [ControlSnapshot]) {
        self.index = index
        self.controls = controls
    }
}

public struct ExcludedWindow: Codable, Equatable {
    public let window: Int
    public let reason: String

    public init(window: Int, reason: String) {
        self.window = window
        self.reason = reason
    }
}
