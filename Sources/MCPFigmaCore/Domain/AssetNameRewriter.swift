import Foundation

public enum AssetKind: Sendable, Equatable, Hashable {
    case icon
    case image
}

public enum RewriteError: Error, Equatable, Sendable {
    case notExportable(String)
    case invalidName(String)
    case containsIllegalChars(String)
}

public struct AssetNameRewriter: Sendable {
    private static let iconPrefix = "eIC"
    private static let imagePrefix = "eImage"
    private static let iconReplacement = "icAI"
    private static let imageReplacement = "imageAI"
    private static let skipPrefix = "eAnim"

    public init() {}

    public static func isSkippedSubtree(_ figmaName: String) -> Bool {
        figmaName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix(skipPrefix)
    }

    public func rewrite(_ figmaName: String) throws -> (kind: AssetKind, renamed: String) {
        let trimmed = figmaName.trimmingCharacters(in: .whitespacesAndNewlines)

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
}
