import Foundation
import MCP
import MCPFigmaCore

struct FigmaMCPServer: Sendable {
    let api: FigmaAPI
    let scanner: AssetScanner

    init(api: FigmaAPI, scanner: AssetScanner = AssetScanner()) {
        self.api = api
        self.scanner = scanner
    }

    func run() async throws {
        let server = Server(
            name: "mcp-figma",
            version: "0.3.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        let api = self.api
        let scanner = self.scanner

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolDefinitions.all)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await Self.handleCall(params: params, api: api, scanner: scanner)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    static func handleCall(
        params: CallTool.Parameters,
        api: FigmaAPI,
        scanner: AssetScanner
    ) async -> CallTool.Result {
        let args = params.arguments ?? [:]
        do {
            switch params.name {
            case "figma_list_assets":
                return try await handleListAssets(args: args, api: api, scanner: scanner)
            case "figma_export_assets":
                return try await handleExportAssets(args: args, api: api, scanner: scanner)
            case "figma_build_registry":
                return try await handleBuildRegistry(args: args, api: api, scanner: scanner)
            case "figma_export_assets_unified":
                return try await handleExportAssetsUnified(args: args, api: api, scanner: scanner)
            case "figma_extract_tokens":
                return try await handleExtractTokens(args: args, api: api)
            default:
                return errorResult("Tool không hỗ trợ: \(params.name)")
            }
        } catch let error as FigmaAPIError {
            return errorResult("Figma API lỗi: \(error)")
        } catch {
            return errorResult("Lỗi không xác định: \(error)")
        }
    }

    static func handleListAssets(
        args: [String: Value],
        api: FigmaAPI,
        scanner: AssetScanner
    ) async throws -> CallTool.Result {
        guard let fileKey = args["fileKey"]?.stringValue, !fileKey.isEmpty else {
            return errorResult("Thiếu tham số 'fileKey'.")
        }
        guard let nodeId = args["nodeId"]?.stringValue, !nodeId.isEmpty else {
            return errorResult("Thiếu tham số 'nodeId'.")
        }
        let depth = args["depth"]?.intValue

        let response = try await api.fetchNodes(fileKey: fileKey, nodeId: nodeId, depth: depth)
        guard let root = response.nodes[nodeId]?.document else {
            return errorResult("Không tìm thấy node \(nodeId) trong file \(fileKey).")
        }

        let scanResult = scanner.scan(root)
        let payload = ListAssetsOutput(
            matches: scanResult.matches.map {
                ListAssetsOutput.Match(
                    nodeId: $0.nodeId,
                    figmaName: $0.figmaName,
                    kind: kindString($0.kind),
                    exportName: $0.renamed
                )
            },
            warnings: scanResult.warnings.map {
                ListAssetsOutput.Warning(
                    nodeId: $0.nodeId,
                    figmaName: $0.figmaName,
                    reason: $0.reason
                )
            }
        )
        return .init(content: [text(try JSONOutput.encode(payload))], isError: false)
    }

    static func handleExportAssets(
        args: [String: Value],
        api: FigmaAPI,
        scanner: AssetScanner
    ) async throws -> CallTool.Result {
        guard let fileKey = args["fileKey"]?.stringValue, !fileKey.isEmpty else {
            return errorResult("Thiếu tham số 'fileKey'.")
        }
        guard let nodeId = args["nodeId"]?.stringValue, !nodeId.isEmpty else {
            return errorResult("Thiếu tham số 'nodeId'.")
        }
        guard let outputDirString = args["outputDir"]?.stringValue, !outputDirString.isEmpty else {
            return errorResult("Thiếu tham số 'outputDir'.")
        }
        guard outputDirString.hasPrefix("/") else {
            return errorResult("'outputDir' phải là đường dẫn tuyệt đối, nhận được: \(outputDirString)")
        }
        let assetCatalogPath = args["assetCatalogPath"]?.stringValue
        let xcodeProjectPath = args["xcodeProjectPath"]?.stringValue

        let scales: [Int] = {
            if let raw = args["scales"]?.arrayValue {
                let parsed = raw.compactMap { $0.intValue }
                return parsed.isEmpty ? [2, 3] : parsed
            }
            return [2, 3]
        }()
        let overwrite = args["overwrite"]?.boolValue ?? true
        let skipIfExistsInCatalog = args["skipIfExistsInCatalog"]?.boolValue ?? true
        let selectedIds: Set<String>? = {
            guard let raw = args["nodeIds"]?.arrayValue else { return nil }
            let ids = raw.compactMap { $0.stringValue }
            return ids.isEmpty ? nil : Set(ids)
        }()
        let assetCatalogDir = try AssetCatalogResolver().resolve(
            assetCatalogPath: assetCatalogPath,
            xcodeProjectPath: xcodeProjectPath
        )

        let exporter = AssetExporter(api: api, scanner: scanner)
        let summary = try await exporter.export(
            fileKey: fileKey,
            rootNodeId: nodeId,
            outputDir: URL(fileURLWithPath: outputDirString, isDirectory: true),
            scales: scales,
            overwrite: overwrite,
            selectedNodeIds: selectedIds,
            assetCatalogDir: assetCatalogDir,
            skipIfExistsInCatalog: skipIfExistsInCatalog
        )

        let payload = ExportSummaryOutput(
            savedFiles: summary.savedFiles.map {
                ExportSummaryOutput.SavedFile(
                    figmaName: $0.figmaName,
                    exportName: $0.renamed,
                    scale: $0.scale,
                    path: $0.path
                )
            },
            skipped: summary.skipped.map {
                ExportSummaryOutput.SavedFile(
                    figmaName: $0.figmaName,
                    exportName: $0.renamed,
                    scale: $0.scale,
                    path: $0.path
                )
            },
            errors: summary.errors.map {
                ExportSummaryOutput.Failure(figmaName: $0.figmaName, reason: $0.reason)
            },
            warnings: summary.warnings.map {
                ExportSummaryOutput.Warning(
                    nodeId: $0.nodeId,
                    figmaName: $0.figmaName,
                    reason: $0.reason
                )
            },
            assetCatalog: summary.assetCatalogImport.map {
                ExportSummaryOutput.AssetCatalogImport(
                    catalogPath: $0.catalogPath,
                    savedFiles: $0.savedFiles.map {
                        ExportSummaryOutput.SavedFile(
                            figmaName: $0.figmaName,
                            exportName: $0.renamed,
                            scale: $0.scale,
                            path: $0.path
                        )
                    },
                    skipped: $0.skipped.map {
                        ExportSummaryOutput.SavedFile(
                            figmaName: $0.figmaName,
                            exportName: $0.renamed,
                            scale: $0.scale,
                            path: $0.path
                        )
                    },
                    errors: $0.errors.map {
                        ExportSummaryOutput.Failure(figmaName: $0.figmaName, reason: $0.reason)
                    }
                )
            }
        )
        return .init(
            content: [text(try JSONOutput.encode(payload))],
            isError: !summary.errors.isEmpty || !(summary.assetCatalogImport?.errors.isEmpty ?? true)
        )
    }

    static func handleBuildRegistry(
        args: [String: Value],
        api: FigmaAPI,
        scanner: AssetScanner
    ) async throws -> CallTool.Result {
        guard let fileKey = args["fileKey"]?.stringValue, !fileKey.isEmpty else {
            return errorResult("Thiếu tham số 'fileKey'.")
        }
        guard let nodeId = args["nodeId"]?.stringValue, !nodeId.isEmpty else {
            return errorResult("Thiếu tham số 'nodeId'.")
        }
        let depth = args["depth"]?.intValue ?? 10

        let response = try await api.fetchNodes(fileKey: fileKey, nodeId: nodeId, depth: depth)
        guard let root = response.nodes[nodeId]?.document else {
            return errorResult("Không tìm thấy node \(nodeId) trong file \(fileKey).")
        }

        let builder = RegistryBuilder(scanner: scanner)
        let registry = builder.build(rootNode: root)

        let payload = RegistryOutput(
            rootNode: .init(nodeId: registry.rootNodeId, name: registry.rootName, type: registry.rootType),
            screens: registry.screens.map {
                RegistryOutput.Screen(
                    nodeId: $0.nodeId,
                    name: $0.name,
                    type: $0.type,
                    width: $0.width,
                    height: $0.height
                )
            },
            taggedAssets: registry.taggedAssets.map {
                RegistryOutput.TaggedAsset(
                    nodeId: $0.nodeId,
                    figmaName: $0.figmaName,
                    kind: kindString($0.kind),
                    exportName: $0.renamed
                )
            },
            lottiePlaceholders: registry.lottiePlaceholders.map {
                RegistryOutput.Lottie(
                    nodeId: $0.nodeId,
                    figmaName: $0.figmaName,
                    width: $0.width,
                    height: $0.height
                )
            },
            warnings: registry.warnings.map {
                RegistryOutput.Warning(
                    nodeId: $0.nodeId,
                    figmaName: $0.figmaName,
                    reason: $0.reason
                )
            }
        )
        return .init(content: [text(try JSONOutput.encode(payload))], isError: false)
    }

    static func handleExportAssetsUnified(
        args: [String: Value],
        api: FigmaAPI,
        scanner: AssetScanner
    ) async throws -> CallTool.Result {
        guard let fileKey = args["fileKey"]?.stringValue, !fileKey.isEmpty else {
            return errorResult("Thiếu tham số 'fileKey'.")
        }
        guard let nodeId = args["nodeId"]?.stringValue, !nodeId.isEmpty else {
            return errorResult("Thiếu tham số 'nodeId'.")
        }
        guard let outputDirString = args["outputDir"]?.stringValue, !outputDirString.isEmpty else {
            return errorResult("Thiếu tham số 'outputDir'.")
        }
        guard outputDirString.hasPrefix("/") else {
            return errorResult("'outputDir' phải là đường dẫn tuyệt đối, nhận được: \(outputDirString)")
        }
        guard let sharedDirString = args["sharedAssetsDir"]?.stringValue, !sharedDirString.isEmpty else {
            return errorResult("Thiếu tham số 'sharedAssetsDir'.")
        }
        guard sharedDirString.hasPrefix("/") else {
            return errorResult("'sharedAssetsDir' phải là đường dẫn tuyệt đối, nhận được: \(sharedDirString)")
        }
        let autoDiscover = args["autoDiscover"]?.boolValue ?? false
        let rawRows = args["rows"]?.arrayValue ?? []
        if rawRows.isEmpty && !autoDiscover {
            return errorResult("Thiếu hoặc rỗng 'rows' — phải có ít nhất 1 row hoặc bật 'autoDiscover'.")
        }

        var parsedRows: [UnifiedExportRow] = []
        for raw in rawRows {
            guard let dict = raw.objectValue,
                  let nodeIdValue = dict["nodeId"]?.stringValue,
                  let exporterRaw = dict["exporter"]?.stringValue,
                  let exporter = UnifiedRowExporter(rawValue: exporterRaw) else {
                return errorResult("Row không hợp lệ — thiếu 'nodeId' hoặc 'exporter' (tagged|fallback).")
            }
            let strategy: UnifiedRowStrategy = {
                if let raw = dict["strategy"]?.stringValue,
                   let parsed = UnifiedRowStrategy(rawValue: raw) {
                    return parsed
                }
                return .atomic
            }()
            parsedRows.append(UnifiedExportRow(
                nodeId: nodeIdValue,
                exporter: exporter,
                exportName: dict["exportName"]?.stringValue,
                friendlyName: dict["friendlyName"]?.stringValue,
                strategy: strategy
            ))
        }

        let scales: [Int] = {
            if let raw = args["scales"]?.arrayValue {
                let parsed = raw.compactMap { $0.intValue }
                return parsed.isEmpty ? [2, 3] : parsed
            }
            return [2, 3]
        }()
        let fallbackScale = args["fallbackScale"]?.intValue ?? 3
        let overwrite = args["overwrite"]?.boolValue ?? true
        let skipIfExistsInCatalog = args["skipIfExistsInCatalog"]?.boolValue ?? true

        let assetCatalogPath = args["assetCatalogPath"]?.stringValue
        let assetCatalogDir = try AssetCatalogResolver().resolve(
            assetCatalogPath: assetCatalogPath,
            xcodeProjectPath: nil
        )

        let exporter = UnifiedExporter(api: api, scanner: scanner)
        let summary = try await exporter.export(
            fileKey: fileKey,
            rootNodeId: nodeId,
            rows: parsedRows,
            outputDir: URL(fileURLWithPath: outputDirString, isDirectory: true),
            sharedAssetsDir: URL(fileURLWithPath: sharedDirString, isDirectory: true),
            assetCatalogDir: assetCatalogDir,
            scales: scales,
            fallbackScale: fallbackScale,
            overwrite: overwrite,
            skipIfExistsInCatalog: skipIfExistsInCatalog,
            autoDiscover: autoDiscover
        )

        let payload = UnifiedExportOutput(
            rows: summary.rows.map {
                UnifiedExportOutput.Row(
                    nodeId: $0.nodeId,
                    exporter: $0.exporter.rawValue,
                    strategy: $0.strategy.rawValue,
                    status: $0.status.rawValue,
                    exportName: $0.exportName,
                    friendlyName: $0.friendlyName,
                    outputPath: $0.outputPath,
                    imagesetPath: $0.imagesetPath,
                    xcassetsImported: $0.xcassetsImported,
                    sharedPath: $0.sharedPath,
                    reason: $0.reason
                )
            },
            warnings: summary.warnings.map {
                UnifiedExportOutput.Warning(
                    nodeId: $0.nodeId,
                    figmaName: $0.figmaName,
                    reason: $0.reason
                )
            },
            assetCatalogPath: summary.assetCatalogPath,
            coverage: summary.coverage.map {
                UnifiedExportOutput.Coverage(
                    discoveredCount: $0.discoveredCount,
                    exportedCount: $0.exportedCount,
                    autoAddedRows: $0.autoAddedRows,
                    skippedNodeIds: $0.skippedNodeIds,
                    animationNodeIds: $0.animationNodeIds
                )
            }
        )
        let hasFailure = summary.rows.contains { $0.status == .failed }
        return .init(content: [text(try JSONOutput.encode(payload))], isError: hasFailure)
    }

    static func handleExtractTokens(
        args: [String: Value],
        api: FigmaAPI
    ) async throws -> CallTool.Result {
        guard let fileKey = args["fileKey"]?.stringValue, !fileKey.isEmpty else {
            return errorResult("Thiếu tham số 'fileKey'.")
        }

        let response = try await api.fetchVariables(fileKey: fileKey)
        let extractor = TokenExtractor()
        let variableTokens = extractor.extract(from: response)

        // Typography pass: /styles → batched /nodes → TextStyleExtractor.
        // Failures here add a warning but never block variable token output.
        var typography: [TypographyToken] = []
        var typographyWarnings: [String] = []
        do {
            let stylesResponse = try await api.fetchStyles(fileKey: fileKey)
            let textNodeIds = stylesResponse.meta?.styles
                .filter { $0.styleType == "TEXT" && !$0.nodeId.isEmpty }
                .map { $0.nodeId } ?? []
            let nodesResponse: FigmaFileNodesResponse?
            if textNodeIds.isEmpty {
                nodesResponse = nil
            } else {
                nodesResponse = try await api.fetchNodes(
                    fileKey: fileKey,
                    nodeIds: textNodeIds,
                    depth: nil
                )
            }
            let textResult = TextStyleExtractor().extract(
                styles: stylesResponse,
                nodes: nodesResponse
            )
            typography = textResult.typography
            typographyWarnings = textResult.warnings
        } catch let error as FigmaAPIError {
            typographyWarnings = [
                "Typography pass bỏ qua — Figma /styles trả lỗi: \(error)"
            ]
        }

        let combinedWarnings = variableTokens.warnings + typographyWarnings

        let payload = TokensOutput(
            colors: variableTokens.colors.map {
                TokensOutput.ColorToken(
                    figmaName: $0.figmaName,
                    swiftName: $0.swiftName,
                    lightHex: $0.lightHex,
                    darkHex: $0.darkHex
                )
            },
            spacing: variableTokens.spacing.map(TokensOutput.NumberToken.init),
            radius: variableTokens.radius.map(TokensOutput.NumberToken.init),
            opacity: variableTokens.opacity.map(TokensOutput.NumberToken.init),
            other: variableTokens.other.map(TokensOutput.NumberToken.init),
            typography: typography.map(TokensOutput.TypographyToken.init),
            warnings: combinedWarnings
        )
        return .init(content: [text(try JSONOutput.encode(payload))], isError: false)
    }

    private static func kindString(_ kind: AssetKind) -> String {
        switch kind {
        case .icon: return "icon"
        case .image: return "image"
        case .animation: return "animation"
        }
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [text(message)], isError: true)
    }

