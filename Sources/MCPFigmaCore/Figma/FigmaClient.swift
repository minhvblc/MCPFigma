import Foundation

public enum FigmaAPIError: Error, Equatable, Sendable {
    case missingToken
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int)
    case figmaError(String)
    case invalidResponse
    case network(String)
    case exhaustedRetries(lastStatus: Int?)
}

public protocol FigmaAPI: Sendable {
    func fetchNodes(fileKey: String, nodeId: String, depth: Int?) async throws -> FigmaFileNodesResponse
    func fetchNodes(fileKey: String, nodeIds: [String], depth: Int?) async throws -> FigmaFileNodesResponse
    func renderImages(fileKey: String, nodeIds: [String], scale: Int) async throws -> [String: URL]
    func download(_ url: URL) async throws -> Data
    func fetchVariables(fileKey: String) async throws -> FigmaVariablesResponse
    func fetchStyles(fileKey: String) async throws -> FigmaStylesResponse
}

extension FigmaAPI {
    /// Default bridge so existing single-id callers stay source-compatible.
    public func fetchNodes(fileKey: String, nodeIds: [String], depth: Int? = nil) async throws -> FigmaFileNodesResponse {
        // Default delegates to single-id form by joining; conforming types should
        // override for true batching.
        try await fetchNodes(fileKey: fileKey, nodeId: nodeIds.joined(separator: ","), depth: depth)
    }
}

public struct FigmaClient: FigmaAPI {
    public static let imagesBatchSize = 150

    private let token: String
    private let session: URLSession
    private let retryPolicy: RetryPolicy

    public init(token: String, session: URLSession = .shared, retryPolicy: RetryPolicy = .default) {
        self.token = token
        self.session = session
        self.retryPolicy = retryPolicy
    }

    public func fetchNodes(fileKey: String, nodeId: String, depth: Int?) async throws -> FigmaFileNodesResponse {
        let url = FigmaEndpoints.fileNodes(fileKey: fileKey, nodeId: nodeId, depth: depth)
        let data = try await performJSON(url: url)
        do {
            return try JSONDecoder().decode(FigmaFileNodesResponse.self, from: data)
        } catch {
            throw FigmaAPIError.invalidResponse
        }
    }

    public func renderImages(fileKey: String, nodeIds: [String], scale: Int) async throws -> [String: URL] {
        guard !nodeIds.isEmpty else { return [:] }
        var combined: [String: URL] = [:]

        for batch in nodeIds.chunked(by: Self.imagesBatchSize) {
            let url = FigmaEndpoints.images(fileKey: fileKey, nodeIds: batch, scale: scale)
            let data = try await performJSON(url: url)
            let decoded: FigmaImagesResponse
            do {
                decoded = try JSONDecoder().decode(FigmaImagesResponse.self, from: data)
            } catch {
                throw FigmaAPIError.invalidResponse
            }
            if let err = decoded.err, !err.isEmpty {
                throw FigmaAPIError.figmaError(err)
            }
            for (id, urlString) in decoded.images {
                guard let urlString, let parsed = URL(string: urlString) else { continue }
                combined[id] = parsed
            }
        }
        return combined
    }

    public func fetchVariables(fileKey: String) async throws -> FigmaVariablesResponse {
        let url = FigmaEndpoints.variablesLocal(fileKey: fileKey)
        let data = try await performJSON(url: url)
        do {
            return try JSONDecoder().decode(FigmaVariablesResponse.self, from: data)
        } catch {
            throw FigmaAPIError.invalidResponse
        }
    }

    public func fetchStyles(fileKey: String) async throws -> FigmaStylesResponse {
        let url = FigmaEndpoints.fileStyles(fileKey: fileKey)
        let data = try await performJSON(url: url)
        do {
            return try JSONDecoder().decode(FigmaStylesResponse.self, from: data)
        } catch {
            throw FigmaAPIError.invalidResponse
        }
    }

    public func fetchNodes(fileKey: String, nodeIds: [String], depth: Int? = nil) async throws -> FigmaFileNodesResponse {
        guard !nodeIds.isEmpty else {
            return FigmaFileNodesResponse(name: "", nodes: [:])
        }
        let url = FigmaEndpoints.fileNodes(fileKey: fileKey, nodeIds: nodeIds, depth: depth)
        let data = try await performJSON(url: url)
        do {
            return try JSONDecoder().decode(FigmaFileNodesResponse.self, from: data)
        } catch {
            throw FigmaAPIError.invalidResponse
        }
    }

    public func download(_ url: URL) async throws -> Data {
        try await performWithRetry(attempt: 0) {
            let (data, response) = try await self.session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return .fail(FigmaAPIError.invalidResponse)
            }
            return try Self.classify(status: http.statusCode, headers: http.allHeaderFields, data: data)
        }
    }

    private func performJSON(url: URL) async throws -> Data {
        try await performWithRetry(attempt: 0) {
            var request = URLRequest(url: url)
            request.setValue(self.token, forHTTPHeaderField: "X-Figma-Token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .fail(FigmaAPIError.invalidResponse)
            }
            return try Self.classify(status: http.statusCode, headers: http.allHeaderFields, data: data)
        }
    }

    private func performWithRetry(
        attempt: Int,
        operation: () async throws -> RetryableResult<Data>
    ) async throws -> Data {
        var lastStatus: Int?
        var current = attempt
        while current < retryPolicy.maxAttempts {
            let outcome: RetryableResult<Data>
            do {
                outcome = try await operation()
            } catch let urlError as URLError {
                let delay = retryPolicy.backoff(attempt: current, retryAfter: nil)
                try? await Task.sleep(nanoseconds: Self.nanoseconds(delay))
                current += 1
                if current >= retryPolicy.maxAttempts {
                    throw FigmaAPIError.network(urlError.localizedDescription)
                }
                continue
            }
            switch outcome {
            case .success(let data):
                return data
            case .retry(let retryAfter, let status):
                lastStatus = status
                let delay = retryPolicy.backoff(attempt: current, retryAfter: retryAfter)
                try? await Task.sleep(nanoseconds: Self.nanoseconds(delay))
                current += 1
            case .fail(let error):
                throw error
            }
        }
        throw FigmaAPIError.exhaustedRetries(lastStatus: lastStatus)
    }

    static func classify(status: Int, headers: [AnyHashable: Any], data: Data) throws -> RetryableResult<Data> {
        switch status {
        case 200...299:
            return .success(data)
        case 401:
            return .fail(FigmaAPIError.unauthorized)
        case 403:
            return .fail(FigmaAPIError.forbidden)
        case 404:
            return .fail(FigmaAPIError.notFound)
        case 429:
            let retryAfter = RetryPolicy.parseRetryAfter(headers["Retry-After"] as? String)
            return .retry(retryAfter: retryAfter, status: 429)
        case 500...599:
            return .retry(retryAfter: nil, status: status)
        default:
            return .fail(FigmaAPIError.serverError(statusCode: status))
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(seconds, 0) * 1_000_000_000)
    }
}

enum RetryableResult<T: Sendable>: Sendable {
    case success(T)
    case retry(retryAfter: TimeInterval?, status: Int)
    case fail(Error)
}

extension Array {
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
