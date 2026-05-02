import Foundation

public struct ScreenInfo: Equatable, Sendable {
    public let nodeId: String
    public let name: String
    public let type: String
    public let width: Double?
    public let height: Double?

    public init(nodeId: String, name: String, type: String, width: Double?, height: Double?) {
        self.nodeId = nodeId
        self.name = name
        self.type = type
        self.width = width
        self.height = height
    }
}

public struct LottiePlaceholder: Equatable, Sendable {
    public let nodeId: String
    public let figmaName: String
    public let width: Double?
    public let height: Double?

    public init(nodeId: String, figmaName: String, width: Double?, height: Double?) {
        self.nodeId = nodeId
        self.figmaName = figmaName
        self.width = width
        self.height = height
    }
}

public struct Registry: Equatable, Sendable {
    public let rootNodeId: String
    public let rootName: String
    public let rootType: String
    public let screens: [ScreenInfo]
    public let taggedAssets: [FoundAsset]
    public let lottiePlaceholders: [LottiePlaceholder]
    public let warnings: [ScanWarning]

    public init(
        rootNodeId: String,
        rootName: String,
        rootType: String,
        screens: [ScreenInfo],
        taggedAssets: [FoundAsset],
        lottiePlaceholders: [LottiePlaceholder],
        warnings: [ScanWarning]
    ) {
        self.rootNodeId = rootNodeId
        self.rootName = rootName
        self.rootType = rootType
        self.screens = screens
        self.taggedAssets = taggedAssets
        self.lottiePlaceholders = lottiePlaceholders
        self.warnings = warnings
    }
}

public struct RegistryBuilder: Sendable {
    private static let containerTypes: Set<String> = ["CANVAS", "PAGE", "DOCUMENT"]
    private static let frameTypes: Set<String> = ["FRAME", "COMPONENT", "COMPONENT_SET", "INSTANCE"]
    /// Screen size heuristic: any FRAME within iPhone SE (320pt) to iPad mini (~1024pt) range.
    private static let screenWidthRange: ClosedRange<Double> = 320...1024

    private let scanner: AssetScanner

    public init(scanner: AssetScanner = AssetScanner()) {
        self.scanner = scanner
    }

    public func build(rootNode: FigmaNode) -> Registry {
        let scanResult = scanner.scan(rootNode)
        let lottie = scanResult.animations.map {
            LottiePlaceholder(
                nodeId: $0.nodeId,
                figmaName: $0.figmaName,
                width: $0.width,
                height: $0.height
            )
        }
        let screens = detectScreens(from: rootNode)

        return Registry(
            rootNodeId: rootNode.id,
            rootName: rootNode.name,
            rootType: rootNode.type,
            screens: screens,
            taggedAssets: scanResult.matches,
            lottiePlaceholders: lottie,
            warnings: scanResult.warnings
        )
    }

    // MARK: - Screen detection
    // Goal: enumerate FRAME-like nodes that look like iOS screens. For multi-screen flow.
    // Single-screen call (root is a FRAME) → screens = [root].
    // Container call (root is CANVAS/PAGE/DOCUMENT) → screens = direct frame-typed children
    //   whose width falls in iOS device range.
    // Nested DOCUMENT → recurse one level into CANVAS/PAGE children.
    private func detectScreens(from root: FigmaNode) -> [ScreenInfo] {
        if Self.frameTypes.contains(root.type) {
            return [Self.makeScreenInfo(from: root)]
        }
        if Self.containerTypes.contains(root.type) {
            return collectScreens(from: root)
        }
        return []
    }

    private func collectScreens(from container: FigmaNode) -> [ScreenInfo] {
        var screens: [ScreenInfo] = []
        for child in container.children ?? [] {
            if Self.frameTypes.contains(child.type),
               let box = child.absoluteBoundingBox,
               Self.screenWidthRange.contains(box.width) {
                screens.append(Self.makeScreenInfo(from: child))
            } else if Self.containerTypes.contains(child.type) {
                // DOCUMENT → list of CANVAS pages → recurse one level
                screens.append(contentsOf: collectScreens(from: child))
            }
        }
        return screens
    }

    private static func makeScreenInfo(from node: FigmaNode) -> ScreenInfo {
        ScreenInfo(
            nodeId: node.id,
            name: node.name,
            type: node.type,
            width: node.absoluteBoundingBox?.width,
            height: node.absoluteBoundingBox?.height
        )
    }
}
