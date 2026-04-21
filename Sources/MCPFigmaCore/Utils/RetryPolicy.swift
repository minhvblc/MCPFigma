import Foundation

public struct RetryPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval

    public init(maxAttempts: Int = 4, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 10.0) {
        precondition(maxAttempts >= 1, "maxAttempts must be >= 1")
        precondition(baseDelay >= 0, "baseDelay must be >= 0")
        precondition(maxDelay >= baseDelay, "maxDelay must be >= baseDelay")
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let `default` = RetryPolicy()

    public func backoff(attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter {
            return min(max(retryAfter, 0), maxDelay)
        }
        let exponential = baseDelay * pow(2.0, Double(attempt))
        return min(exponential, maxDelay)
    }

    public static func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        return TimeInterval(trimmed)
    }
}
