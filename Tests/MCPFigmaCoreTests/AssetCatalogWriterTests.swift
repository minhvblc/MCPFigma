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

    @Test("imports both icons and images into screen folder")
    func importsBothKindsIntoScreenFolder() throws {
        let root = tempDir()
        let source = root.appendingPathComponent("Exports", isDirectory: true)
        let catalog = root.appendingPathComponent("Assets.xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data([0x02]).write(to: source.appendingPathComponent("icAIHome@2x.png"))
        try Data([0x03]).write(to: source.appendingPathComponent("icAIHome@3x.png"))
        try Data([0x12]).write(to: source.appendingPathComponent("imageAIBanner@2x.png"))
        try Data([0x13]).write(to: source.appendingPathComponent("imageAIBanner@3x.png"))

        let summary = try AssetCatalogWriter().importIcons(
            assets: [
                ResolvedExportedAsset(nodeId: "a", figmaName: "eICHome", kind: .icon, finalName: "icAIHome"),
                ResolvedExportedAsset(nodeId: "b", figmaName: "eImageBanner", kind: .image, finalName: "imageAIBanner")
            ],
            scales: [2, 3],
            sourceDir: source,
            assetCatalogDir: catalog,
            screenName: "Home Screen",
            overwrite: true
        )

        let screenFolder = catalog.appendingPathComponent("Home_Screen", isDirectory: true)
        let iconImageset = screenFolder.appendingPathComponent("icAIHome.imageset", isDirectory: true)
        let imageImageset = screenFolder.appendingPathComponent("imageAIBanner.imageset", isDirectory: true)

        #expect(summary.savedFiles.count == 4)
        #expect(summary.errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: iconImageset.appendingPathComponent("icAIHome@2x.png").path))
        #expect(FileManager.default.fileExists(atPath: iconImageset.appendingPathComponent("icAIHome@3x.png").path))
        #expect(FileManager.default.fileExists(atPath: imageImageset.appendingPathComponent("imageAIBanner@2x.png").path))
        #expect(FileManager.default.fileExists(atPath: imageImageset.appendingPathComponent("imageAIBanner@3x.png").path))
        #expect(FileManager.default.fileExists(atPath: screenFolder.appendingPathComponent("Contents.json").path))
    }

    @Test("reuses existing imageset location instead of moving into screen folder")
    func reusesExistingLocation() throws {
        let root = tempDir()
        let source = root.appendingPathComponent("Exports", isDirectory: true)
        let catalog = root.appendingPathComponent("Assets.xcassets", isDirectory: true)
        let oldFolder = catalog.appendingPathComponent("OldScreen", isDirectory: true)
        let existingImageset = oldFolder.appendingPathComponent("icAIHome.imageset", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existingImageset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data([0x20]).write(to: source.appendingPathComponent("icAIHome@2x.png"))
        try Data([0x30]).write(to: source.appendingPathComponent("icAIHome@3x.png"))

        let summary = try AssetCatalogWriter().importIcons(
            assets: [
                ResolvedExportedAsset(nodeId: "a", figmaName: "eICHome", kind: .icon, finalName: "icAIHome")
            ],
            scales: [2, 3],
            sourceDir: source,
            assetCatalogDir: catalog,
            screenName: "NewScreen",
            overwrite: true
        )

        #expect(summary.savedFiles.count == 2)
        #expect(summary.errors.isEmpty)
        // Phải dùng location cũ, không tạo trong folder NewScreen
        #expect(FileManager.default.fileExists(atPath: existingImageset.appendingPathComponent("icAIHome@2x.png").path))
        #expect(!FileManager.default.fileExists(
            atPath: catalog.appendingPathComponent("NewScreen/icAIHome.imageset").path
        ))
    }

    @Test("preserves existing files at scale level when overwrite false")
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
            screenName: "Home",
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

    @Test("scanExistingImagesets finds imagesets in nested folders")
    func scanExistingFindsNested() throws {
        let root = tempDir()
        let catalog = root.appendingPathComponent("Assets.xcassets", isDirectory: true)
        let nested = catalog.appendingPathComponent("Login/icAILogo.imageset", isDirectory: true)
        let topLevel = catalog.appendingPathComponent("imageAIHero.imageset", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: topLevel, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let found = AssetCatalogWriter().scanExistingImagesets(in: catalog)

        #expect(found["icAILogo"]?.lastPathComponent == "icAILogo.imageset")
        #expect(found["imageAIHero"]?.lastPathComponent == "imageAIHero.imageset")
    }

    @Test("falls back to catalog root when screenName sanitizes to empty")
    func emptyScreenNameFallsBackToRoot() throws {
        let root = tempDir()
        let source = root.appendingPathComponent("Exports", isDirectory: true)
        let catalog = root.appendingPathComponent("Assets.xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data([0x01]).write(to: source.appendingPathComponent("icAIHome@2x.png"))

        _ = try AssetCatalogWriter().importIcons(
            assets: [
                ResolvedExportedAsset(nodeId: "a", figmaName: "eICHome", kind: .icon, finalName: "icAIHome")
            ],
            scales: [2],
            sourceDir: source,
            assetCatalogDir: catalog,
            screenName: "   ",
            overwrite: true
        )

        let imageset = catalog.appendingPathComponent("icAIHome.imageset", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: imageset.appendingPathComponent("icAIHome@2x.png").path))
    }
}
