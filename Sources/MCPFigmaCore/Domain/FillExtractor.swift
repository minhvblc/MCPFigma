import Foundation

// MARK: - Output types

public struct FillsResult: Equatable, Sendable {
    public let nodes: [NodeFills]
    public let warnings: [String]

    public init(nodes: [NodeFills], warnings: [String]) {
        self.nodes = nodes
        self.warnings = warnings
    }
}

public struct NodeFills: Equatable, Sendable {
    public let nodeId: String
    public let nodeName: String
    public let nodeType: String
    public let width: Double?
    public let height: Double?
    public let fills: [FillSpec]

    public init(
        nodeId: String,
        nodeName: String,
        nodeType: String,
        width: Double?,
        height: Double?,
        fills: [FillSpec]
    ) {
        self.nodeId = nodeId
        self.nodeName = nodeName
        self.nodeType = nodeType
        self.width = width
        self.height = height
        self.fills = fills
    }
}

public enum FillSpec: Equatable, Sendable {
    case solid(SolidFill)
    case gradient(GradientFill)
    case image(ImageFill)
    case unsupported(rawType: String, opacity: Double, visible: Bool)
}

public struct SolidFill: Equatable, Sendable {
    public let hex: String          // #RRGGBB or #RRGGBBAA when color-alpha != 1
    public let opacity: Double      // paint-level opacity, distinct from color alpha
    public let visible: Bool
    public let blendMode: String?   // omitted when "NORMAL"
}

public struct GradientFill: Equatable, Sendable {
    public enum Kind: String, Sendable { case linear, radial, angular, diamond }
    public let kind: Kind
    public let stops: [GradientStopSpec]
    public let startPoint: NormalizedPoint
    public let endPoint: NormalizedPoint
    public let widthPoint: NormalizedPoint?  // radial/angular only
    public let opacity: Double
    public let visible: Bool
    public let blendMode: String?
}

public struct GradientStopSpec: Equatable, Sendable {
    public let position: Double  // 0..1
    public let hex: String       // includes alpha when color-alpha != 1
}

public struct NormalizedPoint: Equatable, Sendable {
    public let x: Double  // 0..1 in fill's bounding box (Figma convention)
    public let y: Double
}

public struct ImageFill: Equatable, Sendable {
    public let imageRef: String
    public let scaleMode: String     // FILL | FIT | TILE | STRETCH | CROP
    public let opacity: Double
    public let visible: Bool
    public let blendMode: String?
    public let imageUrl: String?     // resolved from /v1/files/<key>/images, optional
}

// MARK: - Extractor

/// Walks each provided node (and its descendants) and pulls "interesting" fills.
///
/// Interesting = anything beyond a single 100%-opacity SOLID — i.e. exactly the
/// cases the skill historically fumbled (background image, gradient overlay, the
/// image+gradient stack on hero cards). Plain solids are filtered out because
/// design-context.md + tokens.json already cover them.
public struct FillExtractor: Sendable {
    public init() {}

    public func extract(
        nodes: [String: FigmaNode],
        imageRefURLs: [String: String]
    ) -> FillsResult {
        var output: [NodeFills] = []
        var warnings: [String] = []
        for nodeId in nodes.keys.sorted() {
            guard let root = nodes[nodeId] else { continue }
            walk(root, output: &output, warnings: &warnings, imageRefURLs: imageRefURLs)
        }
        return FillsResult(nodes: output, warnings: warnings)
    }

    private func walk(
        _ node: FigmaNode,
        output: inout [NodeFills],
        warnings: inout [String],
        imageRefURLs: [String: String]
    ) {
        let specs = (node.fills ?? []).compactMap {
            translate(
                paint: $0,
                imageRefURLs: imageRefURLs,
                nodeName: node.name,
                warnings: &warnings
            )
        }
        if interesting(specs) {
            output.append(NodeFills(
                nodeId: node.id,
                nodeName: node.name,
                nodeType: node.type,
                width: node.absoluteBoundingBox?.width,
                height: node.absoluteBoundingBox?.height,
                fills: specs
            ))
        }
        for child in node.children ?? [] {
            walk(child, output: &output, warnings: &warnings, imageRefURLs: imageRefURLs)
        }
    }

