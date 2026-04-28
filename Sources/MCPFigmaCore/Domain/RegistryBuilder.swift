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
    private static let lottiePrefix = "eAnim"
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

        var lottie: [LottiePlaceholder] = []
        var lottieWarnings: [ScanWarning] = []
        walkLottie(rootNode, lottie: &lottie, warnings: &lottieWarnings)

        let screens = detectScreens(from: rootNode)

        let mergedWarnings = scanResult.warnings + lottieWarnings

        return Registry(
            rootNodeId: rootNode.id,
            rootName: rootNode.name,
            rootType: rootNode.type,
            screens: screens,
            taggedAssets: scanResult.matches,
            lottiePlaceholders: lottie,
            warnings: mergedWarnings
        )
    }

    // MARK: - Lottie walk
    // Mirrors AssetScanner: stop recursion at every eAnim* node (children are preview keyframes).
    // Validates the same naming rules as eIC*/eImage* (uppercase ASCII first char, [A-Za-z0-9_]).
    private func walkLottie(
        _ node: FigmaNode,
        lottie: inout [LottiePlaceholder],
        warnings: inout [ScanWarning]
    ) {
        let trimmed = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(Self.lottiePrefix) {
            let remainder = String(trimmed.dropFirst(Self.lottiePrefix.count))
            if let validation = Self.validate(remainder: remainder) {
                warnings.append(ScanWarning(
                    nodeId: node.id,
                    figmaName: node.name,
                    reason: validation
                ))
            } else {
                lottie.append(LottiePlaceholder(
                    nodeId: node.id,
                    figmaName: node.name,
                    width: node.absoluteBoundingBox?.width,
                    height: node.absoluteBoundingBox?.height
                ))
            }
            return
        }
        for child in node.children ?? [] {
            walkLottie(child, lottie: &lottie, warnings: &warnings)
        }
    }

    private static func validate(remainder: String) -> String? {
        guard let first = remainder.first else {
            return "Tên eAnim thiếu phần tên — phải có ít nhất 1 ký tự sau prefix"
        }
        guard first.isASCII, first.isUppercase else {
            return "Tên '\(remainder)' không hợp lệ — ký tự đầu sau prefix phải là chữ ASCII viết hoa"
        }
        for c in remainder {
            guard c.isASCII, c.isLetter || c.isNumber || c == "_" else {
                return "Tên 'eAnim\(remainder)' chứa ký tự không cho phép — chỉ cho phép [A-Za-z0-9_]"
            }
        }
        return nil
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
