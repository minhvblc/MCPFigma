import Testing
@testable import MCPFigmaCore

@Suite("AssetScanner")
struct AssetScannerTests {
    let scanner = AssetScanner()

    @Test("Matches eIC node and does NOT recurse into its children")
    func matchesIconAndSkipsChildren() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "eICHome", type: "FRAME", children: [
                FigmaNode(id: "3", name: "eICShouldBeIgnored", type: "VECTOR", children: nil),
                FigmaNode(id: "4", name: "eImageAlsoIgnored", type: "FRAME", children: nil)
            ])
        ])

        let result = scanner.scan(root)

        #expect(result.matches.count == 1)
        #expect(result.matches.first?.nodeId == "2")
        #expect(result.matches.first?.kind == .icon)
        #expect(result.matches.first?.renamed == "icAIHome")
        #expect(result.warnings.isEmpty)
    }

    @Test("Scans siblings across multiple branches")
    func scansMultipleBranches() {
        let root = FigmaNode(id: "1", name: "Page", type: "CANVAS", children: [
            FigmaNode(id: "2", name: "Section A", type: "FRAME", children: [
                FigmaNode(id: "3", name: "eICHome", type: "FRAME", children: nil),
                FigmaNode(id: "4", name: "eImageBanner", type: "FRAME", children: nil)
            ]),
            FigmaNode(id: "5", name: "Section B", type: "FRAME", children: [
                FigmaNode(id: "6", name: "eICUser", type: "FRAME", children: nil)
            ])
        ])

        let result = scanner.scan(root)

        #expect(result.matches.count == 3)
        #expect(Set(result.matches.map { $0.renamed }) == ["icAIHome", "imageAIBanner", "icAIUser"])
        #expect(result.warnings.isEmpty)
    }

    @Test("Empty/no-children tree returns empty")
    func emptyTree() {
        let root = FigmaNode(id: "1", name: "Empty", type: "FRAME", children: nil)
        let result = scanner.scan(root)
        #expect(result.matches.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test("Untagged tree with no graphic leaves returns empty")
    func untaggedNonGraphicTreeReturnsEmpty() {
        // FRAME containers + a TEXT leaf — none is a VECTOR or IMAGE-filled
        // node, so nothing is auto-exported and descent finds no tagged nodes.
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "normal", type: "FRAME", children: [
                FigmaNode(id: "3", name: "Label", type: "TEXT", children: nil),
                FigmaNode(id: "4", name: "Spacer", type: "FRAME", children: nil)
            ])
        ])
        let result = scanner.scan(root)
        #expect(result.matches.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test("Deeply nested matched node is still found")
    func deeplyNestedMatch() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "A", type: "FRAME", children: [
                FigmaNode(id: "3", name: "B", type: "FRAME", children: [
                    FigmaNode(id: "4", name: "eICDeep", type: "FRAME", children: nil)
                ])
            ])
        ])
        let result = scanner.scan(root)
        #expect(result.matches.count == 1)
        #expect(result.matches.first?.nodeId == "4")
        #expect(result.matches.first?.renamed == "icAIDeep")
    }

    @Test("Bare/malformed icon prefix emits warning AND stops descent")
    func invalidPrefixWarnsAndStopsDescent() {
        // `eIC` (bare prefix, empty remainder) is unsalvageable — the prefix
        // is a clear tag, so we treat the node as terminal. The valid child
        // `eICInside` must NOT be exported.
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "eIC", type: "FRAME", children: [
                FigmaNode(id: "3", name: "eICInside", type: "FRAME", children: nil)
            ])
        ])

        let result = scanner.scan(root)

        #expect(result.matches.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.nodeId == "2")
        #expect(result.warnings.first?.figmaName == "eIC")
    }

    @Test("Bare eImage container emits warning AND stops descent")
    func invalidImageContainerStopsDescent() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "eImage", type: "FRAME", children: [
                FigmaNode(id: "3", name: "eImageBanner", type: "FRAME", children: nil)
            ])
        ])

        let result = scanner.scan(root)

        #expect(result.matches.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.nodeId == "2")
        #expect(result.warnings.first?.figmaName == "eImage")
    }

    @Test("Canonical prefix with lowercase remainder is auto-recovered without warning")
    func canonicalPrefixWithLowercaseRemainderRecovers() {
        // `eIChome` and `eImagebanner` have canonical prefixes but lowercase
        // remainder first chars. Recovery auto-uppercases (`home`→`Home`,
        // `banner`→`Banner`) and produces canonical iOS names. Because the
        // prefix itself is canonical, no case-mismatch warning is emitted.
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "eIChome", type: "FRAME", children: nil),
            FigmaNode(id: "3", name: "eImagebanner", type: "FRAME", children: nil),
        ])

        let result = scanner.scan(root)

        #expect(result.matches.count == 2)
        let byId = Dictionary(uniqueKeysWithValues: result.matches.map { ($0.nodeId, $0) })
        #expect(byId["2"]?.renamed == "icAIHome")
        #expect(byId["3"]?.renamed == "imageAIBanner")
        #expect(result.warnings.isEmpty)
    }

    @Test("Illegal-char node (eICHome-2) emits warning")
    func illegalCharEmitsWarning() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "eICHome-2", type: "FRAME", children: nil)
        ])

        let result = scanner.scan(root)

        #expect(result.matches.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.figmaName == "eICHome-2")
        #expect(result.warnings.first?.reason.contains("không cho phép") == true)
    }

    @Test("eAnim node is skipped without recursing into children")
    func eAnimSkipsSubtree() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "eAnimSplash", type: "FRAME", children: [
                FigmaNode(id: "3", name: "eICShouldBeIgnored", type: "VECTOR", children: nil),
                FigmaNode(id: "4", name: "eImageAlsoIgnored", type: "FRAME", children: nil)
            ]),
            FigmaNode(id: "5", name: "eICOutside", type: "FRAME", children: nil)
        ])

        let result = scanner.scan(root)

        #expect(result.matches.count == 1)
        #expect(result.matches.first?.nodeId == "5")
        #expect(result.matches.first?.renamed == "icAIOutside")
        #expect(result.warnings.isEmpty)
    }

    @Test("Bounding box on icon/image appends WxH size suffix to renamed")
    func boundingBoxAppendsSizeSuffix() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(
                id: "2",
                name: "eICFacebook",
                type: "FRAME",
                absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 24, height: 24),
                children: nil
            ),
            FigmaNode(
                id: "3",
                name: "eImageBanner",
                type: "FRAME",
                absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 375, height: 200),
                children: nil
            )
        ])

        let result = scanner.scan(root)

        #expect(result.matches.count == 2)
        let byId = Dictionary(uniqueKeysWithValues: result.matches.map { ($0.nodeId, $0) })
        #expect(byId["2"]?.renamed == "icAIFacebook24x24")
        #expect(byId["2"]?.width == 24)
        #expect(byId["2"]?.height == 24)
        #expect(byId["3"]?.renamed == "imageAIBanner375x200")
    }

    @Test("Asset without bounding box keeps renamed without suffix")
    func missingBoundingBoxLeavesRenamedUnchanged() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "eICHome", type: "FRAME", children: nil)
        ])

        let result = scanner.scan(root)

        #expect(result.matches.first?.renamed == "icAIHome")
        #expect(result.matches.first?.width == nil)
    }

    @Test("Mixed valid + invalid produces both matches and warnings")
    func mixedMatchesAndWarnings() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "eICHome", type: "FRAME", children: nil),
            FigmaNode(id: "3", name: "eImage", type: "FRAME", children: nil),
            FigmaNode(id: "4", name: "eImageBanner", type: "FRAME", children: nil)
        ])

        let result = scanner.scan(root)

        #expect(result.matches.count == 2)
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.nodeId == "3")
    }

    @Test("Case-variant prefix is exported under canonical name with warning")
    func caseMismatchExportsWithWarning() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "EICHome", type: "FRAME", children: nil),
            FigmaNode(id: "3", name: "eichome", type: "VECTOR", children: nil),
            FigmaNode(id: "4", name: "eIMAGEBanner", type: "FRAME", children: nil),
        ])

        let result = scanner.scan(root)

        // All three should match (case-recovered), so registry / xcassets /
        // Swift binding chain stays intact.
        #expect(result.matches.count == 3)
        let byId = Dictionary(uniqueKeysWithValues: result.matches.map { ($0.nodeId, $0) })
        #expect(byId["2"]?.renamed == "icAIHome")
        #expect(byId["3"]?.renamed == "icAIHome")
        #expect(byId["4"]?.renamed == "imageAIBanner")

        // All three should also emit case-mismatch warnings so the designer
        // can fix the Figma layer names.
        #expect(result.warnings.count == 3)
        let warningIds = Set(result.warnings.map { $0.nodeId })
        #expect(warningIds == ["2", "3", "4"])
        // Warning message should mention canonical prefix
        for w in result.warnings {
            #expect(w.reason.contains("canonical 'eIC'") || w.reason.contains("canonical 'eImage'"))
        }
    }

    // ── Untagged graphic-leaf auto-export ────────────────────────────────────

    @Test("Untagged VECTOR leaf is auto-exported as an icon")
    func untaggedVectorLeafExportedAsIcon() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "container", type: "FRAME", children: [
                FigmaNode(id: "3", name: "search", type: "VECTOR", children: nil)
            ])
        ])

        let result = scanner.scan(root)

        #expect(result.matches.count == 1)
        #expect(result.matches.first?.nodeId == "3")
        #expect(result.matches.first?.kind == .icon)
        #expect(result.matches.first?.renamed == "icAISearch")
        #expect(result.warnings.isEmpty)
    }

    @Test("Untagged IMAGE-filled leaf is auto-exported as an image")
    func untaggedImageFillLeafExportedAsImage() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(
                id: "2",
                name: "hero banner",
                type: "RECTANGLE",
                children: nil,
                fills: [FigmaPaint(type: "IMAGE", imageRef: "abc")]
            )
        ])

        let result = scanner.scan(root)

        #expect(result.matches.count == 1)
        #expect(result.matches.first?.kind == .image)
        #expect(result.matches.first?.renamed == "imageAIHeroBanner")
    }

    @Test("Untagged container with children is still descended into")
    func untaggedContainerStillDescends() {
        // A plain FRAME with children must NOT be exported itself — the
        // scanner descends and still finds the tagged node inside.
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "section", type: "FRAME", children: [
                FigmaNode(id: "3", name: "eICHome", type: "FRAME", children: nil)
            ])
        ])

        let result = scanner.scan(root)

        #expect(result.matches.count == 1)
        #expect(result.matches.first?.renamed == "icAIHome")
    }

    @Test("Untagged non-graphic leaf (FRAME / TEXT) is skipped")
    func untaggedNonGraphicLeafSkipped() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "empty box", type: "FRAME", children: nil),
            FigmaNode(id: "3", name: "Title", type: "TEXT", children: nil)
        ])

        let result = scanner.scan(root)

        #expect(result.matches.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test("Untagged VECTOR leaf gets a WxH size suffix from its bounding box")
    func untaggedVectorLeafAppendsSizeSuffix() {
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(
                id: "2",
                name: "close",
                type: "VECTOR",
                absoluteBoundingBox: FigmaBoundingBox(x: 0, y: 0, width: 24, height: 24),
                children: nil
            )
        ])

        let result = scanner.scan(root)

        #expect(result.matches.first?.renamed == "icAIClose24x24")
    }

    @Test("Untagged graphic leaf with an unusable layer name warns instead of exporting")
    func untaggedLeafWithUnusableNameWarns() {
        // A VECTOR leaf named only with symbols yields no valid identifier.
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "★★★", type: "VECTOR", children: nil)
        ])

        let result = scanner.scan(root)

        #expect(result.matches.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.nodeId == "2")
    }

    @Test("Tagged node still stops descent over untagged VECTOR children")
    func taggedStopsDescentOverUntaggedChildren() {
        // Regression: an eIC node with untagged VECTOR children exports only
        // itself — the VECTOR children must NOT also surface as assets.
        let root = FigmaNode(id: "1", name: "Root", type: "FRAME", children: [
            FigmaNode(id: "2", name: "eICHome", type: "FRAME", children: [
                FigmaNode(id: "3", name: "stroke", type: "VECTOR", children: nil)
            ])
        ])

        let result = scanner.scan(root)

        #expect(result.matches.count == 1)
        #expect(result.matches.first?.nodeId == "2")
    }
}