    /// Single-SOLID 100%-opacity fills are dropped — the skill already handles those
    /// from tokens.json / design-context.md. Anything stacked, gradient, image, or
    /// blended is kept.
    private func interesting(_ specs: [FillSpec]) -> Bool {
        let visible = specs.filter { isVisible($0) }
        if visible.isEmpty { return false }
        if visible.count > 1 { return true }
        switch visible[0] {
        case .gradient, .image, .unsupported:
            return true
        case .solid(let s):
            let blended = s.blendMode != nil && s.blendMode != "NORMAL"
            let translucent = s.opacity < 0.999
            return blended || translucent
        }
    }

    private func isVisible(_ spec: FillSpec) -> Bool {
        switch spec {
        case .solid(let s):  return s.visible
        case .gradient(let g): return g.visible
        case .image(let i):  return i.visible
        case .unsupported(_, _, let visible): return visible
        }
    }

    private func translate(
        paint: FigmaPaint,
        imageRefURLs: [String: String],
        nodeName: String,
        warnings: inout [String]
    ) -> FillSpec? {
        let visible = paint.visible ?? true
        let opacity = paint.opacity ?? 1.0
        let blendMode = (paint.blendMode == "NORMAL") ? nil : paint.blendMode

        switch paint.type {
        case "SOLID":
            guard let color = paint.color else { return nil }
            return .solid(SolidFill(
                hex: TokenExtractor.hexFromRGBA(r: color.r, g: color.g, b: color.b, a: color.a),
                opacity: opacity,
                visible: visible,
                blendMode: blendMode
            ))

        case "GRADIENT_LINEAR", "GRADIENT_RADIAL", "GRADIENT_ANGULAR", "GRADIENT_DIAMOND":
            let kind: GradientFill.Kind
            switch paint.type {
            case "GRADIENT_LINEAR":  kind = .linear
            case "GRADIENT_RADIAL":  kind = .radial
            case "GRADIENT_ANGULAR": kind = .angular
            default:                 kind = .diamond
            }
            let stops = (paint.gradientStops ?? []).map {
                GradientStopSpec(
                    position: $0.position,
                    hex: TokenExtractor.hexFromRGBA(r: $0.color.r, g: $0.color.g, b: $0.color.b, a: $0.color.a)
                )
            }
            let handles = paint.gradientHandlePositions ?? []
            guard handles.count >= 2 else {
                warnings.append("Gradient on '\(nodeName)' missing gradientHandlePositions; cannot determine direction.")
                return nil
            }
            return .gradient(GradientFill(
                kind: kind,
                stops: stops,
                startPoint: NormalizedPoint(x: handles[0].x, y: handles[0].y),
                endPoint: NormalizedPoint(x: handles[1].x, y: handles[1].y),
                widthPoint: handles.count >= 3 ? NormalizedPoint(x: handles[2].x, y: handles[2].y) : nil,
                opacity: opacity,
                visible: visible,
                blendMode: blendMode
            ))

        case "IMAGE":
            guard let imageRef = paint.imageRef, !imageRef.isEmpty else {
                warnings.append("IMAGE fill on '\(nodeName)' missing imageRef.")
                return nil
            }
            let normalizedScale = (paint.scaleMode ?? "FILL").uppercased()
            return .image(ImageFill(
                imageRef: imageRef,
                scaleMode: normalizedScale,
                opacity: opacity,
                visible: visible,
                blendMode: blendMode,
                imageUrl: imageRefURLs[imageRef]
            ))

        default:
            return .unsupported(rawType: paint.type, opacity: opacity, visible: visible)
        }
    }
}
