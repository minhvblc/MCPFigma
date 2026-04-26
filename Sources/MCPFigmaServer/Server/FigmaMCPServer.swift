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
            version: "0.1.0",
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

    private static func kindString(_ kind: AssetKind) -> String {
        switch kind {
        case .icon: return "icon"
        case .image: return "image"
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
