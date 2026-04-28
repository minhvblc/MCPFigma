import Testing
@testable import MCPFigmaCore

@Suite("TokenExtractor")
struct TokenExtractorTests {
    let extractor = TokenExtractor()

    @Test("Hex from RGBA — opaque drops alpha, transparent keeps it")
    func hexFromRGBA() {
        #expect(TokenExtractor.hexFromRGBA(r: 1, g: 0, b: 0, a: 1) == "#FF0000")
        #expect(TokenExtractor.hexFromRGBA(r: 0, g: 0, b: 0, a: 1) == "#000000")
        #expect(TokenExtractor.hexFromRGBA(r: 1, g: 1, b: 1, a: 1) == "#FFFFFF")
        #expect(TokenExtractor.hexFromRGBA(r: 1, g: 0, b: 0, a: 0.5).hasSuffix("80") == true)
    }

    @Test("Color variable with light + dark modes resolves both hexes")
    func colorWithLightDark() {
        let collectionId = "C1"
        let lightId = "M-light"
        let darkId = "M-dark"

        let response = makeResponse(
            collections: [
                FigmaVariableCollection(
                    id: collectionId,
                    name: "Theme",
                    modes: [
                        .init(modeId: lightId, name: "Light"),
                        .init(modeId: darkId, name: "Dark")
                    ],
                    defaultModeId: lightId
                )
            ],
            variables: [
                FigmaVariable(
                    id: "V1",
                    name: "primary/500",
                    resolvedType: "COLOR",
                    variableCollectionId: collectionId,
                    valuesByMode: [
                        lightId: .color(r: 1, g: 0, b: 0, a: 1),
                        darkId: .color(r: 0, g: 0, b: 1, a: 1)
                    ]
                )
            ]
        )

        let tokens = extractor.extract(from: response)

        #expect(tokens.colors.count == 1)
        let color = tokens.colors.first!
        #expect(color.swiftName == "primary500")
        #expect(color.lightHex == "#FF0000")
        #expect(color.darkHex == "#0000FF")
    }

    @Test("Color alias resolves through one hop")
    func colorAliasResolves() {
        let id = "C1"
        let modeId = "M1"

        let response = makeResponse(
            collections: [
                FigmaVariableCollection(
                    id: id,
                    name: "Theme",
                    modes: [.init(modeId: modeId, name: "Default")],
                    defaultModeId: modeId
                )
            ],
            variables: [
                FigmaVariable(
                    id: "V_BASE",
                    name: "raw/red500",
                    resolvedType: "COLOR",
                    variableCollectionId: id,
                    valuesByMode: [modeId: .color(r: 1, g: 0, b: 0, a: 1)]
                ),
                FigmaVariable(
                    id: "V_ALIAS",
                    name: "primary/500",
                    resolvedType: "COLOR",
                    variableCollectionId: id,
                    valuesByMode: [modeId: .alias(variableId: "V_BASE")]
                )
            ]
        )

        let tokens = extractor.extract(from: response)
        let aliasToken = tokens.colors.first(where: { $0.figmaName == "primary/500" })
        #expect(aliasToken?.lightHex == "#FF0000")
    }

    @Test("Spacing variable drops leading 'spacing/' segment in swiftName")
    func spacingDropsLeading() {
        let id = "C1"
        let modeId = "M1"
        let response = makeResponse(
            collections: [
                FigmaVariableCollection(
                    id: id, name: "S", modes: [.init(modeId: modeId, name: "Default")],
                    defaultModeId: modeId
                )
            ],
            variables: [
                FigmaVariable(
                    id: "V1", name: "spacing/md", resolvedType: "FLOAT",
                    variableCollectionId: id, valuesByMode: [modeId: .number(12)]
                )
            ]
        )
        let tokens = extractor.extract(from: response)
        #expect(tokens.spacing.count == 1)
        #expect(tokens.spacing.first?.swiftName == "md")
        #expect(tokens.spacing.first?.value == 12)
    }

    @Test("Radius >= 999 marks isCapsule")
    func radiusFullPill() {
        let id = "C1"; let modeId = "M1"
        let response = makeResponse(
            collections: [
                FigmaVariableCollection(
                    id: id, name: "R", modes: [.init(modeId: modeId, name: "Default")],
                    defaultModeId: modeId
                )
            ],
            variables: [
                FigmaVariable(
                    id: "V1", name: "radius/full", resolvedType: "FLOAT",
                    variableCollectionId: id, valuesByMode: [modeId: .number(9999)]
                ),
                FigmaVariable(
                    id: "V2", name: "radius/lg", resolvedType: "FLOAT",
                    variableCollectionId: id, valuesByMode: [modeId: .number(12)]
                )
            ]
        )
        let tokens = extractor.extract(from: response)
        let full = tokens.radius.first(where: { $0.figmaName == "radius/full" })
        let lg = tokens.radius.first(where: { $0.figmaName == "radius/lg" })
        #expect(full?.isCapsule == true)
        #expect(lg?.isCapsule == false)
    }

    @Test("No variables → warning, empty token set")
    func emptyResponse() {
        let response = FigmaVariablesResponse(
            status: 404, error: true, message: "not enabled",
            meta: nil
        )
        let tokens = extractor.extract(from: response)
        #expect(tokens.colors.isEmpty)
        #expect(!tokens.warnings.isEmpty)
    }

    // MARK: - Helpers
    private func makeResponse(
        collections: [FigmaVariableCollection],
        variables: [FigmaVariable]
    ) -> FigmaVariablesResponse {
        let collectionDict = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        let varDict = Dictionary(uniqueKeysWithValues: variables.map { ($0.id, $0) })
        return FigmaVariablesResponse(
            status: 200,
            error: false,
            message: nil,
            meta: .init(variables: varDict, variableCollections: collectionDict)
        )
    }
}

