import Testing
import Foundation
@testable import MCPFigmaCore

@Suite("UnifiedExporter")
struct UnifiedExporterTests {
    @Test("dataIsPNG accepts canonical signature, rejects SVG/XML/short data")
    func pngSignatureCheck() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let xml = Data("<?xml version=\"1.0\"?>".utf8)
        let short = Data([0x89, 0x50])
        #expect(UnifiedExporter.dataIsPNG(png) == true)
        #expect(UnifiedExporter.dataIsPNG(svg) == false)
        #expect(UnifiedExporter.dataIsPNG(xml) == false)
        #expect(UnifiedExporter.dataIsPNG(short) == false)
    }

    @Test("Fallback path: cached file in shared dir is reused, others fetched")
    func fallbackUsesSharedDedupAndFetches() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outputDir = tmp.appendingPathComponent("output", isDirectory: true)
        let sharedDir = tmp.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        // Pre-seed shared cache for nodeId 1:1 (with `:` → `_` rule)
        let cachedPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xAA])
        try cachedPNG.write(to: sharedDir.appendingPathComponent("1_1.png"))

        let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xBB])
        let api = StubFigmaAPI(
            renderURL: URL(string: "https://cdn/render-2.png")!,
            downloadData: fakePNG
        )

        let exporter = UnifiedExporter(api: api, downloadConcurrency: 2)
        let summary = try await exporter.export(
            fileKey: "abc",
            rootNodeId: "0:1",
            rows: [
                UnifiedExportRow(nodeId: "1:1", exporter: .fallback, friendlyName: "icon1"),
                UnifiedExportRow(nodeId: "2:2", exporter: .fallback, friendlyName: "icon2", strategy: .flatten)
            ],
            outputDir: outputDir,
            sharedAssetsDir: sharedDir,
            assetCatalogDir: nil,
            overwrite: false
        )

        #expect(summary.rows.count == 2)
        let oneOne = summary.rows.first { $0.nodeId == "1:1" }
        let twoTwo = summary.rows.first { $0.nodeId == "2:2" }
        #expect(oneOne?.status == .done)
        #expect(oneOne?.sharedPath?.hasSuffix("1_1.png") == true)
        #expect(twoTwo?.status == .done)
        #expect(twoTwo?.sharedPath?.hasSuffix("2_2.png") == true)
        let calls = await api.recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.nodeIds == ["2:2"])
    }

    @Test("Fallback row whose render returns SVG is marked failed (no auto local convert)")
    func fallbackRejectsNonPNG() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outputDir = tmp.appendingPathComponent("o", isDirectory: true)
        let sharedDir = tmp.appendingPathComponent("s", isDirectory: true)

        let svg = Data("<svg/>".utf8)
        let api = StubFigmaAPI(
            renderURL: URL(string: "https://cdn/x.svg")!,
            downloadData: svg
        )
        let exporter = UnifiedExporter(api: api)
        let summary = try await exporter.export(
            fileKey: "abc",
            rootNodeId: "0:1",
            rows: [UnifiedExportRow(nodeId: "1:1", exporter: .fallback, friendlyName: "x")],
            outputDir: outputDir,
            sharedAssetsDir: sharedDir,
            assetCatalogDir: nil
        )

        let row = summary.rows.first
        #expect(row?.status == .failed)
        #expect(row?.reason?.contains("PNG") == true)
    }

    @Test("Lottie placeholder rows pass through with status=done")
    func lottiePassThrough() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let api = StubFigmaAPI(
            renderURL: URL(string: "https://cdn/x.png")!,
            downloadData: Data()
        )
        let exporter = UnifiedExporter(api: api)
        let summary = try await exporter.export(
            fileKey: "abc",
            rootNodeId: "0:1",
            rows: [UnifiedExportRow(
                nodeId: "9:9",
                exporter: .fallback,
                friendlyName: "placeholder_animation",
                strategy: .lottiePlaceholder
            )],
            outputDir: tmp.appendingPathComponent("o"),
            sharedAssetsDir: tmp.appendingPathComponent("s"),
            assetCatalogDir: nil
        )
        #expect(summary.rows.count == 1)
        #expect(summary.rows.first?.status == .done)
        #expect(summary.rows.first?.strategy == .lottiePlaceholder)
        // Lottie shouldn't have hit the network
        let calls = await api.recorder.calls
        #expect(calls.isEmpty)
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Fake API

actor RenderCallRecorder {
    private(set) var calls: [StubFigmaAPI.RenderImagesCall] = []
    func record(_ call: StubFigmaAPI.RenderImagesCall) { calls.append(call) }
}

final class StubFigmaAPI: FigmaAPI, @unchecked Sendable {
    struct RenderImagesCall: Equatable {
        let fileKey: String
        let nodeIds: [String]
        let scale: Int
    }

    let recorder: RenderCallRecorder
    private let renderURL: URL
    private let downloadData: Data

    init(renderURL: URL, downloadData: Data) {
        self.renderURL = renderURL
        self.downloadData = downloadData
        self.recorder = RenderCallRecorder()
    }

    func fetchNodes(fileKey: String, nodeId: String, depth: Int?) async throws -> FigmaFileNodesResponse {
        FigmaFileNodesResponse(
            name: "fake",
            nodes: [nodeId: FigmaFileNodesResponse.NodeWrapper(
                document: FigmaNode(id: nodeId, name: "Fake", type: "FRAME")
            )]
        )
    }

    func renderImages(fileKey: String, nodeIds: [String], scale: Int) async throws -> [String: URL] {
        await recorder.record(.init(fileKey: fileKey, nodeIds: nodeIds, scale: scale))
        return Dictionary(uniqueKeysWithValues: nodeIds.map { ($0, renderURL) })
    }

    func download(_ url: URL) async throws -> Data {
        downloadData
    }

    func fetchVariables(fileKey: String) async throws -> FigmaVariablesResponse {
        FigmaVariablesResponse(status: 200, error: false, message: nil, meta: nil)
    }
}
