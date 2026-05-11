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

/// P1-1: custom prefix rule. Lets a project map non-standard Figma naming
/// (e.g. "icon/", "img-", "logo-") onto the iOS asset convention without
/// renaming every layer in Figma. Custom rules are checked BEFORE the
/// built-in eIC*/eImage*/eAnim* prefixes, so a project can override the
/// defaults too.
///
/// Use case: when working with a design system that already prefixes icons
/// as "ic/" (slash-separated) or "ic-" (kebab-case), set:
///   [.init(figmaPrefix: "ic/", renamedPrefix: "icAI", kind: .icon)]
///
/// The remainder of the Figma name (after the prefix is stripped) is
/// validated the same way: first char ASCII uppercase, only [A-Za-z0-9_].
public struct RenameRule: Equatable, Sendable {
    public let figmaPrefix: String
    public let renamedPrefix: String
    public let kind: AssetKind

    public init(figmaPrefix: String, renamedPrefix: String, kind: AssetKind) {
        self.figmaPrefix = figmaPrefix
        self.renamedPrefix = renamedPrefix
        self.kind = kind
    }
}

public struct AssetNameRewriter: Sendable {
    private static let iconPrefix = "eIC"
    private static let imagePrefix = "eImage"
    private static let animationPrefix = "eAnim"
    private static let iconReplacement = "icAI"
    private static let imageReplacement = "imageAI"

    private let customRules: [RenameRule]

    public init(customRules: [RenameRule] = []) {
        self.customRules = customRules
    }

    public func rewrite(_ figmaName: String) throws -> (kind: AssetKind, renamed: String) {
        let trimmed = figmaName.trimmingCharacters(in: .whitespacesAndNewlines)

        // P1-1: Try custom rules first so a project can opt out of the built-in
        // eIC*/eImage* convention. Longest-prefix-wins to avoid ambiguity when
        // rules overlap (e.g. "ic/" and "icon/").
        let sortedRules = customRules.sorted { $0.figmaPrefix.count > $1.figmaPrefix.count }
        for rule in sortedRules where trimmed.hasPrefix(rule.figmaPrefix) {
            let remainder = String(trimmed.dropFirst(rule.figmaPrefix.count))
            try validateCustomRemainder(remainder: remainder, originalName: figmaName)
            if rule.kind == .animation {
                return (.animation, trimmed)
            }
            return (rule.kind, rule.renamedPrefix + remainder)
        }

        // Built-in prefixes. Order matters: eImage before eIC is irrelevant
        // (no overlap), but eAnim is the only stop-descent prefix that produces
        // no rendered output.
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

    /// More permissive remainder validation for custom rules. Designers using
    /// "ic/HomeFilled" expect "HomeFilled" — strict uppercase-first is fine,
    /// but kebab-case "ic/home-filled" should normalize too. Convert kebab/snake
    /// segments to camelCase so the iOS asset name is always identifier-safe.
    private func validateCustomRemainder(remainder: String, originalName: String) throws {
        let normalized = Self.normalizeCustomRemainder(remainder)
        guard let first = normalized.first else {
            throw RewriteError.invalidName(originalName)
        }
        guard first.isASCII, first.isLetter || first.isNumber else {
            throw RewriteError.invalidName(originalName)
        }
        guard normalized.allSatisfy(Self.isAllowed) else {
            throw RewriteError.containsIllegalChars(originalName)
        }
    }

    /// Kebab/snake → camelCase, uppercase first letter for asset-name safety.
    private static func normalizeCustomRemainder(_ raw: String) -> String {
        guard raw.contains("-") || raw.contains("_") || raw.contains("/") else {
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
        let parts = raw.split(whereSeparator: { "-_/".contains($0) })
        return parts.enumerated().map { idx, part in
            let s = String(part)
            return s.prefix(1).uppercased() + s.dropFirst()
        }.joined()
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
