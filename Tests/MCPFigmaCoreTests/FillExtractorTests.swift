import Testing
@testable import MCPFigmaCore

@Suite("FillExtractor")
struct FillExtractorTests {
    let extractor = FillExtractor()

    // MARK: - Filter behavior

    @Test("Plain SOLID 100% fills are filtered out (skill already has these from tokens.json)")
    func plainSolidIsFiltered() {
        let node = FigmaNode(
            id: "1:1", name: "Background", type: "RECTANGLE",
            fills: [
                FigmaPaint(type: "SOLID", color: FigmaColor(r: 1, g: 1, b: 1, a: 1))
            ]
        )
        let result = extractor.extract(nodes: ["1:1": node], imageRefURLs: [:])
        #expect(result.nodes.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test("SOLID with translucent paint opacity is kept (caller needs to know about the layer)")
    func translucentSolidIsKept() {
        let node = FigmaNode(
            id: "1:2", name: "Tint", type: "RECTANGLE",
            fills: [
                FigmaPaint(type: "SOLID", opacity: 0.5, color: FigmaColor(r: 0, g: 0, b: 0, a: 1))
            ]
        )
        let result = extractor.extract(nodes: ["1:2": node], imageRefURLs: [:])
        #expect(result.nodes.count == 1)
        if case .solid(let s) = result.nodes[0].fills[0] {
            #expect(s.opacity == 0.5)
            #expect(s.hex == "#000000")
        } else {
            Issue.record("Expected solid fill")
        }
    }

    @Test("Invisible fills are dropped from interesting check")
    func invisibleFillsDropped() {
        let node = FigmaNode(
            id: "1:3", name: "Hidden", type: "RECTANGLE",
            fills: [
                FigmaPaint(type: "GRADIENT_LINEAR", visible: false,
                           gradientStops: [
                            FigmaColorStop(position: 0, color: FigmaColor(r: 1, g: 0, b: 0, a: 1)),
                            FigmaColorStop(position: 1, color: FigmaColor(r: 0, g: 0, b: 1, a: 1))
                           ],
                           gradientHandlePositions: [
                            FigmaVector2D(x: 0, y: 0),
                            FigmaVector2D(x: 1, y: 1)
                           ])
            ]
        )
        let result = extractor.extract(nodes: ["1:3": node], imageRefURLs: [:])
        #expect(result.nodes.isEmpty)
    }

    // MARK: - Gradient parsing

    @Test("Linear gradient top-to-bottom emits start (0.5, 0) → end (0.5, 1) with both stops")
    func linearGradientStops() {
        let node = FigmaNode(
            id: "2:1", name: "HeroCard", type: "FRAME",
            fills: [
                FigmaPaint(
                    type: "GRADIENT_LINEAR",
                    gradientStops: [
                        FigmaColorStop(position: 0,   color: FigmaColor(r: 1, g: 0.42, b: 0.42, a: 1)),
                        FigmaColorStop(position: 1.0, color: FigmaColor(r: 1, g: 0.85, b: 0.24, a: 1))
                    ],
                    gradientHandlePositions: [
                        FigmaVector2D(x: 0.5, y: 0),
                        FigmaVector2D(x: 0.5, y: 1)
                    ]
                )
            ]
        )
        let result = extractor.extract(nodes: ["2:1": node], imageRefURLs: [:])
        #expect(result.nodes.count == 1)
        guard case .gradient(let g) = result.nodes[0].fills[0] else {
            Issue.record("Expected gradient"); return
        }
        #expect(g.kind == .linear)
        #expect(g.stops.count == 2)
        #expect(g.stops[0].position == 0)
        #expect(g.stops[0].hex == "#FF6B6B")
        #expect(g.stops[1].hex == "#FFD93D")
        #expect(g.startPoint.x == 0.5)
        #expect(g.startPoint.y == 0)
        #expect(g.endPoint.x == 0.5)
        #expect(g.endPoint.y == 1)
        #expect(g.opacity == 1.0)
    }

    @Test("Gradient with paint opacity 0.65 is preserved (typical overlay case)")
    func gradientOverlayOpacity() {
        let node = FigmaNode(
            id: "2:2", name: "Overlay", type: "RECTANGLE",
            fills: [
                FigmaPaint(
                    type: "GRADIENT_LINEAR", opacity: 0.65,
                    gradientStops: [
                        FigmaColorStop(position: 0, color: FigmaColor(r: 0, g: 0, b: 0, a: 0)),
                        FigmaColorStop(position: 1, color: FigmaColor(r: 0, g: 0, b: 0, a: 1))
                    ],
                    gradientHandlePositions: [
                        FigmaVector2D(x: 0.5, y: 0),
                        FigmaVector2D(x: 0.5, y: 1)
                    ]
                )
            ]
        )
        let result = extractor.extract(nodes: ["2:2": node], imageRefURLs: [:])
        guard case .gradient(let g) = result.nodes[0].fills[0] else {
            Issue.record("Expected gradient"); return
        }
        #expect(g.opacity == 0.65)
        // Stop alpha preserved in hex when != 1
        #expect(g.stops[0].hex == "#00000000")
        #expect(g.stops[1].hex == "#000000")
    }

    @Test("Gradient missing handle positions emits warning + skip")
    func gradientMissingHandles() {
        let node = FigmaNode(
            id: "2:3", name: "BrokenGradient", type: "RECTANGLE",
            fills: [
                FigmaPaint(
                    type: "GRADIENT_LINEAR",
                    gradientStops: [FigmaColorStop(position: 0, color: FigmaColor(r: 1, g: 0, b: 0, a: 1))],
                    gradientHandlePositions: []
                )
            ]
        )
        let result = extractor.extract(nodes: ["2:3": node], imageRefURLs: [:])
        #expect(result.nodes.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("BrokenGradient"))
    }

    @Test("Radial gradient parses third handle as widthPoint")
    func radialGradientWidthPoint() {
        let node = FigmaNode(
            id: "2:4", name: "Radial", type: "ELLIPSE",
            fills: [
                FigmaPaint(
                    type: "GRADIENT_RADIAL",
                    gradientStops: [
                        FigmaColorStop(position: 0, color: FigmaColor(r: 1, g: 1, b: 1, a: 1)),
                        FigmaColorStop(position: 1, color: FigmaColor(r: 0, g: 0, b: 0, a: 1))
                    ],
                    gradientHandlePositions: [
                        FigmaVector2D(x: 0.5, y: 0.5),
                        FigmaVector2D(x: 1.0, y: 0.5),
                        FigmaVector2D(x: 0.5, y: 1.0)
                    ]
                )
            ]
        )
        let result = extractor.extract(nodes: ["2:4": node], imageRefURLs: [:])
        guard case .gradient(let g) = result.nodes[0].fills[0] else {
            Issue.record("Expected radial"); return
        }
        #expect(g.kind == .radial)
        #expect(g.widthPoint?.x == 0.5)
        #expect(g.widthPoint?.y == 1.0)
    }

    // MARK: - Image fills

    @Test("IMAGE fill keeps imageRef and resolves URL when map provided")
    func imageFillResolvesURL() {
        let node = FigmaNode(
            id: "3:1", name: "BgImage", type: "RECTANGLE",
            fills: [
                FigmaPaint(type: "IMAGE", imageRef: "abc123", scaleMode: "FILL")
            ]
        )
        let result = extractor.extract(
            nodes: ["3:1": node],
            imageRefURLs: ["abc123": "https://s3.figma.com/img.png"]
        )
        guard case .image(let i) = result.nodes[0].fills[0] else {
            Issue.record("Expected image"); return
        }
        #expect(i.imageRef == "abc123")
        #expect(i.scaleMode == "FILL")
        #expect(i.imageUrl == "https://s3.figma.com/img.png")
    }

    @Test("IMAGE fill without scaleMode defaults to FILL")
    func imageFillDefaultScaleMode() {
        let node = FigmaNode(
            id: "3:2", name: "BgImage", type: "RECTANGLE",
            fills: [FigmaPaint(type: "IMAGE", imageRef: "ref1")]
        )
        let result = extractor.extract(nodes: ["3:2": node], imageRefURLs: [:])
        guard case .image(let i) = result.nodes[0].fills[0] else {
            Issue.record("Expected image"); return
        }
        #expect(i.scaleMode == "FILL")
        #expect(i.imageUrl == nil)
    }

    @Test("IMAGE fill with empty imageRef is skipped + warns")
    func imageFillMissingRef() {
        let node = FigmaNode(
            id: "3:3", name: "BrokenImg", type: "RECTANGLE",
            fills: [FigmaPaint(type: "IMAGE", imageRef: "")]
        )
        let result = extractor.extract(nodes: ["3:3": node], imageRefURLs: [:])
        #expect(result.nodes.isEmpty)
        #expect(result.warnings.count == 1)
    }

    // MARK: - Stacked fills (image + gradient overlay)

    @Test("IMAGE + GRADIENT stacked on same node produces both fills in order")
    func imageAndGradientStack() {
        let node = FigmaNode(
            id: "4:1", name: "HeroBanner", type: "FRAME",
            absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 375, height: 422),
            fills: [
                FigmaPaint(type: "IMAGE", imageRef: "heroBg", scaleMode: "FILL"),
                FigmaPaint(
                    type: "GRADIENT_LINEAR", opacity: 0.65,
                    gradientStops: [
                        FigmaColorStop(position: 0, color: FigmaColor(r: 0, g: 0, b: 0, a: 0)),
                        FigmaColorStop(position: 1, color: FigmaColor(r: 0, g: 0, b: 0, a: 1))
                    ],
                    gradientHandlePositions: [
                        FigmaVector2D(x: 0.5, y: 0),
                        FigmaVector2D(x: 0.5, y: 1)
                    ]
                )
            ]
        )
        let result = extractor.extract(
            nodes: ["4:1": node],
            imageRefURLs: ["heroBg": "https://s3.figma.com/hero.png"]
        )
        #expect(result.nodes.count == 1)
        let n = result.nodes[0]
        #expect(n.width == 375)
        #expect(n.height == 422)
        #expect(n.fills.count == 2)
        // Order matches Figma — bottom-to-top stack: image first, gradient on top
        if case .image(let i) = n.fills[0] {
            #expect(i.imageUrl == "https://s3.figma.com/hero.png")
        } else {
            Issue.record("Expected image at index 0")
        }
        if case .gradient(let g) = n.fills[1] {
            #expect(g.opacity == 0.65)
        } else {
            Issue.record("Expected gradient at index 1")
        }
    }

