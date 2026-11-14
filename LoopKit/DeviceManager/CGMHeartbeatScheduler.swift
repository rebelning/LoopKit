import Foundation

/// Evaluates existing pump events; it does not create a BLE wake or run a timer.
/// Observation preserves legacy timing until a device has validated aligned mode.
public final class CGMHeartbeatScheduler {
    public enum Mode: String { case observe, aligned }

    public struct Decision {
        public let shouldFire: Bool
        public let reason: String
        public let targetDate: Date?
        public let readingAge: TimeInterval?
        public let wouldDefer: Bool
    }

    private let lock = NSLock()
    private let minimumInterval: TimeInterval = 120
    private let buffer: TimeInterval = 20
    private var enabled = false
    private var lastReading: Date?
    private var interval: TimeInterval?
    private var recoveryPending = false
    private var lastHeartbeat: Date?

    public init() {}

    public func update(required: Bool, lastReading: Date?, interval: TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        enabled = required
        self.lastReading = required ? lastReading : nil
        self.interval = required ? interval : nil
        // Keep the throttle across disable/re-enable and repeated schedule updates.
    }

    /// Preserve the next existing recovery notification; do not introduce a BLE command.
    public func noteConnectionRecovery() {
        lock.lock()
        recoveryPending = true
        lock.unlock()
    }

    public func evaluate(at now: Date, mode: Mode, recovery: Bool = false) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        let age = lastReading.map { now.timeIntervalSince($0) }
        var target: Date?
        if let reading = lastReading, let interval = interval,
           interval.isFinite, interval > 0, interval <= 3600,
           let age = age, age.isFinite, age >= 0, age <= 2 * interval + buffer {
            target = reading.addingTimeInterval(interval + buffer)
        }
        let wouldDefer = target.map { $0 > now } ?? false
        func decision(_ fire: Bool, _ reason: String) -> Decision {
            Decision(shouldFire: fire, reason: reason, targetDate: target,
                     readingAge: age, wouldDefer: wouldDefer)
        }
        guard enabled else { return decision(false, "disabled") }
        if let last = lastHeartbeat {
            let elapsed = now.timeIntervalSince(last)
            // A clock correction must not suppress heartbeats indefinitely.
            if elapsed >= 0 && elapsed <= minimumInterval {
                return decision(false, "throttled")
            }
        }
        let reason: String
        if lastHeartbeat == nil {
            reason = "bootstrap"
        } else if recovery || recoveryPending {
            reason = "recovery"
        } else if mode == .observe {
            reason = "observe"
        } else if target == nil {
            reason = "fallback"
        } else if wouldDefer {
            return decision(false, "before-target")
        } else {
            // Keep a past-due target past due: missing/late data retries at the
            // legacy minimum interval rather than being deferred every event.
            reason = "target-due"
        }
        recoveryPending = false
        lastHeartbeat = now
        return decision(true, reason)
    }
}
