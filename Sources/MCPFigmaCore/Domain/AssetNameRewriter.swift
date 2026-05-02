import Foundation

public enum AssetKind: Sendable, Equatable, Hashable {
    case icon
    case image
    case animation
}

public enum RewriteError: Error, Equatable, Sendable {
    case notExportable(String)
    case invalidName(String)
    case containsIllegalChars(String)
}

public struct AssetNameRewriter: Sendable {
    private static let iconPrefix = "eIC"
    private static let imagePrefix = "eImage"
    private static let animationPrefix = "eAnim"
    private static let iconReplacement = "icAI"
    private static let imageReplacement = "imageAI"

    public init() {}

    public func rewrite(_ figmaName: String) throws -> (kind: AssetKind, renamed: String) {
        let trimmed = figmaName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Order matters: eImage before eIC is irrelevant (no overlap), but eAnim
        // is the only stop-descent prefix that produces no rendered output.
        if trimmed.hasPrefix(Self.iconPrefix) {
            let remainder = String(trimmed.dropFirst(Self.iconPrefix.count))
            try validate(remainder: remainder, originalName: figmaName)
            return (.icon, Self.iconReplacement + remainder)
        }
        if trimmed.hasPrefix(Self.imagePrefix) {
            let remainder = String(trimmed.dropFirst(Self.imagePrefix.count))
            try validate(remainder: remainder, originalName: figmaName)
            return (.image, Self.imageReplacement + remainder)
        }
        if trimmed.hasPrefix(Self.animationPrefix) {
            let remainder = String(trimmed.dropFirst(Self.animationPrefix.count))
            try validate(remainder: remainder, originalName: figmaName)
            // Animations keep the original Figma name — they're not downloaded
            // and not renamed for xcassets; SwiftUI skill renders a placeholder.
            return (.animation, trimmed)
        }
        throw RewriteError.notExportable(figmaName)
    }

    private func validate(remainder: String, originalName: String) throws {
        guard let first = remainder.first else {
            throw RewriteError.invalidName(originalName)
        }
        guard remainder.allSatisfy(Self.isAllowed) else {
            throw RewriteError.containsIllegalChars(originalName)
        }
        guard first.isASCII, first.isUppercase else {
            throw RewriteError.invalidName(originalName)
        }
    }

    private static func isAllowed(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        return c.isLetter || c.isNumber || c == "_"
    }
}

public extension AssetNameRewriter {
    static func fileName(renamed: String, scale: Int) -> String {
        "\(renamed)@\(scale)x.png"
    }

    /// Appends a `WxH` suffix derived from the node's bounding box (rounded to int).
    /// Returns `renamed` unchanged when either dimension is missing or non-positive.
    static func appendSizeSuffix(renamed: String, width: Double?, height: Double?) -> String {
        guard let width, let height, width > 0, height > 0 else { return renamed }
        let w = Int(width.rounded())
        let h = Int(height.rounded())
        guard w > 0, h > 0 else { return renamed }
        return "\(renamed)\(w)x\(h)"
    }
}
