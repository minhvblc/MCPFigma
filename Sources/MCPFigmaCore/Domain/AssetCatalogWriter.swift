import Foundation

struct AssetCatalogWriter: Sendable {
    func importIcons(
        assets: [ResolvedExportedAsset],
        scales: [Int],
        sourceDir: URL,
        assetCatalogDir: URL,
        screenName: String,
        overwrite: Bool
    ) throws -> AssetCatalogImportSummary {
        try FileManager.default.createDirectory(at: assetCatalogDir, withIntermediateDirectories: true)

        let existing = scanExistingImagesets(in: assetCatalogDir)
        let groupDir = makeGroupDir(catalog: assetCatalogDir, screenName: screenName)
        var groupDirEnsured = groupDir == assetCatalogDir

        var saved: [SavedFile] = []
        var skipped: [SavedFile] = []
        var errors: [ExportFailure] = []

        for asset in assets {
            let imagesetDir: URL
            if let existingURL = existing[asset.finalName] {
                imagesetDir = existingURL
            } else {
                if !groupDirEnsured {
                    do {
                        try ensureGroupDir(groupDir)
                        groupDirEnsured = true
                    } catch {
                        errors.append(ExportFailure(
                            nodeId: asset.nodeId,
                            figmaName: asset.figmaName,
                            reason: "Không tạo được group folder \(groupDir.path): \(error)"
                        ))
                        continue
                    }
                }
                imagesetDir = groupDir.appendingPathComponent("\(asset.finalName).imageset", isDirectory: true)
            }

            do {
                try FileManager.default.createDirectory(at: imagesetDir, withIntermediateDirectories: true)
            } catch {
                errors.append(ExportFailure(
                    nodeId: asset.nodeId,
                    figmaName: asset.figmaName,
                    reason: "Không tạo được imageset \(imagesetDir.path): \(error)"
                ))
                continue
            }

            let contentsURL = imagesetDir.appendingPathComponent("Contents.json")
            var contents = loadContents(from: contentsURL)

            for scale in scales {
                let filename = AssetNameRewriter.fileName(renamed: asset.finalName, scale: scale)
                let sourceURL = sourceDir.appendingPathComponent(filename)
                let destinationURL = imagesetDir.appendingPathComponent(filename)
                let savedFile = SavedFile(
                    nodeId: asset.nodeId,
                    figmaName: asset.figmaName,
                    renamed: asset.finalName,
                    scale: scale,
                    path: destinationURL.path
                )

                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    errors.append(ExportFailure(
                        nodeId: asset.nodeId,
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
                        nodeId: asset.nodeId,
                        figmaName: asset.figmaName,
                        reason: "Import vào asset catalog thất bại (scale \(scale)): \(error)"
                    ))
                }
            }

            do {
                try writeContents(contents, to: contentsURL)
            } catch {
                errors.append(ExportFailure(
                    nodeId: asset.nodeId,
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

    func scanExistingImagesets(in catalog: URL) -> [String: URL] {
        guard FileManager.default.fileExists(atPath: catalog.path),
              let enumerator = FileManager.default.enumerator(
                at: catalog,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return [:]
        }
        var result: [String: URL] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension == "imageset" else { continue }
            var isDir = ObjCBool(false)
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if result[name] == nil {
                result[name] = url
            }
            enumerator.skipDescendants()
        }
        return result
    }

    private func makeGroupDir(catalog: URL, screenName: String) -> URL {
        let sanitized = sanitizeFolderName(screenName)
        guard !sanitized.isEmpty else { return catalog }
        return catalog.appendingPathComponent(sanitized, isDirectory: true)
    }

    private func ensureGroupDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let contentsURL = url.appendingPathComponent("Contents.json")
        guard !FileManager.default.fileExists(atPath: contentsURL.path) else { return }
        let payload: [String: Any] = [
            "info": ["author": "xcode", "version": 1]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: contentsURL)
    }

    private func sanitizeFolderName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var output = ""
        var lastWasSeparator = false
        for char in trimmed {
            if let ascii = char.asciiValue, ascii < 0x20 { continue }
            if forbidden.contains(char) { continue }
            if char.isWhitespace {
                if !output.isEmpty, !lastWasSeparator {
                    output.append("_")
                    lastWasSeparator = true
                }
                continue
            }
            output.append(char)
            lastWasSeparator = false
        }
        while output.hasSuffix("_") || output.hasSuffix(".") {
            output.removeLast()
        }
        return output
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
