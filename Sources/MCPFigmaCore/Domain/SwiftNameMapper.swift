import Foundation

/// Maps Figma variable names (slash-grouped, mixed case) to SwiftUI naming convention.
///
/// Examples:
///   "primary/500"              → "primary500"
///   "text/primary"             → "textPrimary"
///   "surface/default"          → "surfaceDefault"
///   "spacing/md"               → "md"          (last segment when collection-aware)
///   "spacing/md"               → "spacingMd"   (joined when not collection-aware)
///   "Heading / Large"          → "headingLarge"
///   "border-subtle"            → "borderSubtle"
///   "color.primary.500"        → "colorPrimary500"
public struct SwiftNameMapper: Sendable {
    public init() {}

    public enum Style: Sendable {
        /// Drop the leading collection segment ("spacing/md" → "md").
        /// Useful when the collection name is already implied by the enum (Spacing.md).
        case dropFirstSegment
        /// Keep all segments joined ("spacing/md" → "spacingMd").
        /// Useful for flat namespaces like Color.
        case joinAll
    }

    public func map(_ figmaName: String, style: Style = .joinAll) -> String {
        let segments = splitSegments(figmaName)
        guard !segments.isEmpty else { return "" }

        let working: [String]
        switch style {
        case .dropFirstSegment where segments.count > 1:
            working = Array(segments.dropFirst())
        default:
            working = segments
        }

        return camelCase(from: working)
    }

    /// Convenience: extract the last-segment hint as a kind label
    /// (e.g. "spacing/md" → "spacing"; "primary/500" → "primary").
    public func leadingSegment(_ figmaName: String) -> String? {
        let segments = splitSegments(figmaName)
        return segments.first
    }

    private func splitSegments(_ name: String) -> [String] {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        // Split on / . or whitespace; treat - and _ as word boundaries within a segment
        let separators: Set<Character> = ["/", ".", " "]
        var segments: [String] = []
        var current = ""
        for c in cleaned {
            if separators.contains(c) {
                if !current.isEmpty { segments.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func camelCase(from segments: [String]) -> String {
        var result = ""
        for (idx, segment) in segments.enumerated() {
            // Within a segment, split on - and _
            let words = segment
                .split { $0 == "-" || $0 == "_" }
                .map(String.init)
                .filter { !$0.isEmpty }
            for (wIdx, word) in words.enumerated() {
                let lower = word.lowercased()
                if idx == 0 && wIdx == 0 {
                    result.append(lower)
                } else {
                    result.append(uppercaseFirst(lower))
                }
            }
        }
        return result
    }

    private func uppercaseFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }
}
