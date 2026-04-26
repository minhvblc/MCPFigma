import Testing
import Foundation
@testable import MCPFigmaCore

@Suite("AssetExporter")
struct AssetExporterTests {
    func tempDir(_ name: String = UUID().uuidString) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MCPFigmaTests-\(name)")
        try? FileManager.default.removeItem(at: dir)
        return dir
    }

    @Test("Exports matching assets at @2x and @3x, returns paths")
    func happyPath() async throws {
        let root = FigmaNode(id: "root", name: "Page", type: "CANVAS", children: [
            FigmaNode(id: "a", name: "eICHome", type: "FRAME", children: nil),
            FigmaNode(id: "b", name: "eImageBanner", type: "FRAME", children: nil),
            FigmaNode(id: "c", name: "Ignored", type: "FRAME", children: nil)
        ])
        let fake = FakeFigmaAPI(
            nodes: makeResponse(rootId: "root", node: root),
            imagesByScale: [
                2: ["a": URL(string: "https://cdn/a@2x.png")!, "b": URL(string: "https://cdn/b@2x.png")!],
                3: ["a": URL(string: "https://cdn/a@3x.png")!, "b": URL(string: "https://cdn/b@3x.png")!]
            ],
            downloads: [
                URL(string: "https://cdn/a@2x.png")!: Data([0xA2]),
                URL(string: "https://cdn/a@3x.png")!: Data([0xA3]),
                URL(string: "https://cdn/b@2x.png")!: Data([0xB2]),
                URL(string: "https://cdn/b@3x.png")!: Data([0xB3])
            ]
        )
        let out = tempDir()
        defer { try? FileManager.default.removeItem(at: out) }

        let exporter = AssetExporter(api: fake, downloadConcurrency: 2)
        let summary = try await exporter.export(fileKey: "k", rootNodeId: "root", outputDir: out)

        #expect(summary.savedFiles.count == 4)
        #expect(summary.errors.isEmpty)
        let names = Set(summary.savedFiles.map { ($0.path as NSString).lastPathComponent })
        #expect(names == [
            "icAIHome@2x.png", "icAIHome@3x.png",
            "imageAIBanner@2x.png", "imageAIBanner@3x.png"
        ])
        for file in summary.savedFiles {
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("Collision: duplicate renamed gets _2 suffix")
    func collisionGetsSuffix() async throws {
        let root = FigmaNode(id: "root", name: "Page", type: "CANVAS", children: [
            FigmaNode(id: "a", name: "eICHome", type: "FRAME", children: nil),
            FigmaNode(id: "b", name: "eICHome", type: "FRAME", children: nil)
        ])
        let fake = FakeFigmaAPI(
            nodes: makeResponse(rootId: "root", node: root),
            imagesByScale: [
                2: ["a": URL(string: "https://cdn/a.png")!, "b": URL(string: "https://cdn/b.png")!]
            ],
            downloads: [
                URL(string: "https://cdn/a.png")!: Data([0x01]),
                URL(string: "https://cdn/b.png")!: Data([0x02])
            ]
        )
        let out = tempDir()
        defer { try? FileManager.default.removeItem(at: out) }

        let exporter = AssetExporter(api: fake)
        let summary = try await exporter.export(
            fileKey: "k",
            rootNodeId: "root",
            outputDir: out,
            scales: [2]
        )

        let names = Set(summary.savedFiles.map { ($0.path as NSString).lastPathComponent })
        #expect(names == ["icAIHome@2x.png", "icAIHome_2@2x.png"])
    }

    @Test("overwrite=false skips existing files")
    func skipsExistingWhenNotOverwrite() async throws {
        let root = FigmaNode(id: "root", name: "Page", type: "CANVAS", children: [
            FigmaNode(id: "a", name: "eICHome", type: "FRAME", children: nil)
        ])
        let fake = FakeFigmaAPI(
            nodes: makeResponse(rootId: "root", node: root),
            imagesByScale: [2: ["a": URL(string: "https://cdn/a.png")!]],
            downloads: [URL(string: "https://cdn/a.png")!: Data([0x01])]
        )
        let out = tempDir()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let existing = out.appendingPathComponent("icAIHome@2x.png")
        try Data([0xFF]).write(to: existing)
        defer { try? FileManager.default.removeItem(at: out) }

        let exporter = AssetExporter(api: fake)
        let summary = try await exporter.export(
            fileKey: "k",
            rootNodeId: "root",
            outputDir: out,
            scales: [2],
            overwrite: false
        )

        #expect(summary.savedFiles.isEmpty)
        #expect(summary.skipped.count == 1)
        let keptBytes = try Data(contentsOf: existing)
        #expect(keptBytes == Data([0xFF]))
    }

    @Test("Missing render URL is reported as error")
    func missingRenderURLReported() async throws {
        let root = FigmaNode(id: "root", name: "Page", type: "CANVAS", children: [
            FigmaNode(id: "a", name: "eICHome", type: "FRAME", children: nil)
        ])
        let fake = FakeFigmaAPI(
            nodes: makeResponse(rootId: "root", node: root),
            imagesByScale: [2: [:]],
            downloads: [:]
        )
        let out = tempDir()
        defer { try? FileManager.default.removeItem(at: out) }

        let exporter = AssetExporter(api: fake)
        let summary = try await exporter.export(
            fileKey: "k",
            rootNodeId: "root",
            outputDir: out,
            scales: [2]
        )

        #expect(summary.savedFiles.isEmpty)
        #expect(summary.errors.count == 1)
        #expect(summary.errors.first?.figmaName == "eICHome")
    }

    @Test("selectedNodeIds filters which matches to export")
    func filtersSelectedIds() async throws {
        let root = FigmaNode(id: "root", name: "Page", type: "CANVAS", children: [
            FigmaNode(id: "a", name: "eICHome", type: "FRAME", children: nil),
            FigmaNode(id: "b", name: "eImageBanner", type: "FRAME", children: nil)
        ])
        let fake = FakeFigmaAPI(
            nodes: makeResponse(rootId: "root", node: root),
            imagesByScale: [2: ["a": URL(string: "https://cdn/a.png")!]],
            downloads: [URL(string: "https://cdn/a.png")!: Data([0x01])]
        )
        let out = tempDir()
        defer { try? FileManager.default.removeItem(at: out) }

        let exporter = AssetExporter(api: fake)
        let summary = try await exporter.export(
            fileKey: "k",
            rootNodeId: "root",
            outputDir: out,
            scales: [2],
            selectedNodeIds: ["a"]
        )

        #expect(summary.savedFiles.count == 1)
        #expect(summary.savedFiles.first?.figmaName == "eICHome")
    }

    @Test("Scanner warnings are propagated to summary")
    func warningsPropagated() async throws {
        let root = FigmaNode(id: "root", name: "Page", type: "CANVAS", children: [
            FigmaNode(id: "a", name: "eICHome", type: "FRAME", children: nil),
            FigmaNode(id: "b", name: "eIChome", type: "FRAME", children: nil)
        ])
        let fake = FakeFigmaAPI(
            nodes: makeResponse(rootId: "root", node: root),
            imagesByScale: [2: ["a": URL(string: "https://cdn/a.png")!]],
            downloads: [URL(string: "https://cdn/a.png")!: Data([0x01])]
        )
        let out = tempDir()
        defer { try? FileManager.default.removeItem(at: out) }

        let exporter = AssetExporter(api: fake)
        let summary = try await exporter.export(
            fileKey: "k",
            rootNodeId: "root",
            outputDir: out,
            scales: [2]
        )

        #expect(summary.warnings.count == 1)
        #expect(summary.warnings.first?.figmaName == "eIChome")
    }

    @Test("skipIfExistsInCatalog skips download when imageset đã có trong catalog")
    func skipsWhenAlreadyInCatalog() async throws {
        let root = FigmaNode(id: "root", name: "HomeScreen", type: "CANVAS", children: [
            FigmaNode(id: "a", name: "eICHome", type: "FRAME", children: nil),
            FigmaNode(id: "b", name: "eICNew", type: "FRAME", children: nil)
        ])
        let fake = FakeFigmaAPI(
            nodes: makeResponse(rootId: "root", node: root),
            imagesByScale: [2: ["b": URL(string: "https://cdn/b.png")!]],
            downloads: [URL(string: "https://cdn/b.png")!: Data([0xBB])]
        )
        let workRoot = tempDir()
        let out = workRoot.appendingPathComponent("Exports", isDirectory: true)
        let catalog = workRoot.appendingPathComponent("Assets.xcassets", isDirectory: true)
        let existingImageset = catalog
            .appendingPathComponent("OldFolder/icAIHome.imageset", isDirectory: true)
        try FileManager.default.createDirectory(at: existingImageset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        let exporter = AssetExporter(api: fake)
        let summary = try await exporter.export(
            fileKey: "k",
            rootNodeId: "root",
            outputDir: out,
            scales: [2],
            assetCatalogDir: catalog,
            skipIfExistsInCatalog: true
        )

        // icAIHome đã có sẵn → skipped, không download (file PNG không tồn tại trong outputDir)
        let savedNames = Set(summary.savedFiles.map { $0.renamed })
        let skippedNames = Set(summary.skipped.map { $0.renamed })
        #expect(savedNames == ["icAINew"])
        #expect(skippedNames == ["icAIHome"])
        #expect(!FileManager.default.fileExists(
            atPath: out.appendingPathComponent("icAIHome@2x.png").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: out.appendingPathComponent("icAINew@2x.png").path
        ))
        // icAINew là asset mới → đặt trong screen folder HomeScreen
        let newImageset = catalog.appendingPathComponent("HomeScreen/icAINew.imageset", isDirectory: true)
        #expect(FileManager.default.fileExists(
            atPath: newImageset.appendingPathComponent("icAINew@2x.png").path
        ))
    }

    private func makeResponse(rootId: String, node: FigmaNode) -> FigmaFileNodesResponse {
        let json = """
        { "name": "Test", "nodes": { "\(rootId)": { "document": \(nodeJSON(node)) } } }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(FigmaFileNodesResponse.self, from: json)
    }

    private func nodeJSON(_ node: FigmaNode) -> String {
        var fields = #""id":"\#(node.id)","name":"\#(node.name)","type":"\#(node.type)""#
        if let children = node.children {
            let childJSON = children.map { nodeJSON($0) }.joined(separator: ",")
            fields += #","children":[\#(childJSON)]"#
        }
        return "{\(fields)}"
    }
}

final class FakeFigmaAPI: FigmaAPI, @unchecked Sendable {
    let nodes: FigmaFileNodesResponse
    let imagesByScale: [Int: [String: URL]]
    let downloads: [URL: Data]

    init(
        nodes: FigmaFileNodesResponse,
        imagesByScale: [Int: [String: URL]],
        downloads: [URL: Data]
    ) {
        self.nodes = nodes
        self.imagesByScale = imagesByScale
        self.downloads = downloads
    }

    func fetchNodes(fileKey: String, nodeId: String, depth: Int?) async throws -> FigmaFileNodesResponse {
        nodes
    }

    func renderImages(fileKey: String, nodeIds: [String], scale: Int) async throws -> [String: URL] {
        guard let batch = imagesByScale[scale] else { return [:] }
        return batch.filter { nodeIds.contains($0.key) }
    }

    func download(_ url: URL) async throws -> Data {
        guard let data = downloads[url] else {
            throw FigmaAPIError.notFound
        }
        return data
    }
}
