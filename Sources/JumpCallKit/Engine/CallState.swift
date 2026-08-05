import Foundation

/// Everything needed to describe — and later jump to — one live call.
public struct CallHandle: Sendable, Equatable {
    public let platformID: String
    public let displayName: String
    /// Extra human-readable context (meeting URL, matched bundle id).
    public let detail: String?
    /// App to activate when jumping (native platforms).
    public let activateBundleID: String?
    /// Browser-based calls only: which browser, and where the tab lives.
    public let browserID: String?
    public let windowIndex: Int?
    public let tabIndex: Int?

    init(
        platformID: String,
        displayName: String,
        detail: String? = nil,
        activateBundleID: String? = nil,
        browserID: String? = nil,
        windowIndex: Int? = nil,
        tabIndex: Int? = nil
    ) {
        self.platformID = platformID
        self.displayName = displayName
        self.detail = detail
        self.activateBundleID = activateBundleID
        self.browserID = browserID
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
    }
}

enum CallState: Sendable, Equatable {
    case none
    case live(CallHandle)

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    var handle: CallHandle? {
        if case .live(let h) = self { return h }
        return nil
    }
}
