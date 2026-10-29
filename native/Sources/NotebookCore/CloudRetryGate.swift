import Foundation
import CloudKit

struct CloudCooldownError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Persists Apple's retry deadline so foreground polling and app restarts cannot
/// bypass it. CKSyncEngine separately manages retries for its automatic requests.
struct CloudRetryGate {
    let store: RecordStore
    let container: String
    private var metadataKey: String { "cloud-retry-until:" + container }

    func remaining(now: Date = Date()) throws -> TimeInterval {
        guard let value = try store.metadata(metadataKey), let deadline = Double(value) else { return 0 }
        return max(0, deadline - now.timeIntervalSince1970)
    }
    func message(now: Date = Date()) throws -> String? {
        let seconds = try remaining(now:now)
        guard seconds > 0 else { return nil }
        let minutes = Int(ceil(seconds / 60))
        return "iCloud is temporarily busy. Try again in about \(minutes) \(minutes == 1 ? "minute" : "minutes"). Your notes are saved on this device."
    }
    func check(now: Date = Date()) throws {
        if let message = try message(now:now) { throw CloudCooldownError(message:message) }
    }
    @discardableResult func record(_ error: Error, now: Date = Date()) throws -> Bool {
        guard let delay = Self.delay(error), delay.isFinite, delay > 0 else { return false }
        let seconds = max(delay, try remaining(now:now))
        try store.setMetadata(metadataKey,String(now.timeIntervalSince1970 + seconds))
        return true
    }
    private static func delay(_ error: Error) -> TimeInterval? {
        let error = error as NSError
        var delays: [TimeInterval] = []
        if error.domain == CKErrorDomain {
            if let seconds = error.userInfo[CKErrorRetryAfterKey] as? NSNumber,
               seconds.doubleValue.isFinite, seconds.doubleValue > 0 {
                delays.append(seconds.doubleValue)
            } else if error.code == CKError.serviceUnavailable.rawValue || error.code == CKError.requestRateLimited.rawValue {
                delays.append(60)
            }
            if let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable:Error] {
                delays.append(contentsOf:partial.values.compactMap { delay($0) })
            }
        }
        return delays.max()
    }
}
