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
            case "figma_extract_fills":
                return try await handleExtractFills(args: args, api: api)
            default:
                return errorResult("Tool không hỗ trợ: \(params.name)")
            }
        } catch let error as FigmaAPIError {
            // P0-2: surface forbidden / unauthorized with concrete fallback steps.
            return errorResult(Self.humanReadable(error, toolName: params.name))
        } catch {
            return errorResult("Lỗi không xác định: \(error)")
        }
    }

    /// P0-2 human-readable mapping for FigmaAPIError. The default `\(error)`
    /// stringification ("forbidden") gave callers nothing actionable. This
    /// returns: what failed, why (best-guess from HTTP status), and a list of
    /// fallback workflows the caller can try.
    static func humanReadable(_ error: FigmaAPIError, toolName: String) -> String {
        switch error {
        case .missingToken:
            return "FIGMA_API_MISSING_TOKEN: FIGMA_ACCESS_TOKEN env var not set on the MCP server. " +
                "Edit ~/.claude/mcp.json → mcpServers.figma-assets.env.FIGMA_ACCESS_TOKEN."
        case .unauthorized:
            return "FIGMA_API_UNAUTHORIZED (401): the access token is invalid or expired. " +
                "Generate a new Personal Access Token at https://www.figma.com/settings/tokens and " +
                "update ~/.claude/mcp.json. Restart Claude Code after editing."
        case .forbidden:
            // Most common cause: hitting `/v1/files/<key>/variables/local` on a
            // non-Enterprise plan, OR the token's owner lacks edit-access to
            // the file. Return tool-specific fallback advice.
            let toolSpecific: String
            if toolName == "figma_extract_tokens" {
                toolSpecific = """

                Fallback for figma_extract_tokens:
                  1. Local variables API requires Figma Enterprise OR the file owner must publish variables to a Team library.
                  2. If neither applies, skip tokens.json and:
                     a) Run figma_extract_fills on the style-guide node to grab color tokens manually.
                     b) Read get_design_context on each token node and parse hex literals.
                  3. tokens.json with empty colors[] is acceptable when usesIKAssetSymbol=false in c1-conventions.json.
                """
            } else {
                toolSpecific = """

                Fallback for \(toolName):
                  - Verify the token has access to file <fileKey>. The file owner must add the token's user as a viewer/editor.
                  - If the file is shared by link only (no team), the variables/styles endpoints will 403.
                """
            }
            return "FIGMA_API_FORBIDDEN (403): server refused the request." + toolSpecific
        case .notFound:
            return "FIGMA_API_NOT_FOUND (404): node or file not found. Verify the fileKey and nodeId. " +
                "If the URL is figma.com/design/<key>/<file>?node-id=1-2, nodeId is '1:2' (replace '-' with ':')."
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { "\(Int($0))s" } ?? "the server-provided Retry-After"
            return "FIGMA_API_RATE_LIMITED (429): wait \(wait) and retry. Reduce parallel calls below 3 if hitting often."
        case .serverError(let code):
            return "FIGMA_API_SERVER_ERROR (\(code)): transient. Retry in 30s. If persistent, check https://status.figma.com."
        case .figmaError(let msg):
            return "FIGMA_API_ERROR: \(msg)"
        case .invalidResponse:
            return "FIGMA_API_INVALID_RESPONSE: response body did not decode. Likely a Figma API schema change; report to MCPFigma maintainer."
        case .network(let msg):
            return "FIGMA_API_NETWORK_ERROR: \(msg). Check connectivity to api.figma.com."
        case .exhaustedRetries(let lastStatus):
            return "FIGMA_API_EXHAUSTED_RETRIES: gave up after RetryPolicy max attempts. Last status: \(lastStatus.map(String.init) ?? "n/a")."
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
        // P0-3: pagination + summary mode flags. summaryOnly drops the heavy
        // taggedAssets[] body, returning only counts + first 10 samples — useful
        // when the caller just wants to know "how many screens / what convention?"
        // without burning context on 300+ asset entries.
        let summaryOnly = args["summaryOnly"]?.boolValue ?? false
        let pageSize = args["pageSize"]?.intValue
        let cursor = args["cursor"]?.intValue ?? 0

        let response = try await api.fetchNodes(fileKey: fileKey, nodeId: nodeId, depth: depth)
        guard let root = response.nodes[nodeId]?.document else {
            return errorResult("Không tìm thấy node \(nodeId) trong file \(fileKey).")
        }

        // P1-1: parse renameRules and build a custom scanner if provided.
        let customRules = parseRenameRules(args["renameRules"])
        let effectiveScanner: AssetScanner
        if customRules.isEmpty {
            effectiveScanner = scanner
        } else {
            effectiveScanner = AssetScanner(rewriter: AssetNameRewriter(customRules: customRules))
        }
        let builder = RegistryBuilder(scanner: effectiveScanner)
        let registry = builder.build(rootNode: root)

        // P0-3: slice taggedAssets when pageSize is provided. When summaryOnly
        // is true AND pageSize is unset, default to a 10-row sample. nextCursor
        // is set only when there are more rows to fetch.
        let totalTaggedAssets = registry.taggedAssets.count
        let effectivePageSize: Int? = {
            if let pageSize, pageSize > 0 { return pageSize }
            if summaryOnly { return 10 }
            return nil
        }()
        let pagedAssets: [FoundAsset]
        var nextCursor: Int? = nil
        if let limit = effectivePageSize {
            let start = max(0, cursor)
            let end = min(totalTaggedAssets, start + limit)
            pagedAssets = Array(registry.taggedAssets[start..<end])
            if end < totalTaggedAssets { nextCursor = end }
        } else {
            pagedAssets = registry.taggedAssets
        }

        // P1-2: recommended-next-call hint. Walks the caller through the most
        // likely follow-up so they don't have to re-read the SKILL.md.
        let recommendedNext = Self.makeRegistryRecommendation(registry: registry, fileKey: fileKey)

        let payload = RegistryOutput(
            rootNode: .init(nodeId: registry.rootNodeId, name: registry.rootName, type: registry.rootType),
            screens: registry.screens.map { mapScreen($0) },
            candidateScreens: registry.candidateScreens.map { mapScreen($0) },
            taggedAssets: pagedAssets.map {
                RegistryOutput.TaggedAsset(
                    nodeId: $0.nodeId,
                    figmaName: $0.figmaName,
                    kind: kindString($0.kind),
                    exportName: $0.renamed
                )
            },
            taggedAssetsTotalCount: totalTaggedAssets,
            nextCursor: nextCursor,
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
            },
            recommendedNextCall: recommendedNext
        )
        return .init(content: [text(try JSONOutput.encode(payload))], isError: false)
    }

    /// P1-1: parse `renameRules` array arg into typed RenameRule list.
    /// Schema:
    ///   "renameRules": [{
    ///     "figmaPrefix": "ic/",
    ///     "renamedPrefix": "icAI",
    ///     "kind": "icon" | "image" | "animation"
    ///   }, ...]
    /// Invalid entries are skipped silently (logged via warnings is overkill
    /// for an off-by-default feature).
    private static func parseRenameRules(_ value: Value?) -> [RenameRule] {
        guard let raw = value?.arrayValue else { return [] }
        var out: [RenameRule] = []
        for entry in raw {
            guard let dict = entry.objectValue,
                  let figmaPrefix = dict["figmaPrefix"]?.stringValue,
                  let renamedPrefix = dict["renamedPrefix"]?.stringValue,
                  let kindRaw = dict["kind"]?.stringValue,
                  !figmaPrefix.isEmpty,
                  !renamedPrefix.isEmpty else {
                continue
            }
            let kind: AssetKind
            switch kindRaw {
            case "icon": kind = .icon
            case "image": kind = .image
            case "animation": kind = .animation
            default: continue
            }
            out.append(RenameRule(figmaPrefix: figmaPrefix, renamedPrefix: renamedPrefix, kind: kind))
        }
        return out
    }

    /// Map a ScreenInfo from the core registry into the wire ScreenInfo.
    /// Extracted so both `screens` and `candidateScreens` share the conversion.
    private static func mapScreen(_ info: ScreenInfo) -> RegistryOutput.Screen {
        RegistryOutput.Screen(
            nodeId: info.nodeId,
            name: info.name,
            type: info.type,
            width: info.width,
            height: info.height,
            depth: info.depth
        )
    }

    /// P1-2. Inspect the registry and emit the next-most-useful call. Three
    /// branches:
    ///   1. screens populated → recommend fetch design context per screen
    ///   2. candidateScreens populated → recommend export_assets_unified per
    ///      candidate so user gets icons even without a clean Board root
    ///   3. nothing at all → suggest re-rooting on a CANVAS/PAGE ancestor
    private static func makeRegistryRecommendation(
        registry: Registry,
        fileKey: String
    ) -> RegistryOutput.NextCall? {
        if !registry.screens.isEmpty {
            return RegistryOutput.NextCall(
                tool: "figma_export_assets_unified",
                rationale: "Found \(registry.screens.count) direct screen(s). " +
                    "Run export_assets_unified per screen with autoDiscover=true to populate Assets.xcassets.",
                argsTemplate: [
                    "fileKey": fileKey,
                    "nodeId": "<each screen.nodeId>",
                    "outputDir": "<absolute project path>",
                    "sharedAssetsDir": "<absolute path under .figma-cache/_shared/assets>",
                    "autoDiscover": "true"
                ]
            )
        }
        if !registry.candidateScreens.isEmpty {
            return RegistryOutput.NextCall(
                tool: "figma_export_assets_unified",
                rationale: "Root is a Group — direct screens empty. Use the \(registry.candidateScreens.count) " +
                    "candidateScreens nodeIds as input. STOP before code-gen until each candidate has had its " +
                    "design-context + screenshot fetched and verified.",
                argsTemplate: [
                    "fileKey": fileKey,
                    "nodeId": "<each candidateScreens.nodeId>",
                    "outputDir": "<absolute project path>",
                    "sharedAssetsDir": "<absolute path under .figma-cache/_shared/assets>",
                    "autoDiscover": "true"
                ]
            )
        }
        return RegistryOutput.NextCall(
            tool: "figma_build_registry",
            rationale: "Neither screens nor candidateScreens found. Re-root on a CANVAS/PAGE/DOCUMENT " +
                "ancestor. Use get_metadata at depth=1 on the file page to identify the right rootNodeId.",
            argsTemplate: [
                "fileKey": fileKey,
                "nodeId": "<a CANVAS or PAGE ancestor of the current node>",
                "depth": "5"
            ]
        )
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

    static func handleExtractFills(
        args: [String: Value],
        api: FigmaAPI
    ) async throws -> CallTool.Result {
        guard let fileKey = args["fileKey"]?.stringValue, !fileKey.isEmpty else {
            return errorResult("Thiếu tham số 'fileKey'.")
        }
        guard let nodeId = args["nodeId"]?.stringValue, !nodeId.isEmpty else {
            return errorResult("Thiếu tham số 'nodeId'.")
        }
        let depth = args["depth"]?.intValue ?? 10
        let resolveURLs = args["resolveImageUrls"]?.boolValue ?? true

        let response = try await api.fetchNodes(fileKey: fileKey, nodeId: nodeId, depth: depth)
        let documents: [String: FigmaNode] = response.nodes.reduce(into: [:]) { acc, pair in
            acc[pair.key] = pair.value.document
        }
        if documents.isEmpty {
            return errorResult("Không tìm thấy node \(nodeId) trong file \(fileKey).")
        }

        var imageRefURLs: [String: String] = [:]
        var imageResolutionWarnings: [String] = []
        if resolveURLs {
            do {
                let imagesResponse = try await api.fetchFileImages(fileKey: fileKey)
                imageRefURLs = imagesResponse.meta?.images ?? [:]
            } catch let error as FigmaAPIError {
                imageResolutionWarnings.append(
                    "/v1/files/\(fileKey)/images lỗi: \(error). IMAGE fills sẽ không kèm imageUrl."
                )
            }
        }

        let result = FillExtractor().extract(nodes: documents, imageRefURLs: imageRefURLs)
        let payload = FillsOutput(
            fileKey: fileKey,
            rootNodeId: nodeId,
            nodes: result.nodes.map(FillsOutput.Node.init),
            warnings: result.warnings + imageResolutionWarnings
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
        /// 0 = root itself, 1+ = nested. Only meaningful for candidateScreens.
        let depth: Int
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
    /// P1-2 next-call hint — server-side recommendation, replaces the
    /// "what do I call next?" decision the SKILL.md used to embed.
    struct NextCall: Encodable {
        let tool: String
        let rationale: String
        let argsTemplate: [String: String]
    }
    let rootNode: RootNode
    let screens: [Screen]
    /// P0-1: phone-sized FRAMEs found nested under a non-Board root (Group).
    /// Empty when `screens` is populated. Consumers should treat these as
    /// recoverable input and feed each nodeId back into export_assets_unified
    /// / get_design_context calls per screen.
    let candidateScreens: [Screen]
    let taggedAssets: [TaggedAsset]
    /// P0-3: total before pagination. taggedAssets[] may be a slice.
    let taggedAssetsTotalCount: Int
    /// P0-3: cursor for the next page, nil when exhausted.
    let nextCursor: Int?
    let lottiePlaceholders: [Lottie]
    let warnings: [Warning]
    let recommendedNextCall: NextCall?
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

// MARK: - Fills output

struct FillsOutput: Encodable {
    let fileKey: String
    let rootNodeId: String
    let nodes: [Node]
    let warnings: [String]

    struct Node: Encodable {
        let nodeId: String
        let nodeName: String
        let nodeType: String
        let width: Double?
        let height: Double?
        let fills: [Fill]

        init(_ n: MCPFigmaCore.NodeFills) {
            self.nodeId = n.nodeId
            self.nodeName = n.nodeName
            self.nodeType = n.nodeType
            self.width = n.width
            self.height = n.height
            self.fills = n.fills.map(Fill.init)
        }
    }

    struct Fill: Encodable {
        // `type` is the discriminator: "solid" | "gradient" | "image" | "unsupported".
        // All optional fields below are populated based on `type`.
        let type: String
        let opacity: Double
        let visible: Bool
        let blendMode: String?
        // SOLID:
        let hex: String?
        // GRADIENT:
        let kind: String?
        let stops: [Stop]?
        let startPoint: Point?
        let endPoint: Point?
        let widthPoint: Point?
        // IMAGE:
        let imageRef: String?
        let scaleMode: String?
        let imageUrl: String?
        // UNSUPPORTED:
        let rawType: String?

        init(_ spec: MCPFigmaCore.FillSpec) {
            switch spec {
            case .solid(let s):
                self.type = "solid"
                self.opacity = s.opacity
                self.visible = s.visible
                self.blendMode = s.blendMode
                self.hex = s.hex
                self.kind = nil; self.stops = nil
                self.startPoint = nil; self.endPoint = nil; self.widthPoint = nil
                self.imageRef = nil; self.scaleMode = nil; self.imageUrl = nil
                self.rawType = nil
            case .gradient(let g):
                self.type = "gradient"
                self.opacity = g.opacity
                self.visible = g.visible
                self.blendMode = g.blendMode
                self.hex = nil
                self.kind = g.kind.rawValue
                self.stops = g.stops.map { Stop(position: $0.position, hex: $0.hex) }
                self.startPoint = Point(x: g.startPoint.x, y: g.startPoint.y)
                self.endPoint = Point(x: g.endPoint.x, y: g.endPoint.y)
                self.widthPoint = g.widthPoint.map { Point(x: $0.x, y: $0.y) }
                self.imageRef = nil; self.scaleMode = nil; self.imageUrl = nil
                self.rawType = nil
            case .image(let i):
                self.type = "image"
                self.opacity = i.opacity
                self.visible = i.visible
                self.blendMode = i.blendMode
                self.hex = nil
                self.kind = nil; self.stops = nil
                self.startPoint = nil; self.endPoint = nil; self.widthPoint = nil
                self.imageRef = i.imageRef
                self.scaleMode = i.scaleMode
                self.imageUrl = i.imageUrl
                self.rawType = nil
            case .unsupported(let raw, let op, let vis):
                self.type = "unsupported"
                self.opacity = op
                self.visible = vis
                self.blendMode = nil
                self.hex = nil
                self.kind = nil; self.stops = nil
                self.startPoint = nil; self.endPoint = nil; self.widthPoint = nil
                self.imageRef = nil; self.scaleMode = nil; self.imageUrl = nil
                self.rawType = raw
            }
        }
    }

    struct Stop: Encodable {
        let position: Double
        let hex: String
    }

    struct Point: Encodable {
        let x: Double
        let y: Double
    }
}
