import Foundation

public struct SavedFile: Equatable, Sendable {
    public let figmaName: String
    public let renamed: String
    public let scale: Int
    public let path: String
}

public struct ExportFailure: Equatable, Sendable {
    public let figmaName: String
    public let reason: String
}

public struct ExportSummary: Equatable, Sendable {
    public let savedFiles: [SavedFile]
    public let skipped: [SavedFile]
    public let errors: [ExportFailure]
    public let warnings: [ScanWarning]
}

public struct AssetExporter: Sendable {
    private let api: FigmaAPI
    private let scanner: AssetScanner
    private let downloadConcurrency: Int

    public init(
        api: FigmaAPI,
        scanner: AssetScanner = AssetScanner(),
        downloadConcurrency: Int = 6
    ) {
        precondition(downloadConcurrency >= 1)
        self.api = api
        self.scanner = scanner
        self.downloadConcurrency = downloadConcurrency
    }

    public func export(
        fileKey: String,
        rootNodeId: String,
        outputDir: URL,
        scales: [Int] = [2, 3],
        overwrite: Bool = true,
        selectedNodeIds: Set<String>? = nil
    ) async throws -> ExportSummary {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let response = try await api.fetchNodes(fileKey: fileKey, nodeId: rootNodeId, depth: nil)
        guard let root = response.nodes[rootNodeId]?.document else {
            throw FigmaAPIError.notFound
        }

        let scan = scanner.scan(root)
        let targets = selectedNodeIds.map { selected in
            scan.matches.filter { selected.contains($0.nodeId) }
        } ?? scan.matches

        let resolved = resolveCollisions(targets)

        var saved: [SavedFile] = []
        var skipped: [SavedFile] = []
        var errors: [ExportFailure] = []

        for scale in scales {
            let ids = resolved.map { $0.asset.nodeId }
            let renders: [String: URL]
            do {
                renders = try await api.renderImages(fileKey: fileKey, nodeIds: ids, scale: scale)
            } catch {
                for item in resolved {
                    errors.append(ExportFailure(
                        figmaName: item.asset.figmaName,
                        reason: "renderImages(scale: \(scale)) lỗi: \(error)"
                    ))
                }
                continue
            }

            let jobs: [DownloadJob] = resolved.compactMap { item in
                guard let url = renders[item.asset.nodeId] else { return nil }
                let filename = "\(item.finalName)@\(scale)x.png"
                let dest = outputDir.appendingPathComponent(filename)
                return DownloadJob(
                    asset: item.asset,
                    finalName: item.finalName,
                    scale: scale,
                    url: url,
                    destination: dest
                )
            }

            let missingIds = Set(ids).subtracting(renders.keys)
            for missingId in missingIds {
                if let asset = resolved.first(where: { $0.asset.nodeId == missingId })?.asset {
                    errors.append(ExportFailure(
                        figmaName: asset.figmaName,
                        reason: "Figma không trả URL cho scale \(scale)"
                    ))
                }
            }

            let outcomes = await downloadAll(jobs: jobs, overwrite: overwrite)
            for outcome in outcomes {
                switch outcome {
                case .saved(let file): saved.append(file)
                case .skipped(let file): skipped.append(file)
                case .failed(let failure): errors.append(failure)
                }
            }
        }

        return ExportSummary(
            savedFiles: saved,
            skipped: skipped,
            errors: errors,
            warnings: scan.warnings
        )
    }

    private func resolveCollisions(_ matches: [FoundAsset]) -> [ResolvedAsset] {
        var counts: [String: Int] = [:]
        return matches.map { asset in
            let count = counts[asset.renamed, default: 0] + 1
            counts[asset.renamed] = count
            let finalName = count == 1 ? asset.renamed : "\(asset.renamed)_\(count)"
            return ResolvedAsset(asset: asset, finalName: finalName)
        }
    }

    private func downloadAll(jobs: [DownloadJob], overwrite: Bool) async -> [DownloadOutcome] {
        await withTaskGroup(of: DownloadOutcome.self) { group in
            var iterator = jobs.makeIterator()
            for _ in 0..<downloadConcurrency {
                guard let job = iterator.next() else { break }
                group.addTask { await self.process(job: job, overwrite: overwrite) }
            }
            var results: [DownloadOutcome] = []
            while let outcome = await group.next() {
                results.append(outcome)
                if let job = iterator.next() {
                    group.addTask { await self.process(job: job, overwrite: overwrite) }
                }
            }
            return results
        }
    }

    private func process(job: DownloadJob, overwrite: Bool) async -> DownloadOutcome {
        let savedFile = SavedFile(
            figmaName: job.asset.figmaName,
            renamed: job.finalName,
            scale: job.scale,
            path: job.destination.path
        )
        if !overwrite, FileManager.default.fileExists(atPath: job.destination.path) {
            return .skipped(savedFile)
        }
        do {
            let data = try await api.download(job.url)
            try data.write(to: job.destination)
            return .saved(savedFile)
        } catch {
            return .failed(ExportFailure(
                figmaName: job.asset.figmaName,
                reason: "download/save thất bại (scale \(job.scale)): \(error)"
            ))
        }
    }
}

private struct ResolvedAsset: Sendable {
    let asset: FoundAsset
    let finalName: String
}

private struct DownloadJob: Sendable {
    let asset: FoundAsset
    let finalName: String
    let scale: Int
    let url: URL
    let destination: URL
}

private enum DownloadOutcome: Sendable {
    case saved(SavedFile)
    case skipped(SavedFile)
    case failed(ExportFailure)
}
