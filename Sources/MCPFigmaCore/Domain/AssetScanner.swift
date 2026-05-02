import Foundation

public struct FoundAsset: Equatable, Sendable {
    public let nodeId: String
    public let figmaName: String
    public let kind: AssetKind
    public let renamed: String
    public let width: Double?
    public let height: Double?

    public init(
        nodeId: String,
        figmaName: String,
        kind: AssetKind,
        renamed: String,
        width: Double? = nil,
        height: Double? = nil
    ) {
        self.nodeId = nodeId
        self.figmaName = figmaName
        self.kind = kind
        self.renamed = renamed
        self.width = width
        self.height = height
    }
}

public struct ScanWarning: Equatable, Sendable {
    public let nodeId: String
    public let figmaName: String
    public let reason: String

    public init(nodeId: String, figmaName: String, reason: String) {
        self.nodeId = nodeId
        self.figmaName = figmaName
        self.reason = reason
    }
}

public struct ScanResult: Equatable, Sendable {
    /// Downloadable assets (icon + image). Animations are surfaced separately
    /// so callers that render don't have to filter them out.
    public let matches: [FoundAsset]
    /// eAnim* placeholders. Reported but never downloaded.
    public let animations: [FoundAsset]
    public let warnings: [ScanWarning]

    public init(matches: [FoundAsset], animations: [FoundAsset] = [], warnings: [ScanWarning]) {
        self.matches = matches
        self.animations = animations
        self.warnings = warnings
    }
}

public struct AssetScanner: Sendable {
    private let rewriter: AssetNameRewriter

    public init(rewriter: AssetNameRewriter = AssetNameRewriter()) {
        self.rewriter = rewriter
    }

    public func scan(_ root: FigmaNode) -> ScanResult {
        var matches: [FoundAsset] = []
        var animations: [FoundAsset] = []
        var warnings: [ScanWarning] = []
        walk(root, matches: &matches, animations: &animations, warnings: &warnings)
        return ScanResult(matches: matches, animations: animations, warnings: warnings)
    }

    private func walk(
        _ node: FigmaNode,
        matches: inout [FoundAsset],
        animations: inout [FoundAsset],
        warnings: inout [ScanWarning]
    ) {
        do {
            let result = try rewriter.rewrite(node.name)
            let width = node.absoluteBoundingBox?.width
            let height = node.absoluteBoundingBox?.height
            switch result.kind {
            case .icon, .image:
                let renamed = AssetNameRewriter.appendSizeSuffix(
                    renamed: result.renamed,
                    width: width,
                    height: height
                )
                matches.append(FoundAsset(
                    nodeId: node.id,
                    figmaName: node.name,
                    kind: result.kind,
                    renamed: renamed,
                    width: width,
                    height: height
                ))
            case .animation:
                animations.append(FoundAsset(
                    nodeId: node.id,
                    figmaName: node.name,
                    kind: .animation,
                    renamed: result.renamed,
                    width: width,
                    height: height
                ))
            }
            // All three prefixes stop descent.
            return
        } catch RewriteError.notExportable {
        } catch let error as RewriteError {
            warnings.append(ScanWarning(
                nodeId: node.id,
                figmaName: node.name,
                reason: Self.reason(for: error)
            ))
        } catch {
            warnings.append(ScanWarning(
                nodeId: node.id,
                figmaName: node.name,
                reason: "Unexpected rewrite error: \(error)"
            ))
        }

        guard let children = node.children else { return }
        for child in children {
            walk(child, matches: &matches, animations: &animations, warnings: &warnings)
        }
    }

    private static func reason(for error: RewriteError) -> String {
        switch error {
        case .invalidName(let name):
            return "Tên '\(name)' không hợp lệ — ký tự đầu sau prefix phải là chữ ASCII viết hoa"
        case .containsIllegalChars(let name):
            return "Tên '\(name)' chứa ký tự không cho phép — chỉ cho phép [A-Za-z0-9_]"
        case .notExportable(let name):
            return "Tên '\(name)' không có prefix eIC/eImage/eAnim"
        }
    }
}
