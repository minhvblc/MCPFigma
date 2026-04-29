import Foundation

// MARK: - Output types

public struct ColorToken: Equatable, Sendable {
    public let figmaName: String
    public let swiftName: String
    public let lightHex: String?
    public let darkHex: String?

    public init(figmaName: String, swiftName: String, lightHex: String?, darkHex: String?) {
        self.figmaName = figmaName
        self.swiftName = swiftName
        self.lightHex = lightHex
        self.darkHex = darkHex
    }
}

public struct NumberToken: Equatable, Sendable {
    public let figmaName: String
    public let swiftName: String
    public let value: Double
    public let isCapsule: Bool

    public init(figmaName: String, swiftName: String, value: Double, isCapsule: Bool = false) {
        self.figmaName = figmaName
        self.swiftName = swiftName
        self.value = value
        self.isCapsule = isCapsule
    }
}

public enum TokenKind: String, Sendable {
    case color
    case spacing
    case radius
    case opacity
    case stroke
    case other
}

public struct TokenSet: Equatable, Sendable {
    public let colors: [ColorToken]
    public let spacing: [NumberToken]
    public let radius: [NumberToken]
    public let opacity: [NumberToken]
    public let other: [NumberToken]
    public let typography: [TypographyToken]
    public let warnings: [String]

    public init(
        colors: [ColorToken] = [],
        spacing: [NumberToken] = [],
        radius: [NumberToken] = [],
        opacity: [NumberToken] = [],
        other: [NumberToken] = [],
        typography: [TypographyToken] = [],
        warnings: [String] = []
    ) {
        self.colors = colors
        self.spacing = spacing
        self.radius = radius
        self.opacity = opacity
        self.other = other
        self.typography = typography
        self.warnings = warnings
    }
}

// MARK: - Extractor

/// Maps Figma local variables → SwiftUI-friendly tokens.
/// Detects light/dark mode pairs by mode name (`light`/`dark` or `default`/`dark`).
/// Resolves alias values one hop (variable → variable). Doesn't follow longer chains
/// because Figma shouldn't produce them in practice; deeper chains land in `warnings`.
public struct TokenExtractor: Sendable {
    private let mapper: SwiftNameMapper

    public init(mapper: SwiftNameMapper = SwiftNameMapper()) {
        self.mapper = mapper
    }

    public func extract(from response: FigmaVariablesResponse) -> TokenSet {
        guard let meta = response.meta else {
            var warnings: [String] = []
            if response.error == true {
                warnings.append("Figma trả về lỗi khi đọc variables: \(response.message ?? "không rõ")")
            } else {
                warnings.append("Figma file không có local variables, hoặc plan không hỗ trợ Variables API.")
            }
            return TokenSet(warnings: warnings)
        }

        var colors: [ColorToken] = []
        var spacing: [NumberToken] = []
        var radius: [NumberToken] = []
        var opacity: [NumberToken] = []
        var other: [NumberToken] = []
        var warnings: [String] = []

        for variable in meta.variables.values.sorted(by: { $0.name < $1.name }) {
            switch variable.resolvedType {
            case "COLOR":
                if let token = makeColorToken(variable: variable, meta: meta, warnings: &warnings) {
                    colors.append(token)
                }
            case "FLOAT":
                if let token = makeNumberToken(variable: variable, meta: meta, warnings: &warnings) {
                    let kind = classifyNumber(name: variable.name, value: token.value)
                    switch kind {
                    case .spacing: spacing.append(token)
                    case .radius:  radius.append(makeRadius(token))
                    case .opacity: opacity.append(token)
                    case .stroke:  spacing.append(token) // stroke widths group with spacing-like values
                    case .color, .other: other.append(token)
                    }
                }
            case "BOOLEAN", "STRING":
                // Not yet mapped to SwiftUI tokens; ignored on purpose.
                continue
            default:
                continue
            }
        }

        return TokenSet(
            colors: colors,
            spacing: spacing.sorted { $0.value < $1.value },
            radius: radius.sorted { $0.value < $1.value },
            opacity: opacity.sorted { $0.value < $1.value },
            other: other.sorted { $0.swiftName < $1.swiftName },
            warnings: warnings
        )
    }

    // MARK: - Color

    private func makeColorToken(
        variable: FigmaVariable,
        meta: FigmaVariablesResponse.Meta,
        warnings: inout [String]
    ) -> ColorToken? {
        guard let collection = meta.variableCollections[variable.variableCollectionId] else {
            return nil
        }
        let modesByName = collection.modes.reduce(into: [String: String]()) { acc, mode in
            acc[mode.name.lowercased()] = mode.modeId
        }
        let lightModeId = pickMode(modesByName: modesByName, kind: .light, defaultModeId: collection.defaultModeId)
        let darkModeId = pickMode(modesByName: modesByName, kind: .dark, defaultModeId: nil)

        let lightHex = lightModeId.flatMap { resolveColorHex(variable: variable, modeId: $0, meta: meta, depth: 0) }
        let darkHex: String? = {
            guard let darkModeId, darkModeId != lightModeId else { return nil }
            return resolveColorHex(variable: variable, modeId: darkModeId, meta: meta, depth: 0)
        }()

        if lightHex == nil && darkHex == nil {
            warnings.append("Color variable '\(variable.name)' không resolve được sang hex.")
            return nil
        }

        let swiftName = mapper.map(variable.name, style: .joinAll)
        return ColorToken(
            figmaName: variable.name,
            swiftName: swiftName,
            lightHex: lightHex,
            darkHex: darkHex
        )
    }

