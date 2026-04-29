import Foundation

/// One typography token ready for SwiftUI codegen.
///
/// Carries every field that affects rendered text in iOS — when any of these
/// is missing in Figma, the consumer should warn instead of inventing a value.
public struct TypographyToken: Equatable, Sendable {
    public let figmaName: String
    public let swiftName: String
    public let fontFamily: String?
    public let fontPostScriptName: String?
    public let fontWeight: Int?           // Figma weight is a number 100..900
    public let fontSize: Double?
    public let lineHeightPx: Double?
    public let letterSpacing: Double?
    public let textCase: String?          // "UPPER" | "LOWER" | "TITLE" | "ORIGINAL"
    public let textAlignHorizontal: String?
    public let italic: Bool

    public init(
        figmaName: String,
        swiftName: String,
        fontFamily: String?,
        fontPostScriptName: String?,
        fontWeight: Int?,
        fontSize: Double?,
        lineHeightPx: Double?,
        letterSpacing: Double?,
        textCase: String?,
        textAlignHorizontal: String?,
        italic: Bool
    ) {
        self.figmaName = figmaName
        self.swiftName = swiftName
        self.fontFamily = fontFamily
        self.fontPostScriptName = fontPostScriptName
        self.fontWeight = fontWeight
        self.fontSize = fontSize
        self.lineHeightPx = lineHeightPx
        self.letterSpacing = letterSpacing
        self.textCase = textCase
        self.textAlignHorizontal = textAlignHorizontal
        self.italic = italic
    }
}

/// Builds `TypographyToken[]` from Figma's `/v1/files/<key>/styles` summary
/// plus a `/v1/files/<key>/nodes?ids=…` payload that resolves each text-style
/// node to its `style` (TypeStyle) block.
///
/// Why two endpoints: `/styles` gives names + node IDs but no styling values.
/// `/nodes` returns the full node tree where text nodes carry the TypeStyle.
/// We batch the IDs into a single nodes call so cost is one round trip.
public struct TextStyleExtractor: Sendable {
    private let mapper: SwiftNameMapper

    public init(mapper: SwiftNameMapper = SwiftNameMapper()) {
        self.mapper = mapper
    }

    public struct Result: Equatable, Sendable {
        public let typography: [TypographyToken]
        public let warnings: [String]

        public init(typography: [TypographyToken] = [], warnings: [String] = []) {
            self.typography = typography
            self.warnings = warnings
        }
    }

    /// `stylesResponse` may be missing (file has no shared styles, or the
    /// Figma plan blocks the styles endpoint). In that case return empty
    /// typography with a single warning rather than failing the whole token
    /// extraction.
    public func extract(
        styles stylesResponse: FigmaStylesResponse?,
        nodes nodesResponse: FigmaFileNodesResponse?
    ) -> Result {
        guard let stylesResponse else {
            return Result(warnings: ["Không gọi được /styles — typography bỏ qua."])
        }
        if stylesResponse.error == true {
            return Result(warnings: [
                "Figma /styles trả lỗi: \(stylesResponse.message ?? "không rõ")."
            ])
        }
        guard let textStyles = stylesResponse.meta?.styles
                .filter({ $0.styleType == "TEXT" })
                .filter({ !$0.nodeId.isEmpty }), !textStyles.isEmpty else {
            return Result()
        }
        guard let nodesResponse else {
            return Result(warnings: [
                "Có \(textStyles.count) text style nhưng /nodes không gọi — typography bỏ qua."
            ])
        }

        var tokens: [TypographyToken] = []
        var warnings: [String] = []

        for summary in textStyles {
            let document = nodesResponse.nodes[summary.nodeId]?.document
            guard let document else {
                warnings.append("Text style '\(summary.name)' không có node trong response.")
                continue
            }
            guard let style = firstStyle(in: document) else {
                warnings.append("Text style '\(summary.name)' không có TypeStyle.")
                continue
            }
            let weightInt: Int? = style.fontWeight.map { Int($0.rounded()) }
            let lineHeight: Double? = {
                if let px = style.lineHeightPx, px > 0 { return px }
                if let pct = style.lineHeightPercent, let size = style.fontSize, pct > 0 {
                    return size * pct / 100.0
                }
                return nil
            }()
            tokens.append(TypographyToken(
                figmaName: summary.name,
                swiftName: mapper.map(summary.name, style: .joinAll),
                fontFamily: style.fontFamily,
                fontPostScriptName: style.fontPostScriptName,
                fontWeight: weightInt,
                fontSize: style.fontSize,
                lineHeightPx: lineHeight,
                letterSpacing: style.letterSpacing,
                textCase: style.textCase,
                textAlignHorizontal: style.textAlignHorizontal,
                italic: style.italic ?? false
            ))
        }

        return Result(typography: tokens.sorted { $0.swiftName < $1.swiftName }, warnings: warnings)
    }

    /// Some Figma files store the TypeStyle on the style node itself, others
    /// on a child of it. Walk one level deep before giving up.
    private func firstStyle(in node: FigmaNode) -> FigmaTypeStyle? {
        if let s = node.style { return s }
        for child in node.children ?? [] {
            if let s = child.style { return s }
        }
        return nil
    }
}
