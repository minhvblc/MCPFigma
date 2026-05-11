import Foundation

public struct ScreenInfo: Equatable, Sendable {
    public let nodeId: String
    public let name: String
    public let type: String
    public let width: Double?
    public let height: Double?
    /// Depth from root in the node tree. 0 = root itself; ≥1 = nested descendants
    /// surfaced as `candidateScreens` when the root is a non-container Group.
    public let depth: Int

    public init(nodeId: String, name: String, type: String, width: Double?, height: Double?, depth: Int = 0) {
        self.nodeId = nodeId
        self.name = name
        self.type = type
        self.width = width
        self.height = height
        self.depth = depth
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
    /// Direct screens. Populated when root is a FRAME (single-screen call) or a
    /// CANVAS/PAGE/DOCUMENT (multi-screen flow). Empty when root is a Group.
    public let screens: [ScreenInfo]
    /// Candidate screens — phone-sized FRAME nodes found nested under a Group
    /// root. P0-1 fix: surface them as recoverable input so the caller doesn't
    /// silently end up with `screens: []` when working off a Group root.
    public let candidateScreens: [ScreenInfo]
    public let taggedAssets: [FoundAsset]
    public let lottiePlaceholders: [LottiePlaceholder]
    public let warnings: [ScanWarning]

    public init(
        rootNodeId: String,
        rootName: String,
        rootType: String,
        screens: [ScreenInfo],
        candidateScreens: [ScreenInfo] = [],
        taggedAssets: [FoundAsset],
        lottiePlaceholders: [LottiePlaceholder],
        warnings: [ScanWarning]
    ) {
        self.rootNodeId = rootNodeId
        self.rootName = rootName
        self.rootType = rootType
        self.screens = screens
        self.candidateScreens = candidateScreens
        self.taggedAssets = taggedAssets
        self.lottiePlaceholders = lottiePlaceholders
        self.warnings = warnings
    }
}

public struct RegistryBuilder: Sendable {
    private static let containerTypes: Set<String> = ["CANVAS", "PAGE", "DOCUMENT"]
    private static let frameTypes: Set<String> = ["FRAME", "COMPONENT", "COMPONENT_SET", "INSTANCE"]
    /// Group-like nodes that often wrap a flow-board on the canvas. Not real
    /// containers (CANVAS/PAGE/DOCUMENT) — but a designer may rectangle-select
    /// 40 screens and group them, then share that Group's link. We treat this
    /// case explicitly via candidate-screen discovery.
    private static let groupLikeTypes: Set<String> = ["GROUP", "SECTION"]
    /// Screen size heuristic: any FRAME within iPhone SE (320pt) to iPad mini (~1024pt) range.
    private static let screenWidthRange: ClosedRange<Double> = 320...1024
    /// Minimum height to qualify as a screen (vs a chip/banner inside a group).
    /// iPhone SE landscape is 320×568; portrait iPad mini is 768×1024. Anything
    /// shorter than 480pt at our width range is almost certainly a UI component.
    private static let minScreenHeight: Double = 480
    /// Max recursion depth for candidate-screen discovery inside a Group root.
    /// Most flow boards bury frames 2–3 levels deep (group > row > screen).
    /// Cap at 6 to keep cost bounded on pathological files.
    private static let maxCandidateDepth: Int = 6

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

        // P0-1: when direct screen detection yields nothing AND root isn't a
        // single FRAME (which would have been returned as the lone screen),
        // search nested children for phone-sized frames and surface them as
        // candidateScreens. Add a warning so callers know which array to read.
        var candidates: [ScreenInfo] = []
        var extraWarnings: [ScanWarning] = []
        if screens.isEmpty && !Self.frameTypes.contains(rootNode.type) {
            candidates = collectCandidateScreens(from: rootNode, depth: 0)
            if !candidates.isEmpty {
                let reason: String
                if Self.groupLikeTypes.contains(rootNode.type) {
                    reason = "ROOT_IS_GROUP: root node \(rootNode.id) is a \(rootNode.type), not a Board/Frame. " +
                            "Found \(candidates.count) phone-sized FRAME nodes nested at depth ≤ \(Self.maxCandidateDepth). " +
                            "Use these nodeIds as input to figma_export_assets_unified(autoDiscover: true) per screen, " +
                            "OR re-root build_registry on a CANVAS/PAGE ancestor."
                } else {
                    reason = "NO_DIRECT_SCREENS: root node \(rootNode.id) (\(rootNode.type)) has no direct FRAME screens. " +
                            "Found \(candidates.count) candidate phone-sized FRAMEs nested at depth ≤ \(Self.maxCandidateDepth)."
                }
                extraWarnings.append(ScanWarning(
                    nodeId: rootNode.id,
                    figmaName: rootNode.name,
                    reason: reason
                ))
            }
        }

        return Registry(
            rootNodeId: rootNode.id,
            rootName: rootNode.name,
            rootType: rootNode.type,
            screens: screens,
            candidateScreens: candidates,
            taggedAssets: scanResult.matches,
            lottiePlaceholders: lottie,
            warnings: scanResult.warnings + extraWarnings
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
            return [Self.makeScreenInfo(from: root, depth: 0)]
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
                screens.append(Self.makeScreenInfo(from: child, depth: 1))
            } else if Self.containerTypes.contains(child.type) {
                // DOCUMENT → list of CANVAS pages → recurse one level
                screens.append(contentsOf: collectScreens(from: child))
            }
        }
        return screens
    }

    /// Recursive descent under a non-container root (typically GROUP) looking
    /// for phone-sized FRAME nodes. Bounded by `maxCandidateDepth` to keep cost
    /// proportional to flow size on real designs (~3 levels for most projects).
    private func collectCandidateScreens(from node: FigmaNode, depth: Int) -> [ScreenInfo] {
        guard depth <= Self.maxCandidateDepth else { return [] }
        var out: [ScreenInfo] = []
        for child in node.children ?? [] {
            let childDepth = depth + 1
            if Self.frameTypes.contains(child.type),
               let box = child.absoluteBoundingBox,
               Self.screenWidthRange.contains(box.width),
               box.height >= Self.minScreenHeight {
                out.append(Self.makeScreenInfo(from: child, depth: childDepth))
                // Don't descend into a confirmed screen — its inner frames are
                // sections/components, not standalone screens.
                continue
            }
            // Group/Section/etc — recurse into children
            out.append(contentsOf: collectCandidateScreens(from: child, depth: childDepth))
        }
        return out
    }

    private static func makeScreenInfo(from node: FigmaNode, depth: Int) -> ScreenInfo {
        ScreenInfo(
            nodeId: node.id,
            name: node.name,
            type: node.type,
            width: node.absoluteBoundingBox?.width,
            height: node.absoluteBoundingBox?.height,
            depth: depth
        )
    }
}