    // MARK: - Subtree walking

    @Test("Walks children recursively and only reports interesting descendants")
    func walksChildren() {
        let root = FigmaNode(
            id: "5:1", name: "Screen", type: "CANVAS",
            children: [
                FigmaNode(
                    id: "5:2", name: "Hero", type: "FRAME",
                    fills: [
                        FigmaPaint(type: "IMAGE", imageRef: "heroBg", scaleMode: "FILL")
                    ]
                ),
                FigmaNode(
                    id: "5:3", name: "Body", type: "FRAME",
                    fills: [
                        FigmaPaint(type: "SOLID", color: FigmaColor(r: 0.95, g: 0.95, b: 0.95, a: 1))  // plain, filtered
                    ]
                )
            ],
            fills: [
                FigmaPaint(type: "SOLID", color: FigmaColor(r: 1, g: 1, b: 1, a: 1))  // plain white, filtered
            ]
        )
        let result = extractor.extract(nodes: ["5:1": root], imageRefURLs: [:])
        #expect(result.nodes.count == 1)
        #expect(result.nodes[0].nodeId == "5:2")
    }

    // MARK: - Unsupported

    @Test("EMOJI / VIDEO fills emit unsupported case with rawType preserved")
    func unsupportedFillTypes() {
        let node = FigmaNode(
            id: "6:1", name: "WeirdFill", type: "RECTANGLE",
            fills: [
                FigmaPaint(type: "EMOJI")
            ]
        )
        let result = extractor.extract(nodes: ["6:1": node], imageRefURLs: [:])
        #expect(result.nodes.count == 1)
        if case .unsupported(let raw, _, _) = result.nodes[0].fills[0] {
            #expect(raw == "EMOJI")
        } else {
            Issue.record("Expected unsupported")
        }
    }
}