    private static func text(_ message: String) -> Tool.Content {
        .text(text: message, annotations: nil, _meta: nil)
    }
}

struct ListAssetsOutput: Encodable {
    struct Match: Encodable {
        let nodeId: String
        let figmaName: String
        let kind: String
        let exportName: String
    }
    struct Warning: Encodable {
        let nodeId: String
        let figmaName: String
        let reason: String
    }
    let matches: [Match]
    let warnings: [Warning]
}

struct ExportSummaryOutput: Encodable {
    struct SavedFile: Encodable {
        let figmaName: String
        let exportName: String
        let scale: Int
        let path: String
    }
    struct Failure: Encodable {
        let figmaName: String
        let reason: String
    }
    struct Warning: Encodable {
        let nodeId: String
        let figmaName: String
        let reason: String
    }
    struct AssetCatalogImport: Encodable {
        let catalogPath: String
        let savedFiles: [SavedFile]
        let skipped: [SavedFile]
        let errors: [Failure]
    }
    let savedFiles: [SavedFile]
    let skipped: [SavedFile]
    let errors: [Failure]
    let warnings: [Warning]
    let assetCatalog: AssetCatalogImport?
}

enum JSONOutput {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Registry output

struct RegistryOutput: Encodable {
    struct RootNode: Encodable {
        let nodeId: String
        let name: String
        let type: String
    }
    struct Screen: Encodable {
        let nodeId: String
        let name: String
        let type: String
        let width: Double?
        let height: Double?
    }
    struct TaggedAsset: Encodable {
        let nodeId: String
        let figmaName: String
        let kind: String
        let exportName: String
    }
    struct Lottie: Encodable {
        let nodeId: String
        let figmaName: String
        let width: Double?
        let height: Double?
    }
    struct Warning: Encodable {
        let nodeId: String
        let figmaName: String
        let reason: String
    }
    let rootNode: RootNode
    let screens: [Screen]
    let taggedAssets: [TaggedAsset]
    let lottiePlaceholders: [Lottie]
    let warnings: [Warning]
}

// MARK: - Unified export output

struct UnifiedExportOutput: Encodable {
    struct Row: Encodable {
        let nodeId: String
        let exporter: String
        let strategy: String
        let status: String
        let exportName: String?
        let friendlyName: String?
        let outputPath: String?
        let imagesetPath: String?
        let xcassetsImported: Bool
        let sharedPath: String?
        let reason: String?
    }
    struct Warning: Encodable {
        let nodeId: String
        let figmaName: String
        let reason: String
    }
    struct Coverage: Encodable {
        let discoveredCount: Int
        let exportedCount: Int
        let autoAddedRows: [String]
        let skippedNodeIds: [String]
        let animationNodeIds: [String]
    }
    let rows: [Row]
    let warnings: [Warning]
    let assetCatalogPath: String?
    let coverage: Coverage?
}

// MARK: - Tokens output

struct TokensOutput: Encodable {
    struct ColorToken: Encodable {
        let figmaName: String
        let swiftName: String
        let lightHex: String?
        let darkHex: String?
    }
    struct NumberToken: Encodable {
        let figmaName: String
        let swiftName: String
        let value: Double
        let isCapsule: Bool

