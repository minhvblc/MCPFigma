import Foundation

public enum FigmaEndpoints {
    public static let baseURL = URL(string: "https://api.figma.com")!

    public static func fileNodes(fileKey: String, nodeId: String, depth: Int?) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1/files/\(fileKey)/nodes"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [URLQueryItem(name: "ids", value: nodeId)]
        if let depth {
            items.append(URLQueryItem(name: "depth", value: String(depth)))
        }
        components.queryItems = items
        return components.url!
    }

    public static func images(fileKey: String, nodeIds: [String], scale: Int) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1/images/\(fileKey)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "ids", value: nodeIds.joined(separator: ",")),
            URLQueryItem(name: "scale", value: String(scale)),
            URLQueryItem(name: "format", value: "png")
        ]
        return components.url!
    }
}
