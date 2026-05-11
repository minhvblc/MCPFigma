import Foundation

public struct FigmaBoundingBox: Decodable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct FigmaNode: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let absoluteBoundingBox: FigmaBoundingBox?
    public let children: [FigmaNode]?
    public let style: FigmaTypeStyle?
    public let fills: [FigmaPaint]?

    public init(
        id: String,
        name: String,
        type: String,
        absoluteBoundingBox: FigmaBoundingBox? = nil,
        children: [FigmaNode]? = nil,
        style: FigmaTypeStyle? = nil,
        fills: [FigmaPaint]? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.absoluteBoundingBox = absoluteBoundingBox
        self.children = children
        self.style = style
        self.fills = fills
    }
}

// MARK: - Paint (fills)

/// One entry of a Figma node's `fills` array. Figma stores layered fills on a single
/// node — a typical hero card has [IMAGE, GRADIENT_LINEAR] so the gradient sits on
/// top of the image. We decode the union loosely (every field optional) and let the
/// FillExtractor branch on `type`.
public struct FigmaPaint: Decodable, Equatable, Sendable {
    public let type: String              // SOLID | GRADIENT_LINEAR | GRADIENT_RADIAL | GRADIENT_ANGULAR | GRADIENT_DIAMOND | IMAGE | EMOJI | VIDEO
    public let visible: Bool?            // nil → treat as true
    public let opacity: Double?          // paint-level opacity 0..1, nil → 1
    public let blendMode: String?        // nil or "NORMAL" → no blend
    public let color: FigmaColor?        // SOLID
    public let gradientStops: [FigmaColorStop]?       // GRADIENT_*
    public let gradientHandlePositions: [FigmaVector2D]?  // GRADIENT_* — [start, end, width-control]
    public let imageRef: String?         // IMAGE
    public let scaleMode: String?        // IMAGE — FILL | FIT | TILE | STRETCH | CROP
    public let imageTransform: [[Double]]?  // IMAGE — 2x3 affine, identity by default
    public let scalingFactor: Double?    // IMAGE FILL with manual crop adjust
    public let rotation: Double?         // IMAGE — degrees

    public init(
        type: String,
        visible: Bool? = nil,
        opacity: Double? = nil,
        blendMode: String? = nil,
        color: FigmaColor? = nil,
        gradientStops: [FigmaColorStop]? = nil,
        gradientHandlePositions: [FigmaVector2D]? = nil,
        imageRef: String? = nil,
        scaleMode: String? = nil,
        imageTransform: [[Double]]? = nil,
        scalingFactor: Double? = nil,
        rotation: Double? = nil
    ) {
        self.type = type
        self.visible = visible
        self.opacity = opacity
        self.blendMode = blendMode
        self.color = color
        self.gradientStops = gradientStops
        self.gradientHandlePositions = gradientHandlePositions
        self.imageRef = imageRef
        self.scaleMode = scaleMode
        self.imageTransform = imageTransform
        self.scalingFactor = scalingFactor
        self.rotation = rotation
    }
}

public struct FigmaColor: Decodable, Equatable, Sendable {
    public let r: Double  // 0..1
    public let g: Double
    public let b: Double
    public let a: Double  // 0..1

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

public struct FigmaVector2D: Decodable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x; self.y = y
    }
}

public struct FigmaColorStop: Decodable, Equatable, Sendable {
    public let position: Double  // 0..1
    public let color: FigmaColor

    public init(position: Double, color: FigmaColor) {
        self.position = position
        self.color = color
    }
}

// MARK: - File images (imageRef → CDN URL)

/// Response from `/v1/files/<key>/images` — a flat map of every imageRef in the file
/// to its rendered CDN URL. Resolves the `imageRef` returned in IMAGE paint fills.
public struct FigmaFileImagesResponse: Decodable, Sendable {
    public let error: Bool?
    public let status: Int?
    public let meta: Meta?

    public struct Meta: Decodable, Sendable {
        public let images: [String: String]
        public init(images: [String: String]) { self.images = images }
    }

    public init(error: Bool?, status: Int?, meta: Meta?) {
        self.error = error
        self.status = status
        self.meta = meta
    }
}

/// Subset of Figma TypeStyle fields needed to reproduce typography in SwiftUI.
/// Figma may return additional keys (`fontFamily`, `fontPostScriptName`, etc.);
/// we decode the SwiftUI-relevant ones and tolerate the rest.
public struct FigmaTypeStyle: Decodable, Equatable, Sendable {
    public let fontFamily: String?
    public let fontPostScriptName: String?
    public let fontWeight: Double?
    public let fontSize: Double?
    public let lineHeightPx: Double?
    public let lineHeightPercent: Double?
    public let lineHeightUnit: String?
    public let letterSpacing: Double?
    public let textCase: String?
    public let textAlignHorizontal: String?
    public let italic: Bool?

    public init(
        fontFamily: String? = nil,
        fontPostScriptName: String? = nil,
        fontWeight: Double? = nil,
        fontSize: Double? = nil,
        lineHeightPx: Double? = nil,
        lineHeightPercent: Double? = nil,
        lineHeightUnit: String? = nil,
        letterSpacing: Double? = nil,
        textCase: String? = nil,
        textAlignHorizontal: String? = nil,
        italic: Bool? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontPostScriptName = fontPostScriptName
        self.fontWeight = fontWeight
        self.fontSize = fontSize
        self.lineHeightPx = lineHeightPx
        self.lineHeightPercent = lineHeightPercent
        self.lineHeightUnit = lineHeightUnit
        self.letterSpacing = letterSpacing
        self.textCase = textCase
        self.textAlignHorizontal = textAlignHorizontal
        self.italic = italic
    }
}

