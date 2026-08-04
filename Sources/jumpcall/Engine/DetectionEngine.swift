import Foundation

/// Polls the matchers on a background queue and publishes state changes.
/// All mutable state is confined to `queue`.
final class DetectionEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.joncode.jumpcall.engine", qos: .utility)
    private let registry: MatcherRegistry
    private let config: Config
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var userPaused = false
    private var systemAsleep = false
    private var lastState: CallState = .none
    private let cachedStateLock = NSLock()
    private var _cachedState: CallState = .none

    /// Thread-safe snapshot of the last detected state. The hotkey's
    /// pass-through decision reads this — it must never block on the
    /// engine queue (a slow browser probe would freeze keystrokes).
    var cachedState: CallState {
        cachedStateLock.withLock { _cachedState }
    }

    /// Invoked on the main actor whenever the detected state changes.
    /// Set once, before start().
    var onStateChange: (@MainActor @Sendable (CallState) -> Void)?

    init(config: Config, registry: MatcherRegistry) {
        self.config = config
        self.registry = registry
    }

    func start() {
        queue.async { self.startTimer() }
    }

    func setPaused(_ paused: Bool) {
        queue.async {
            self.userPaused = paused
            if paused { self.updateState(.none) }
            else { self.pollTick() }
        }
    }

    func setSystemAsleep(_ asleep: Bool) {
        queue.async {
            self.systemAsleep = asleep
            if !asleep { self.pollTick() }
        }
    }

    /// Fresh detection right now — used by the click path so a stale cached
    /// state can never cause a jump to a call that already ended.
    func verifyNow(_ completion: @MainActor @Sendable @escaping (CallState) -> Void) {
        queue.async {
            let state = self.detect(includeMeet: true)
            if !self.userPaused { self.updateState(state) }
            Task { @MainActor in completion(state) }
        }
    }

    // MARK: - Queue-confined

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(2.0, config.pollSeconds)
        t.schedule(deadline: .now() + 1, repeating: interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.pollTick() }
        t.resume()
        timer = t
    }

    private func pollTick() {
        guard !userPaused, !systemAsleep else { return }
        tick += 1
        let includeMeet = config.meetPollMultiplier <= 1
            || tick % config.meetPollMultiplier == 0
        updateState(detect(includeMeet: includeMeet))
    }

    private func detect(includeMeet: Bool) -> CallState {
        for matcher in registry.orderedMatchers {
            if matcher.id == "meet", !includeMeet {
                // Skipped this tick for cost; keep the previous Meet result
                // rather than flapping to .none between probes.
                if case .live(let h) = lastState, h.platformID == "meet" { return lastState }
                continue
            }
            if let handle = matcher.detect() {
                return .live(handle)
            }
        }
        return .none
    }

    private func updateState(_ state: CallState) {
        cachedStateLock.withLock { _cachedState = state }
        guard state != lastState else { return }
        lastState = state
        if let callback = onStateChange {
            Task { @MainActor in callback(state) }
        }
    }
}
