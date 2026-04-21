import Testing
import Foundation
@testable import MCPFigmaCore

@Suite("RetryPolicy")
struct RetryPolicyTests {
    @Test("Exponential backoff grows then caps at maxDelay")
    func exponentialBackoffCaps() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 0.5, maxDelay: 4.0)
        #expect(policy.backoff(attempt: 0) == 0.5)
        #expect(policy.backoff(attempt: 1) == 1.0)
        #expect(policy.backoff(attempt: 2) == 2.0)
        #expect(policy.backoff(attempt: 3) == 4.0)
        #expect(policy.backoff(attempt: 4) == 4.0)
        #expect(policy.backoff(attempt: 99) == 4.0)
    }

    @Test("retryAfter overrides exponential backoff (capped at maxDelay)")
    func retryAfterOverrides() {
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 0.5, maxDelay: 10.0)
        #expect(policy.backoff(attempt: 0, retryAfter: 3.0) == 3.0)
        #expect(policy.backoff(attempt: 5, retryAfter: 2.0) == 2.0)
        #expect(policy.backoff(attempt: 0, retryAfter: 99.0) == 10.0)
        #expect(policy.backoff(attempt: 0, retryAfter: -5.0) == 0.0)
    }

    @Test("parseRetryAfter handles numeric seconds, nil, and invalid strings")
    func parseRetryAfterBehavior() {
        #expect(RetryPolicy.parseRetryAfter("5") == 5.0)
        #expect(RetryPolicy.parseRetryAfter(" 12 ") == 12.0)
        #expect(RetryPolicy.parseRetryAfter(nil) == nil)
        #expect(RetryPolicy.parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT") == nil)
        #expect(RetryPolicy.parseRetryAfter("") == nil)
    }
}