        init(figmaName: String, swiftName: String, value: Double, isCapsule: Bool) {
            self.figmaName = figmaName
            self.swiftName = swiftName
            self.value = value
            self.isCapsule = isCapsule
        }

        init(_ token: MCPFigmaCore.NumberToken) {
            self.figmaName = token.figmaName
            self.swiftName = token.swiftName
            self.value = token.value
            self.isCapsule = token.isCapsule
        }
    }
    struct TypographyToken: Encodable {
        let figmaName: String
        let swiftName: String
        let fontFamily: String?
        let fontPostScriptName: String?
        let fontWeight: Int?
        let fontSize: Double?
        let lineHeightPx: Double?
        let letterSpacing: Double?
        let textCase: String?
        let textAlignHorizontal: String?
        let italic: Bool

        init(_ t: MCPFigmaCore.TypographyToken) {
            self.figmaName = t.figmaName
            self.swiftName = t.swiftName
            self.fontFamily = t.fontFamily
            self.fontPostScriptName = t.fontPostScriptName
            self.fontWeight = t.fontWeight
            self.fontSize = t.fontSize
            self.lineHeightPx = t.lineHeightPx
            self.letterSpacing = t.letterSpacing
            self.textCase = t.textCase
            self.textAlignHorizontal = t.textAlignHorizontal
            self.italic = t.italic
        }
    }
    let colors: [ColorToken]
    let spacing: [NumberToken]
    let radius: [NumberToken]
    let opacity: [NumberToken]
    let other: [NumberToken]
    let typography: [TypographyToken]
    let warnings: [String]
}
