import Testing
@testable import MCPFigmaCore

@Suite("RegistryBuilder")
struct RegistryBuilderTests {
    let builder = RegistryBuilder()

    @Test("Tagged + Lottie + screen all surfaced from one walk")
    func combinedRegistry() {
        let root = FigmaNode(
            id: "0:1",
            name: "OnboardingFlow",
            type: "CANVAS",
            children: [
                FigmaNode(
                    id: "1:2",
                    name: "Welcome",
                    type: "FRAME",
                    absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 375, height: 812),
                    children: [
                        FigmaNode(id: "1:3", name: "eICClose", type: "FRAME"),
                        FigmaNode(
                            id: "1:4",
                            name: "eAnimLoading",
                            type: "FRAME",
                            absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 120, height: 120),
                            children: [
                                FigmaNode(id: "1:5", name: "ignored frame", type: "FRAME")
                            ]
                        )
                    ]
                ),
                FigmaNode(
                    id: "2:1",
                    name: "Done",
                    type: "FRAME",
                    absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 375, height: 812)
                )
            ]
        )

        let registry = builder.build(rootNode: root)

        #expect(registry.rootNodeId == "0:1")
        #expect(registry.screens.map(\.nodeId) == ["1:2", "2:1"])
        #expect(registry.taggedAssets.count == 1)
        #expect(registry.taggedAssets.first?.renamed == "icAIClose")
        #expect(registry.lottiePlaceholders.count == 1)
        #expect(registry.lottiePlaceholders.first?.figmaName == "eAnimLoading")
        #expect(registry.lottiePlaceholders.first?.width == 120)
        #expect(registry.warnings.isEmpty)
    }

    @Test("eAnim children are not walked into for Lottie placeholders")
    func eAnimSubtreeBlocked() {
        let root = FigmaNode(
            id: "0:1",
            name: "Page",
            type: "FRAME",
            absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 375, height: 812),
            children: [
                FigmaNode(
                    id: "1:1",
                    name: "eAnimSplash",
                    type: "FRAME",
                    children: [
                        FigmaNode(id: "1:2", name: "eAnimNested", type: "FRAME")
                    ]
                )
            ]
        )
        let registry = builder.build(rootNode: root)
        #expect(registry.lottiePlaceholders.count == 1)
        #expect(registry.lottiePlaceholders.first?.figmaName == "eAnimSplash")
    }

    @Test("Invalid eAnim name produces a warning, no placeholder")
    func invalidLottieName() {
        // `eAnim-load` has an illegal `-` in the remainder. Lowercase first
        // chars (e.g. `eAnimloading`) auto-recover via rewriteFlexible, so we
        // pick a name that's truly unsalvageable to assert the warning path.
        let root = FigmaNode(
            id: "0:1",
            name: "Page",
            type: "FRAME",
            absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 375, height: 812),
            children: [
                FigmaNode(id: "1:1", name: "eAnim-load", type: "FRAME")
            ]
        )
        let registry = builder.build(rootNode: root)
        #expect(registry.lottiePlaceholders.isEmpty)
        #expect(registry.warnings.count == 1)
        #expect(registry.warnings.first?.figmaName == "eAnim-load")
    }

    @Test("Single FRAME root → single screen entry")
    func singleScreenRoot() {
        let root = FigmaNode(
            id: "0:1",
            name: "Welcome",
            type: "FRAME",
            absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 375, height: 812)
        )
        let registry = builder.build(rootNode: root)
        #expect(registry.screens.count == 1)
        #expect(registry.screens.first?.nodeId == "0:1")
    }

    @Test("FRAMEs outside iOS device range are NOT screens")
    func tooWideFrameSkipped() {
        let root = FigmaNode(
            id: "0:1",
            name: "Page",
            type: "CANVAS",
            children: [
                FigmaNode(
                    id: "1:1",
                    name: "Wide thumbnail",
                    type: "FRAME",
                    absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 1920, height: 1080)
                ),
                FigmaNode(
                    id: "1:2",
                    name: "iPhone screen",
                    type: "FRAME",
                    absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 390, height: 844)
                )
            ]
        )
        let registry = builder.build(rootNode: root)
        #expect(registry.screens.map(\.nodeId) == ["1:2"])
    }
}