    private enum ModeKind { case light, dark }

    private func pickMode(
        modesByName: [String: String],
        kind: ModeKind,
        defaultModeId: String?
    ) -> String? {
        switch kind {
        case .light:
            if let id = modesByName["light"] { return id }
            if let id = modesByName["default"] { return id }
            if let id = modesByName["mode 1"] { return id }
            return defaultModeId
        case .dark:
            return modesByName["dark"]
        }
    }

    private func resolveColorHex(
        variable: FigmaVariable,
        modeId: String,
        meta: FigmaVariablesResponse.Meta,
        depth: Int
    ) -> String? {
        guard depth < 4 else { return nil }
        guard let value = variable.valuesByMode[modeId] else { return nil }
        switch value {
        case let .color(r, g, b, a):
            return Self.hexFromRGBA(r: r, g: g, b: b, a: a)
        case let .alias(variableId):
            guard let aliased = meta.variables[variableId] else { return nil }
            return resolveColorHex(variable: aliased, modeId: modeId, meta: meta, depth: depth + 1)
        default:
            return nil
        }
    }

    static func hexFromRGBA(r: Double, g: Double, b: Double, a: Double) -> String {
        let rb = clampByte(r * 255)
        let gb = clampByte(g * 255)
        let bb = clampByte(b * 255)
        let ab = clampByte(a * 255)
        if abs(a - 1.0) < 0.0001 {
            return String(format: "#%02X%02X%02X", rb, gb, bb)
        }
        return String(format: "#%02X%02X%02X%02X", rb, gb, bb, ab)
    }

    private static func clampByte(_ v: Double) -> Int {
        max(0, min(255, Int(v.rounded())))
    }

    // MARK: - Number

    private func makeNumberToken(
        variable: FigmaVariable,
        meta: FigmaVariablesResponse.Meta,
        warnings: inout [String]
    ) -> NumberToken? {
        guard let collection = meta.variableCollections[variable.variableCollectionId] else {
            return nil
        }
        let value = resolveNumberValue(
            variable: variable,
            modeId: collection.defaultModeId,
            meta: meta,
            depth: 0
        )
        guard let value else {
            warnings.append("Number variable '\(variable.name)' không resolve được.")
            return nil
        }
        let style: SwiftNameMapper.Style = mapper.leadingSegment(variable.name)
            .map(Self.shouldDropLeadingSegment) ?? false ? .dropFirstSegment : .joinAll
        let swiftName = mapper.map(variable.name, style: style)
        return NumberToken(figmaName: variable.name, swiftName: swiftName, value: value)
    }

    private func resolveNumberValue(
        variable: FigmaVariable,
        modeId: String,
        meta: FigmaVariablesResponse.Meta,
        depth: Int
    ) -> Double? {
        guard depth < 4 else { return nil }
        guard let value = variable.valuesByMode[modeId] else { return nil }
        switch value {
        case .number(let n): return n
        case .alias(let id):
            guard let aliased = meta.variables[id] else { return nil }
            return resolveNumberValue(
                variable: aliased,
                modeId: modeId,
                meta: meta,
                depth: depth + 1
            )
        default: return nil
        }
    }

    private static func shouldDropLeadingSegment(_ leading: String) -> Bool {
        let lower = leading.lowercased()
        return ["spacing", "space", "radius", "rounded", "opacity"].contains(lower)
    }

    private func classifyNumber(name: String, value: Double) -> TokenKind {
        let lower = name.lowercased()
        if lower.contains("radius") || lower.contains("rounded") || lower.contains("corner") {
            return .radius
        }
        if lower.contains("opacity") || lower.contains("alpha") {
            return .opacity
        }
        if lower.contains("spacing") || lower.contains("space") || lower.contains("gap")
            || lower.contains("padding") || lower.contains("margin") {
            return .spacing
        }
        if lower.contains("stroke") || lower.contains("border") {
            return .stroke
        }
        return .other
    }

    private func makeRadius(_ token: NumberToken) -> NumberToken {
        // Figma convention: 9999 represents pill / capsule.
        let isCapsule = token.value >= 999
        return NumberToken(
            figmaName: token.figmaName,
            swiftName: token.swiftName,
            value: token.value,
            isCapsule: isCapsule
        )
    }
}
