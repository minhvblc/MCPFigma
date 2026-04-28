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

    public init(
        id: String,
        name: String,
        type: String,
        absoluteBoundingBox: FigmaBoundingBox? = nil,
        children: [FigmaNode]? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.absoluteBoundingBox = absoluteBoundingBox
        self.children = children
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
