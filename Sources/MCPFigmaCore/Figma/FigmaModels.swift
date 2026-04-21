import Foundation

public struct FigmaNode: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let children: [FigmaNode]?

    public init(id: String, name: String, type: String, children: [FigmaNode]? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.children = children
    }
}

public struct FigmaFileNodesResponse: Decodable, Sendable {
    public struct NodeWrapper: Decodable, Sendable {
        public let document: FigmaNode
    }
    public let name: String
    public let nodes: [String: NodeWrapper]
}

public struct FigmaImagesResponse: Decodable, Sendable {
    public let err: String?
    public let images: [String: String?]
}
