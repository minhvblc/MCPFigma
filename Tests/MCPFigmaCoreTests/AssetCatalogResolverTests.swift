import Foundation
import Testing
@testable import MCPFigmaCore

@Suite("AssetCatalogResolver")
struct AssetCatalogResolverTests {
    func tempDir(_ name: String = UUID().uuidString) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MCPFigmaCatalogResolver-\(name)")
        try? FileManager.default.removeItem(at: dir)
        return dir
    }

    @Test("resolves direct asset catalog path")
    func resolvesDirectPath() throws {
        let root = tempDir()
        let catalog = root.appendingPathComponent("Assets.xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try AssetCatalogResolver().resolve(
            assetCatalogPath: catalog.path,
            xcodeProjectPath: nil
        )

        #expect(resolved?.path == catalog.path)
    }

    @Test("prefers non-preview Assets.xcassets from project root")
    func prefersPrimaryCatalog() throws {
        let root = tempDir()
        let project = root.appendingPathComponent("Demo.xcodeproj", isDirectory: true)
        let preview = root
            .appendingPathComponent("Preview Content", isDirectory: true)
            .appendingPathComponent("Preview Assets.xcassets", isDirectory: true)
        let assets = root.appendingPathComponent("Assets.xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try AssetCatalogResolver().resolve(
            assetCatalogPath: nil,
            xcodeProjectPath: project.path
        )

        #expect(resolved?.path == assets.path)
    }

    @Test("throws when project root has multiple primary catalogs")
    func throwsForMultipleCatalogs() throws {
        let root = tempDir()
        let appAssets = root
            .appendingPathComponent("App", isDirectory: true)
            .appendingPathComponent("Assets.xcassets", isDirectory: true)
        let widgetAssets = root
            .appendingPathComponent("Widget", isDirectory: true)
            .appendingPathComponent("Assets.xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: appAssets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: widgetAssets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try AssetCatalogResolver().resolve(
                assetCatalogPath: nil,
                xcodeProjectPath: root.path
            )
            Issue.record("Expected multiple asset catalog resolution error")
        } catch let error as AssetCatalogResolutionError {
            switch error {
            case .multipleAssetCatalogs(let paths):
                #expect(paths.count == 2)
                #expect(paths.contains { $0.hasSuffix("/App/Assets.xcassets") })
                #expect(paths.contains { $0.hasSuffix("/Widget/Assets.xcassets") })
            default:
                Issue.record("Unexpected resolver error: \(error)")
            }
        }
    }
}
