import Testing
import Foundation
@testable import MCPFigmaCore

@Suite("FigmaClient", .serialized)
struct FigmaClientTests {
    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func makeClient(session: URLSession, retryPolicy: RetryPolicy = .default) -> FigmaClient {
        FigmaClient(token: "test-token", session: session, retryPolicy: retryPolicy)
    }

    @Test("fetchNodes sends X-Figma-Token and parses response")
    func fetchNodesHappy() async throws {
        let session = makeSession()
        let json = """
        {
          "name": "Test",
          "nodes": {
            "1:2": {
              "document": { "id": "1:2", "name": "eICHome", "type": "FRAME" }
            }
          }
        }
        """.data(using: .utf8)!

        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/v1/files/abc/nodes")
            #expect(request.url?.query?.contains("ids=1:2") == true)
            #expect(request.value(forHTTPHeaderField: "X-Figma-Token") == "test-token")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                json
            )
        }

        let client = makeClient(session: session)
        let response = try await client.fetchNodes(fileKey: "abc", nodeId: "1:2", depth: nil)
        #expect(response.nodes["1:2"]?.document.name == "eICHome")
    }

    @Test("401 returns .unauthorized without retry")
    func unauthorizedFailsFast() async throws {
        let session = makeSession()
        let counter = RequestCounter()
        MockURLProtocol.setHandler { request in
            counter.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let client = makeClient(session: session)
        await #expect(throws: FigmaAPIError.unauthorized) {
            _ = try await client.fetchNodes(fileKey: "abc", nodeId: "1:2", depth: nil)
        }
        #expect(counter.count == 1)
    }

    @Test("429 retries then succeeds on second attempt, respects Retry-After")
    func rateLimitedThenSucceeds() async throws {
        let session = makeSession()
        let counter = RequestCounter()
        let json = """
        { "name": "Test", "nodes": {} }
        """.data(using: .utf8)!

        MockURLProtocol.setHandler { request in
            let attempt = counter.incrementAndGet()
            if attempt == 1 {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 429,
                        httpVersion: nil,
                        headerFields: ["Retry-After": "0"]
                    )!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                json
            )
        }

        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02)
        let client = makeClient(session: session, retryPolicy: policy)
        _ = try await client.fetchNodes(fileKey: "abc", nodeId: "1:2", depth: nil)
        #expect(counter.count == 2)
    }

    @Test("5xx retries until exhausted")
    func serverErrorExhaustsRetries() async throws {
        let session = makeSession()
        let counter = RequestCounter()
        MockURLProtocol.setHandler { request in
            counter.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.01)
        let client = makeClient(session: session, retryPolicy: policy)
        await #expect(throws: FigmaAPIError.self) {
            _ = try await client.fetchNodes(fileKey: "abc", nodeId: "1:2", depth: nil)
        }
        #expect(counter.count == 3)
    }

    @Test("renderImages parses image URLs and skips null values")
    func renderImagesParsesURLs() async throws {
        let session = makeSession()
        let json = """
        {
          "err": null,
          "images": {
            "1:2": "https://cdn.figma.com/a.png",
            "1:3": null,
            "1:4": "https://cdn.figma.com/b.png"
          }
        }
        """.data(using: .utf8)!

        MockURLProtocol.setHandler { request in
            #expect(request.url?.path == "/v1/images/abc")
            #expect(request.url?.query?.contains("scale=2") == true)
            #expect(request.url?.query?.contains("format=png") == true)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                json
            )
        }

        let client = makeClient(session: session)
        let images = try await client.renderImages(fileKey: "abc", nodeIds: ["1:2", "1:3", "1:4"], scale: 2)
        #expect(images.count == 2)
        #expect(images["1:2"]?.absoluteString == "https://cdn.figma.com/a.png")
        #expect(images["1:4"]?.absoluteString == "https://cdn.figma.com/b.png")
        #expect(images["1:3"] == nil)
    }

    @Test("renderImages surfaces Figma error field")
    func renderImagesSurfacesFigmaError() async throws {
        let session = makeSession()
        let json = """
        { "err": "Something went wrong", "images": {} }
        """.data(using: .utf8)!

        MockURLProtocol.setHandler { request in
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                json
            )
        }

        let client = makeClient(session: session)
        await #expect(throws: FigmaAPIError.self) {
            _ = try await client.renderImages(fileKey: "abc", nodeIds: ["1:2"], scale: 2)
        }
    }

    @Test("download returns bytes on 200")
    func downloadReturnsBytes() async throws {
        let session = makeSession()
        let payload = Data([0x89, 0x50, 0x4E, 0x47])
        MockURLProtocol.setHandler { request in
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                payload
            )
        }

        let client = makeClient(session: session)
        let data = try await client.download(URL(string: "https://cdn.figma.com/a.png")!)
        #expect(data == payload)
    }
}

final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        _count += 1
    }

    func incrementAndGet() -> Int {
        lock.lock(); defer { lock.unlock() }
        _count += 1
        return _count
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
    }

    static func resetHandler() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
    }

    static func currentHandler() -> (@Sendable (URLRequest) -> (HTTPURLResponse, Data))? {
        lock.lock(); defer { lock.unlock() }
        return _handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
