import Testing
@testable import MCPFigmaCore

@Suite("SwiftNameMapper")
struct SwiftNameMapperTests {
    let mapper = SwiftNameMapper()

    @Test("Slash-grouped name → camelCase joined")
    func slashJoined() {
        #expect(mapper.map("primary/500") == "primary500")
        #expect(mapper.map("text/primary") == "textPrimary")
        #expect(mapper.map("surface/default") == "surfaceDefault")
    }

    @Test("Drop first segment when style says so")
    func dropFirstSegment() {
        #expect(mapper.map("spacing/md", style: .dropFirstSegment) == "md")
        #expect(mapper.map("radius/lg", style: .dropFirstSegment) == "lg")
        #expect(mapper.map("primary", style: .dropFirstSegment) == "primary")
    }

    @Test("Within-segment dashes/underscores produce camelCase words")
    func dashedSegments() {
        #expect(mapper.map("border-subtle") == "borderSubtle")
        #expect(mapper.map("text/primary-on-dark") == "textPrimaryOnDark")
        #expect(mapper.map("primary_strong") == "primaryStrong")
    }

    @Test("Multi-separator and whitespace handling")
    func multiSeparator() {
        #expect(mapper.map("Heading / Large") == "headingLarge")
        #expect(mapper.map("color.primary.500") == "colorPrimary500")
    }

    @Test("Empty input returns empty")
    func emptyInput() {
        #expect(mapper.map("") == "")
        #expect(mapper.map("   ") == "")
    }

    @Test("leadingSegment exposes the first slash-grouped piece")
    func leadingSegment() {
        #expect(mapper.leadingSegment("spacing/md") == "spacing")
        #expect(mapper.leadingSegment("primary/500") == "primary")
        #expect(mapper.leadingSegment("solo") == "solo")
    }
}
