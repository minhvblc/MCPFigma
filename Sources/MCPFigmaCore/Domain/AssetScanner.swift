import Foundation

public struct FoundAsset: Equatable, Sendable {
    public let nodeId: String
    public let figmaName: String
    public let kind: AssetKind
    public let renamed: String

    public init(nodeId: String, figmaName: String, kind: AssetKind, renamed: String) {
        self.nodeId = nodeId
        self.figmaName = figmaName
        self.kind = kind
        self.renamed = renamed
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
    public let matches: [FoundAsset]
    public let warnings: [ScanWarning]

    public init(matches: [FoundAsset], warnings: [ScanWarning]) {
        self.matches = matches
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
        var warnings: [ScanWarning] = []
        walk(root, matches: &matches, warnings: &warnings)
        return ScanResult(matches: matches, warnings: warnings)
    }

    private func walk(
        _ node: FigmaNode,
        matches: inout [FoundAsset],
        warnings: inout [ScanWarning]
    ) {
        do {
            let result = try rewriter.rewrite(node.name)
            matches.append(FoundAsset(
                nodeId: node.id,
                figmaName: node.name,
                kind: result.kind,
                renamed: result.renamed
            ))
            return
        } catch RewriteError.notExportable {
        } catch let error as RewriteError {
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
            walk(child, matches: &matches, warnings: &warnings)
        }
    }

    private static func reason(for error: RewriteError) -> String {
        switch error {
        case .invalidName(let name):
            return "Tên '\(name)' không hợp lệ — ký tự đầu sau prefix phải là chữ ASCII viết hoa"
        case .containsIllegalChars(let name):
            return "Tên '\(name)' chứa ký tự không cho phép — chỉ cho phép [A-Za-z0-9_]"
        case .notExportable(let name):
            return "Tên '\(name)' không có prefix eIC/eImage"
        }
    }
}
