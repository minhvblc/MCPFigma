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
            // Use rewriteFlexible so case-typos like `EICHome` / `eichome` get
            // recovered and emit a warning (rather than silently dropping the
            // asset from the registry → xcassets → Swift binding chain).
            let result = try rewriter.rewriteFlexible(node.name)
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
            // Surface case-mismatch as a warning so the designer renames the
            // Figma layer to canonical form. The asset is still exported under
            // the canonical name — no functional regression.
            if result.prefixCaseMismatch, let original = result.originalPrefix {
                let canonical = Self.canonicalPrefix(for: result.kind)
                warnings.append(ScanWarning(
                    nodeId: node.id,
                    figmaName: node.name,
                    reason: "Prefix '\(original)' does not match canonical '\(canonical)' — exported as '\(result.renamed)'. Rename Figma layer to start with '\(canonical)'."
                ))
            }
            // All three prefixes stop descent.
            return
        } catch RewriteError.notExportable {
            // No prefix. Untagged node — auto-export it when it is a graphic
            // leaf (no children, a VECTOR or an IMAGE-filled node). Otherwise
            // fall through to descend into children, exactly as before.
            if Self.isUntaggedExportableLeaf(node) {
                appendUntaggedLeaf(node, matches: &matches, warnings: &warnings)
                return
            }
        } catch let error as RewriteError {
            // Prefix matched but remainder couldn't be salvaged (illegal chars
            // or bare prefix). Warn + stop descent: the prefix is a clear tag,
            // so we treat the node as terminal rather than recursing past it.
            warnings.append(ScanWarning(
                nodeId: node.id,
                figmaName: node.name,
                reason: Self.reason(for: error)
            ))
            return
        } catch {
            warnings.append(ScanWarning(
                nodeId: node.id,
                figmaName: node.name,
                reason: "Unexpected rewrite error: \(error)"
            ))
            return
        }

        guard let children = node.children else { return }
        for child in children {
            walk(child, matches: &matches, animations: &animations, warnings: &warnings)
        }
    }

    /// An untagged node qualifies for auto-export only when it is a *leaf*
    /// (no children — a container is still descended into) AND it renders as a
    /// graphic: a `VECTOR`, or any node carrying a visible IMAGE fill. Plain
    /// frames, groups and text nodes are skipped.
    private static func isUntaggedExportableLeaf(_ node: FigmaNode) -> Bool {
        guard (node.children ?? []).isEmpty else { return false }
        return node.type == "VECTOR" || hasImageFill(node)
    }

    private static func hasImageFill(_ node: FigmaNode) -> Bool {
        guard let fills = node.fills else { return false }
        return fills.contains { $0.type == "IMAGE" && ($0.visible ?? true) }
    }

    /// Builds a FoundAsset for an untagged graphic leaf. An IMAGE-filled node
    /// is classified `.image`; a bare VECTOR is `.icon`. The asset name is
    /// derived from the layer name via `AssetNameRewriter.rewriteUntagged` — an
    /// unusable layer name yields a warning instead of a broken asset.
    private func appendUntaggedLeaf(
        _ node: FigmaNode,
        matches: inout [FoundAsset],
        warnings: inout [ScanWarning]
    ) {
        let kind: AssetKind = Self.hasImageFill(node) ? .image : .icon
        let width = node.absoluteBoundingBox?.width
        let height = node.absoluteBoundingBox?.height
        do {
            let base = try rewriter.rewriteUntagged(node.name, kind: kind)
            let renamed = AssetNameRewriter.appendSizeSuffix(
                renamed: base,
                width: width,
                height: height
            )
            matches.append(FoundAsset(
                nodeId: node.id,
                figmaName: node.name,
                kind: kind,
                renamed: renamed,
                width: width,
                height: height
            ))
        } catch {
            warnings.append(ScanWarning(
                nodeId: node.id,
                figmaName: node.name,
                reason: "Untagged leaf '\(node.name)' không tạo được tên iOS hợp lệ — bỏ qua. Đặt lại tên layer cho rõ hoặc gắn prefix eIC/eImage."
            ))
        }
    }

    private static func canonicalPrefix(for kind: AssetKind) -> String {
        switch kind {
        case .icon:      return "eIC"
        case .image:     return "eImage"
        case .animation: return "eAnim"
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
