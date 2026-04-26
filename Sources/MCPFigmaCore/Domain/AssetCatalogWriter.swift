import Foundation

struct AssetCatalogWriter: Sendable {
    func importIcons(
        assets: [ResolvedExportedAsset],
        scales: [Int],
        sourceDir: URL,
        assetCatalogDir: URL,
        overwrite: Bool
    ) throws -> AssetCatalogImportSummary {
        try FileManager.default.createDirectory(at: assetCatalogDir, withIntermediateDirectories: true)

        let icons = assets.filter { $0.kind == .icon }
        var saved: [SavedFile] = []
        var skipped: [SavedFile] = []
        var errors: [ExportFailure] = []

        for asset in icons {
            let imagesetDir = assetCatalogDir.appendingPathComponent("\(asset.finalName).imageset", isDirectory: true)
            try FileManager.default.createDirectory(at: imagesetDir, withIntermediateDirectories: true)

            let contentsURL = imagesetDir.appendingPathComponent("Contents.json")
            var contents = loadContents(from: contentsURL)

            for scale in scales {
                let filename = AssetNameRewriter.fileName(renamed: asset.finalName, scale: scale)
                let sourceURL = sourceDir.appendingPathComponent(filename)
                let destinationURL = imagesetDir.appendingPathComponent(filename)
                let savedFile = SavedFile(
                    figmaName: asset.figmaName,
                    renamed: asset.finalName,
                    scale: scale,
                    path: destinationURL.path
                )

                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    errors.append(ExportFailure(
                        figmaName: asset.figmaName,
                        reason: "Thiếu file nguồn để import vào asset catalog (scale \(scale)): \(sourceURL.path)"
                    ))
                    continue
                }

                do {
                    if !overwrite, FileManager.default.fileExists(atPath: destinationURL.path) {
                        skipped.append(savedFile)
                    } else {
                        if FileManager.default.fileExists(atPath: destinationURL.path) {
                            try FileManager.default.removeItem(at: destinationURL)
                        }
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        saved.append(savedFile)
                    }
                    contents.upsertUniversalImage(filename: filename, scale: scale)
                } catch {
                    errors.append(ExportFailure(
                        figmaName: asset.figmaName,
                        reason: "Import vào asset catalog thất bại (scale \(scale)): \(error)"
                    ))
                }
            }

            do {
                try writeContents(contents, to: contentsURL)
            } catch {
                errors.append(ExportFailure(
                    figmaName: asset.figmaName,
                    reason: "Không ghi được Contents.json cho imageset \(asset.finalName): \(error)"
                ))
            }
        }

        return AssetCatalogImportSummary(
            catalogPath: assetCatalogDir.path,
            savedFiles: saved,
            skipped: skipped,
            errors: errors
        )
    }

    private func loadContents(from url: URL) -> AssetCatalogContents {
        guard let data = try? Data(contentsOf: url) else {
            return AssetCatalogContents.makeDefault()
        }
        return (try? AssetCatalogContents(data: data)) ?? AssetCatalogContents.makeDefault()
    }

    private func writeContents(_ contents: AssetCatalogContents, to url: URL) throws {
        let data = try contents.data()
        try data.write(to: url)
    }
}

private struct AssetCatalogContents {
    private(set) var root: [String: Any]

    init(root: [String: Any]) {
        self.root = root
    }

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw NSError(domain: "AssetCatalogContents", code: 1)
        }
        self.root = root
    }

    static func makeDefault() -> AssetCatalogContents {
        AssetCatalogContents(root: [
            "images": [],
            "info": [
                "author": "xcode",
                "version": 1
            ]
        ])
    }

    mutating func upsertUniversalImage(filename: String, scale: Int) {
        var images = (root["images"] as? [[String: Any]]) ?? []
        let targetScale = "\(scale)x"

        if let index = images.firstIndex(where: {
            ($0["idiom"] as? String) == "universal" && ($0["scale"] as? String) == targetScale
        }) {
            images[index]["filename"] = filename
        } else {
            images.append([
                "filename": filename,
                "idiom": "universal",
                "scale": targetScale
            ])
        }

        root["images"] = images

        var info = (root["info"] as? [String: Any]) ?? [:]
        info["author"] = info["author"] ?? "xcode"
        info["version"] = info["version"] ?? 1
        root["info"] = info
    }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
