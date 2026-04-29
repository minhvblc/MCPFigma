import Testing
@testable import MCPFigmaCore

@Suite("TextStyleExtractor")
struct TextStyleExtractorTests {
    let extractor = TextStyleExtractor()

    @Test("Text style with px line-height maps directly to lineHeightPx")
    func pxLineHeight() {
        let styles = FigmaStylesResponse(
            status: 200, error: false, message: nil,
            meta: .init(styles: [
                .init(key: "k1", nodeId: "1:10", name: "Heading 3", styleType: "TEXT")
            ])
        )
        let nodes = FigmaFileNodesResponse(
            name: "f",
            nodes: [
                "1:10": .init(document: FigmaNode(
                    id: "1:10",
                    name: "Heading 3",
                    type: "TEXT",
                    style: FigmaTypeStyle(
                        fontFamily: "SF Pro Rounded",
                        fontPostScriptName: "SFProRounded-Bold",
                        fontWeight: 700,
                        fontSize: 28,
                        lineHeightPx: 34,
                        letterSpacing: -0.56,
                        textCase: "ORIGINAL",
                        textAlignHorizontal: "LEFT",
                        italic: false
                    )
                ))
            ]
        )

        let result = extractor.extract(styles: styles, nodes: nodes)
        #expect(result.typography.count == 1)
        let t = result.typography[0]
        #expect(t.swiftName == "heading3")
        #expect(t.fontFamily == "SF Pro Rounded")
        #expect(t.fontWeight == 700)
        #expect(t.fontSize == 28)
        #expect(t.lineHeightPx == 34)
        #expect(t.letterSpacing == -0.56)
        #expect(t.italic == false)
    }

    @Test("Percent line-height computed against fontSize")
    func percentLineHeight() {
        let styles = FigmaStylesResponse(
            status: 200, error: false, message: nil,
            meta: .init(styles: [
                .init(key: "k1", nodeId: "1:11", name: "Body", styleType: "TEXT")
            ])
        )
        let nodes = FigmaFileNodesResponse(
            name: "f",
            nodes: [
                "1:11": .init(document: FigmaNode(
                    id: "1:11", name: "Body", type: "TEXT",
                    style: FigmaTypeStyle(
                        fontFamily: "Inter", fontWeight: 400, fontSize: 16,
                        lineHeightPx: nil, lineHeightPercent: 150
                    )
                ))
            ]
        )

        let result = extractor.extract(styles: styles, nodes: nodes)
        #expect(result.typography[0].lineHeightPx == 24)
    }

    @Test("Non-TEXT styles are filtered out")
    func nonTextStylesIgnored() {
        let styles = FigmaStylesResponse(
            status: 200, error: false, message: nil,
            meta: .init(styles: [
                .init(key: "k1", nodeId: "1:1", name: "Brand Red", styleType: "FILL"),
                .init(key: "k2", nodeId: "1:2", name: "Big Shadow", styleType: "EFFECT"),
                .init(key: "k3", nodeId: "1:3", name: "Caption", styleType: "TEXT")
            ])
        )
        let nodes = FigmaFileNodesResponse(
            name: "f",
            nodes: [
                "1:3": .init(document: FigmaNode(
                    id: "1:3", name: "Caption", type: "TEXT",
                    style: FigmaTypeStyle(fontFamily: "Inter", fontWeight: 400, fontSize: 12)
                ))
            ]
        )

        let result = extractor.extract(styles: styles, nodes: nodes)
        #expect(result.typography.count == 1)
        #expect(result.typography[0].swiftName == "caption")
    }

    @Test("Missing /styles → empty typography + warning")
    func missingStylesResponse() {
        let result = extractor.extract(styles: nil, nodes: nil)
        #expect(result.typography.isEmpty)
        #expect(!result.warnings.isEmpty)
    }

    @Test("Styles error → empty typography + warning")
    func stylesError() {
        let styles = FigmaStylesResponse(
            status: 403, error: true, message: "forbidden", meta: nil
        )
        let result = extractor.extract(styles: styles, nodes: nil)
        #expect(result.typography.isEmpty)
        #expect(result.warnings.contains { $0.contains("/styles trả lỗi") })
    }

    @Test("Style node without TypeStyle → warning, not crash")
    func styleNodeWithoutTypeStyle() {
        let styles = FigmaStylesResponse(
            status: 200, error: false, message: nil,
            meta: .init(styles: [
                .init(key: "k1", nodeId: "1:1", name: "Lost", styleType: "TEXT")
            ])
        )
        let nodes = FigmaFileNodesResponse(
            name: "f",
            nodes: [
                "1:1": .init(document: FigmaNode(id: "1:1", name: "Lost", type: "FRAME"))
            ]
        )
        let result = extractor.extract(styles: styles, nodes: nodes)
        #expect(result.typography.isEmpty)
        #expect(result.warnings.contains { $0.contains("không có TypeStyle") })
    }
}
