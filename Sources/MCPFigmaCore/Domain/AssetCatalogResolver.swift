import Foundation

public enum AssetCatalogResolutionError: Error, Equatable, Sendable, CustomStringConvertible {
    case conflictingInputs
    case pathMustBeAbsolute(String)
    case pathDoesNotExist(String)
    case notDirectory(String)
    case notAssetCatalog(String)
    case assetCatalogNotFound(String)
    case multipleAssetCatalogs([String])

    public var description: String {
        switch self {
        case .conflictingInputs:
            return "Chỉ truyền một trong hai tham số 'assetCatalogPath' hoặc 'xcodeProjectPath'."
        case .pathMustBeAbsolute(let path):
            return "Đường dẫn phải là tuyệt đối: \(path)"
        case .pathDoesNotExist(let path):
            return "Đường dẫn không tồn tại: \(path)"
        case .notDirectory(let path):
            return "Đường dẫn phải là thư mục hoặc bundle Xcode hợp lệ: \(path)"
        case .notAssetCatalog(let path):
            return "Đường dẫn không phải .xcassets hợp lệ: \(path)"
        case .assetCatalogNotFound(let path):
            return "Không tìm thấy .xcassets phù hợp bên trong: \(path)"
        case .multipleAssetCatalogs(let paths):
            return """
            Tìm thấy nhiều asset catalog, cần chỉ rõ 'assetCatalogPath': \
            \(paths.sorted().joined(separator: ", "))
            """
        }
    }
}

public struct AssetCatalogResolver: Sendable {
    public init() {}

    public func resolve(
        assetCatalogPath: String?,
        xcodeProjectPath: String?
    ) throws -> URL? {
        let direct = assetCatalogPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = xcodeProjectPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let direct, !direct.isEmpty, let project, !project.isEmpty {
            throw AssetCatalogResolutionError.conflictingInputs
        }
        if let direct, !direct.isEmpty {
            return try validateAssetCatalog(path: direct)
        }
        if let project, !project.isEmpty {
            return try resolveFromProjectPath(project)
        }
        return nil
    }

    private func validateAssetCatalog(path: String) throws -> URL {
        try validateAbsolutePath(path)
        let url = URL(fileURLWithPath: path)
        try ensureExists(url)
        guard url.pathExtension == "xcassets" else {
            throw AssetCatalogResolutionError.notAssetCatalog(path)
        }
        guard isDirectory(url) else {
            throw AssetCatalogResolutionError.notDirectory(path)
        }
        return url.standardizedFileURL
    }

    private func resolveFromProjectPath(_ path: String) throws -> URL {
        try validateAbsolutePath(path)
        let url = URL(fileURLWithPath: path)
        try ensureExists(url)

        if url.pathExtension == "xcassets" {
            return try validateAssetCatalog(path: path)
        }

        let searchRoot: URL
        if url.pathExtension == "xcodeproj" || url.pathExtension == "xcworkspace" {
            searchRoot = url.deletingLastPathComponent()
        } else if isDirectory(url) {
            searchRoot = url
        } else {
            searchRoot = url.deletingLastPathComponent()
        }

        let catalogs = findAssetCatalogs(under: searchRoot)
        guard !catalogs.isEmpty else {
            throw AssetCatalogResolutionError.assetCatalogNotFound(searchRoot.path)
        }

        let preferred = catalogs.filter { $0.lastPathComponent == "Assets.xcassets" && !isPreviewCatalog($0) }
        if preferred.count == 1, let catalog = preferred.first {
            return catalog.standardizedFileURL
        }
        if preferred.count > 1 {
            throw AssetCatalogResolutionError.multipleAssetCatalogs(preferred.map(\.path))
        }

        let nonPreview = catalogs.filter { !isPreviewCatalog($0) }
        if nonPreview.count == 1, let catalog = nonPreview.first {
            return catalog.standardizedFileURL
        }
        if catalogs.count == 1, let catalog = catalogs.first {
            return catalog.standardizedFileURL
        }

        throw AssetCatalogResolutionError.multipleAssetCatalogs(catalogs.map(\.path))
    }

    private func validateAbsolutePath(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw AssetCatalogResolutionError.pathMustBeAbsolute(path)
        }
    }

    private func ensureExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AssetCatalogResolutionError.pathDoesNotExist(url.path)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }

    private func findAssetCatalogs(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var catalogs: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "xcassets" && isDirectory(url) {
                catalogs.append(url)
                enumerator.skipDescendants()
            }
        }
        return catalogs.sorted { $0.path < $1.path }
    }

    private func isPreviewCatalog(_ url: URL) -> Bool {
        url.pathComponents.contains("Preview Content")
    }
}
