import Foundation

public protocol PlatformMatcher: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Return a handle if this platform has a live call right now.
    /// Called on a background queue; must be safe to poll every few seconds.
    func detect() -> CallHandle?
    /// Bring the call to the front. Returns false if it could not.
    func jump(_ handle: CallHandle) -> Bool
}

public struct MatcherRegistry: Sendable {
    public let orderedMatchers: [any PlatformMatcher]

    public init(config: Config) {
        let browsers = config.browsers.compactMap { Browser.known[$0.lowercased()] }
        var entries: [(priority: Int, matcher: any PlatformMatcher)] = []
        for platform in config.platforms where platform.enabled {
            switch platform.id {
            case "zoom":
                entries.append((platform.priority, ZoomMatcher()))
            case "meet":
                entries.append((platform.priority, MeetMatcher(browsers: browsers)))
            default:
                // Anything else must have a micMatchers entry — this is the
                // config-extensibility hook for new platforms.
                if let mic = config.micMatchers.first(where: { $0.id == platform.id }) {
                    entries.append((platform.priority, MicUsageMatcher(config: mic)))
                }
            }
        }
        orderedMatchers = entries.sorted { $0.priority < $1.priority }.map(\.matcher)
    }

    func matcher(id: String) -> (any PlatformMatcher)? {
        orderedMatchers.first { $0.id == id }
    }
}