public struct FigmaFileNodesResponse: Decodable, Sendable {
    public struct NodeWrapper: Decodable, Sendable {
        public let document: FigmaNode
        public init(document: FigmaNode) { self.document = document }
    }
    public let name: String
    public let nodes: [String: NodeWrapper]

    public init(name: String, nodes: [String: NodeWrapper]) {
        self.name = name
        self.nodes = nodes
    }
}

public struct FigmaImagesResponse: Decodable, Sendable {
    public let err: String?
    public let images: [String: String?]
}

// MARK: - File styles (text styles, fill styles, effect styles)

public struct FigmaStylesResponse: Decodable, Sendable {
    public let status: Int?
    public let error: Bool?
    public let message: String?
    public let meta: Meta?

    public init(status: Int?, error: Bool?, message: String?, meta: Meta?) {
        self.status = status
        self.error = error
        self.message = message
        self.meta = meta
    }

    public struct Meta: Decodable, Sendable {
        public let styles: [FigmaStyleSummary]
        public init(styles: [FigmaStyleSummary]) { self.styles = styles }
    }
}

public struct FigmaStyleSummary: Decodable, Equatable, Sendable {
    public let key: String
    public let nodeId: String
    public let name: String
    public let styleType: String
    public let description: String?

    enum CodingKeys: String, CodingKey {
        case key, name, description
        case nodeId = "node_id"
        case styleType = "style_type"
    }

    public init(key: String, nodeId: String, name: String, styleType: String, description: String? = nil) {
        self.key = key
        self.nodeId = nodeId
        self.name = name
        self.styleType = styleType
        self.description = description
    }
}

// MARK: - Variables (Figma local variables API)

public struct FigmaVariablesResponse: Decodable, Sendable {
    public let status: Int?
    public let error: Bool?
    public let message: String?
    public let meta: Meta?

    public init(status: Int?, error: Bool?, message: String?, meta: Meta?) {
        self.status = status
        self.error = error
        self.message = message
        self.meta = meta
    }

    public struct Meta: Decodable, Sendable {
        public let variables: [String: FigmaVariable]
        public let variableCollections: [String: FigmaVariableCollection]

        public init(
            variables: [String: FigmaVariable],
            variableCollections: [String: FigmaVariableCollection]
        ) {
            self.variables = variables
            self.variableCollections = variableCollections
        }
    }
}

public struct FigmaVariable: Decodable, Sendable {
    public let id: String
    public let name: String
    public let resolvedType: String
    public let variableCollectionId: String
    public let valuesByMode: [String: FigmaVariableValue]
    public let scopes: [String]?

    public init(
        id: String,
        name: String,
        resolvedType: String,
        variableCollectionId: String,
        valuesByMode: [String: FigmaVariableValue],
        scopes: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.resolvedType = resolvedType
        self.variableCollectionId = variableCollectionId
        self.valuesByMode = valuesByMode
        self.scopes = scopes
    }
}

public struct FigmaVariableCollection: Decodable, Sendable {
    public let id: String
    public let name: String
    public let modes: [Mode]
    public let defaultModeId: String

    public struct Mode: Decodable, Sendable {
        public let modeId: String
        public let name: String
    }

    public init(id: String, name: String, modes: [Mode], defaultModeId: String) {
        self.id = id
        self.name = name
        self.modes = modes
        self.defaultModeId = defaultModeId
    }
}

/// Figma variable values can be a number, string, bool, color, or alias.
public enum FigmaVariableValue: Decodable, Sendable, Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case color(r: Double, g: Double, b: Double, a: Double)
    case alias(variableId: String)
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let n = try? container.decode(Double.self) {
            self = .number(n); return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s); return
        }
        if let b = try? container.decode(Bool.self) {
            self = .bool(b); return
        }
        if let dict = try? container.decode([String: AnyDecodable].self) {
            // Color: { r, g, b, a }
            if let r = dict["r"]?.doubleValue,
               let g = dict["g"]?.doubleValue,
               let b = dict["b"]?.doubleValue {
                let a = dict["a"]?.doubleValue ?? 1.0
                self = .color(r: r, g: g, b: b, a: a)
                return
            }
            // Alias: { type: "VARIABLE_ALIAS", id: "..." }
            if let type = dict["type"]?.stringValue, type == "VARIABLE_ALIAS",
               let id = dict["id"]?.stringValue {
                self = .alias(variableId: id)
                return
            }
        }
        self = .unknown
    }
}

/// Minimal heterogeneous JSON decoder used to peek into Figma variable values.
struct AnyDecodable: Decodable, Sendable {
    let raw: RawValue

    enum RawValue: Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
    }

    var stringValue: String? {
        if case let .string(s) = raw { return s }
        return nil
    }
    var doubleValue: Double? {
        if case let .number(n) = raw { return n }
        return nil
    }
    var boolValue: Bool? {
        if case let .bool(b) = raw { return b }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { raw = .null; return }
        if let n = try? container.decode(Double.self) { raw = .number(n); return }
        if let b = try? container.decode(Bool.self) { raw = .bool(b); return }
        if let s = try? container.decode(String.self) { raw = .string(s); return }
        raw = .null
    }
}
