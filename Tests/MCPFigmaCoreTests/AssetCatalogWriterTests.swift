import Foundation
import Testing
@testable import MCPFigmaCore

@Suite("AssetCatalogWriter")
struct AssetCatalogWriterTests {
    func tempDir(_ name: String = UUID().uuidString) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MCPFigmaCatalogWriter-\(name)")
        try? FileManager.default.removeItem(at: dir)
        return dir
    }

    @Test("imports only icons into imagesets")
    func importsOnlyIcons() throws {
        let root = tempDir()
        let source = root.appendingPathComponent("Exports", isDirectory: true)
        let catalog = root.appendingPathComponent("Assets.xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data([0x02]).write(to: source.appendingPathComponent("icAIHome@2x.png"))
        try Data([0x03]).write(to: source.appendingPathComponent("icAIHome@3x.png"))
        try Data([0x12]).write(to: source.appendingPathComponent("imageAIBanner@2x.png"))

        let summary = try AssetCatalogWriter().importIcons(
            assets: [
                ResolvedExportedAsset(nodeId: "a", figmaName: "eICHome", kind: .icon, finalName: "icAIHome"),
                ResolvedExportedAsset(nodeId: "b", figmaName: "eImageBanner", kind: .image, finalName: "imageAIBanner")
            ],
            scales: [2, 3],
            sourceDir: source,
            assetCatalogDir: catalog,
            overwrite: true
        )

        let imageset = catalog.appendingPathComponent("icAIHome.imageset", isDirectory: true)
        #expect(summary.savedFiles.count == 2)
        #expect(summary.errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: imageset.appendingPathComponent("icAIHome@2x.png").path))
        #expect(FileManager.default.fileExists(atPath: imageset.appendingPathComponent("icAIHome@3x.png").path))
        #expect(!FileManager.default.fileExists(atPath: catalog.appendingPathComponent("imageAIBanner.imageset").path))
    }

    @Test("preserves existing contents and skips existing file when overwrite false")
    func preservesContentsWhenSkipping() throws {
        let root = tempDir()
        let source = root.appendingPathComponent("Exports", isDirectory: true)
        let catalog = root.appendingPathComponent("Assets.xcassets", isDirectory: true)
        let imageset = catalog.appendingPathComponent("icAIHome.imageset", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imageset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data([0x20]).write(to: source.appendingPathComponent("icAIHome@2x.png"))
        try Data([0x30]).write(to: source.appendingPathComponent("icAIHome@3x.png"))
        try Data([0x99]).write(to: imageset.appendingPathComponent("icAIHome@2x.png"))
        let existingContents = """
        {
          "images" : [
            { "filename" : "icAIHome.png", "idiom" : "universal", "scale" : "1x" },
            { "filename" : "icAIHome@2x.png", "idiom" : "universal", "scale" : "2x" }
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }
        """.data(using: .utf8)!
        try existingContents.write(to: imageset.appendingPathComponent("Contents.json"))

        let summary = try AssetCatalogWriter().importIcons(
            assets: [
                ResolvedExportedAsset(nodeId: "a", figmaName: "eICHome", kind: .icon, finalName: "icAIHome")
            ],
            scales: [2, 3],
            sourceDir: source,
            assetCatalogDir: catalog,
            overwrite: false
        )

        #expect(summary.savedFiles.count == 1)
        #expect(summary.skipped.count == 1)
        let keptBytes = try Data(contentsOf: imageset.appendingPathComponent("icAIHome@2x.png"))
        #expect(keptBytes == Data([0x99]))

        let contentsData = try Data(contentsOf: imageset.appendingPathComponent("Contents.json"))
        let json = try JSONSerialization.jsonObject(with: contentsData) as? [String: Any]
        let images = (json?["images"] as? [[String: Any]]) ?? []
        let scales = Set(images.compactMap { $0["scale"] as? String })
        #expect(scales == ["1x", "2x", "3x"])
    }
}
