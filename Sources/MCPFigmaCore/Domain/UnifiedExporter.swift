import Foundation

// MARK: - Inputs

public enum UnifiedRowExporter: String, Sendable {
    case tagged
    case fallback
}

public enum UnifiedRowStrategy: String, Sendable {
    case atomic
    case flatten
    case lottiePlaceholder
}

public struct UnifiedExportRow: Equatable, Sendable {
    public let nodeId: String
    public let exporter: UnifiedRowExporter
    public let exportName: String?
    public let friendlyName: String?
    public let strategy: UnifiedRowStrategy

    public init(
        nodeId: String,
        exporter: UnifiedRowExporter,
        exportName: String? = nil,
        friendlyName: String? = nil,
        strategy: UnifiedRowStrategy = .atomic
    ) {
        self.nodeId = nodeId
        self.exporter = exporter
        self.exportName = exportName
        self.friendlyName = friendlyName
        self.strategy = strategy
    }
}

// MARK: - Outputs

public enum UnifiedRowStatus: String, Sendable {
    case done
    case failed
    case skipped
}

public struct UnifiedExportCoverage: Equatable, Sendable {
    public let discoveredCount: Int
    public let exportedCount: Int
    public let autoAddedRows: [String]
    public let skippedNodeIds: [String]
    /// nodeIds the scanner classified as eAnim*. Reported for visibility only —
    /// these are NOT auto-added as rows because they have no downloadable bytes.
    public let animationNodeIds: [String]

    public init(
        discoveredCount: Int,
        exportedCount: Int,
        autoAddedRows: [String],
        skippedNodeIds: [String],
        animationNodeIds: [String] = []
    ) {
        self.discoveredCount = discoveredCount
        self.exportedCount = exportedCount
        self.autoAddedRows = autoAddedRows
        self.skippedNodeIds = skippedNodeIds
        self.animationNodeIds = animationNodeIds
    }
}

public struct UnifiedExportRowResult: Equatable, Sendable {
    public let nodeId: String
    public let exporter: UnifiedRowExporter
    public let strategy: UnifiedRowStrategy
    public let status: UnifiedRowStatus
    public let exportName: String?
    public let friendlyName: String?
    public let outputPath: String?
    public let imagesetPath: String?
    public let xcassetsImported: Bool
    public let sharedPath: String?
    public let reason: String?
}

public struct UnifiedExportSummary: Equatable, Sendable {
    public let rows: [UnifiedExportRowResult]
    public let warnings: [ScanWarning]
    public let assetCatalogPath: String?
    public let coverage: UnifiedExportCoverage?

    public init(
        rows: [UnifiedExportRowResult],
        warnings: [ScanWarning],
        assetCatalogPath: String?,
        coverage: UnifiedExportCoverage? = nil
    ) {
        self.rows = rows
        self.warnings = warnings
        self.assetCatalogPath = assetCatalogPath
        self.coverage = coverage
    }
}

// MARK: - Exporter

/// Orchestrates the full asset pipeline that used to live in skill prose:
///   - Tagged rows  → batch via AssetExporter (renders @2x/@3x, writes xcassets).
///   - Fallback rows → batch via /v1/images at the requested scale, dedupe to
///     a shared assets dir on disk; per-node retry for nulls; PNG signature
///     validation. No xcassets import (shared assets are referenced by code).
///   - Tagged rows that error → automatically rewritten to fallback and retried.
///   - eAnim* nodes (lottiePlaceholder) → pass-through, never downloaded.
public struct UnifiedExporter: Sendable {
    /// Subdirectory under `outputDir` where tagged @2x/@3x PNGs are staged
    /// before being copied into the .xcassets imageset folders. Internal
    /// staging — callers should not depend on this name.
    private static let stagingDirName = "_mcpfigma"

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
        rows: [UnifiedExportRow],
        outputDir: URL,
        sharedAssetsDir: URL,
        assetCatalogDir: URL?,
        scales: [Int] = [2, 3],
        fallbackScale: Int = 3,
        overwrite: Bool = true,
        skipIfExistsInCatalog: Bool = true,
        autoDiscover: Bool = false
    ) async throws -> UnifiedExportSummary {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedAssetsDir, withIntermediateDirectories: true)

        // Scan once: re-used for autoDiscover, eAnim detection, and (when present)
        // passed straight to AssetExporter to skip its second fetchNodes round-trip.
        var prefetchedRoot: FigmaNode?
        var prefetchedScan: ScanResult?
        var coverage: UnifiedExportCoverage?
        var effectiveRows = rows
        var animationNodeIds: Set<String> = []

        if autoDiscover {
            let response = try await api.fetchNodes(fileKey: fileKey, nodeId: rootNodeId, depth: nil)
            guard let root = response.nodes[rootNodeId]?.document else {
                throw FigmaAPIError.notFound
            }
            let scan = scanner.scan(root)
            prefetchedRoot = root
            prefetchedScan = scan
            animationNodeIds = Set(scan.animations.map(\.nodeId))

            let existingIds = Set(rows.map(\.nodeId))
            var added: [String] = []
            for asset in scan.matches where !existingIds.contains(asset.nodeId) {
                effectiveRows.append(UnifiedExportRow(
                    nodeId: asset.nodeId,
                    exporter: .tagged,
                    exportName: asset.renamed,
                    friendlyName: asset.renamed,
                    strategy: .atomic
                ))
                added.append(asset.nodeId)
            }
            coverage = UnifiedExportCoverage(
                discoveredCount: scan.matches.count,
                exportedCount: 0, // filled in below after results computed
                autoAddedRows: added,
                skippedNodeIds: [],
                animationNodeIds: scan.animations.map(\.nodeId)
            )
        }

        // Caller-supplied rows targeting an eAnim node are coerced to the
        // lottiePlaceholder pipeline regardless of declared strategy — eAnim
        // never produces downloadable bytes.
        if !animationNodeIds.isEmpty {
            effectiveRows = effectiveRows.map { row in
                guard animationNodeIds.contains(row.nodeId), row.strategy != .lottiePlaceholder else {
                    return row
                }
                return UnifiedExportRow(
                    nodeId: row.nodeId,
                    exporter: row.exporter,
                    exportName: row.exportName,
                    friendlyName: row.friendlyName,
                    strategy: .lottiePlaceholder
                )
            }
        }

        let lottieRows = effectiveRows.filter { $0.strategy == .lottiePlaceholder }
        let materialRows = effectiveRows.filter { $0.strategy != .lottiePlaceholder }

        // Tagged rows go through the full xcassets pipeline.
        let taggedNodeIds = Set(materialRows.filter { $0.exporter == .tagged }.map(\.nodeId))
        let taggedSummary: ExportSummary?
        if !taggedNodeIds.isEmpty {
            let exporter = AssetExporter(api: api, scanner: scanner)
            let stagingDir = outputDir.appendingPathComponent(Self.stagingDirName, isDirectory: true)
            if let prefetchedRoot {
                taggedSummary = try await exporter.export(
                    fileKey: fileKey,
                    root: prefetchedRoot,
                    scan: prefetchedScan,
                    outputDir: stagingDir,
                    scales: scales,
                    overwrite: overwrite,
                    selectedNodeIds: taggedNodeIds,
                    assetCatalogDir: assetCatalogDir,
                    skipIfExistsInCatalog: skipIfExistsInCatalog
                )
            } else {
                taggedSummary = try await exporter.export(
                    fileKey: fileKey,
                    rootNodeId: rootNodeId,
                    outputDir: stagingDir,
                    scales: scales,
                    overwrite: overwrite,
                    selectedNodeIds: taggedNodeIds,
                    assetCatalogDir: assetCatalogDir,
                    skipIfExistsInCatalog: skipIfExistsInCatalog
                )
            }
        } else {
            taggedSummary = nil
        }

        // Map nodeId → AssetExporter outcome for tagged rows
        let taggedRowOutcomes = mapTaggedOutcomes(rows: materialRows, summary: taggedSummary)

        // Auto-promote tagged rows that errored to fallback path.
        var fallbackQueue: [UnifiedExportRow] = materialRows.filter { $0.exporter == .fallback }
        var rewrittenTaggedFailures: [String: String] = [:] // nodeId → original exportName for reason
        for row in materialRows where row.exporter == .tagged {
            if let outcome = taggedRowOutcomes[row.nodeId], outcome.status == .failed {
                fallbackQueue.append(UnifiedExportRow(
                    nodeId: row.nodeId,
                    exporter: .fallback,
                    exportName: row.exportName,
                    friendlyName: row.friendlyName ?? row.exportName,
                    strategy: row.strategy
                ))
                rewrittenTaggedFailures[row.nodeId] = outcome.reason
            }
        }

        // Fallback batch
        let fallbackOutcomes = await runFallback(
            fileKey: fileKey,
            rows: fallbackQueue,
            sharedAssetsDir: sharedAssetsDir,
            scale: fallbackScale,
            overwrite: overwrite
        )

        // Merge per-row results
        var finalResults: [UnifiedExportRowResult] = []
        for row in materialRows {
            if row.exporter == .tagged, let outcome = taggedRowOutcomes[row.nodeId] {
                if outcome.status == .failed,
                   let promoted = fallbackOutcomes[row.nodeId] {
                    // Tagged failed → promoted to fallback. Report final fallback outcome
                    // but keep original exporter label so the caller knows the path it took.
                    let reason = [
                        rewrittenTaggedFailures[row.nodeId],
                        promoted.reason
                    ].compactMap { $0 }.joined(separator: " | ")
                    finalResults.append(UnifiedExportRowResult(
                        nodeId: row.nodeId,
                        exporter: .fallback,
                        strategy: row.strategy,
                        status: promoted.status,
                        exportName: nil,
                        friendlyName: row.friendlyName ?? row.exportName,
                        outputPath: nil,
                        imagesetPath: nil,
                        xcassetsImported: false,
                        sharedPath: promoted.sharedPath,
                        reason: reason.isEmpty ? nil : reason
                    ))
                } else {
                    finalResults.append(outcome)
                }
            } else if row.exporter == .fallback, let outcome = fallbackOutcomes[row.nodeId] {
                finalResults.append(UnifiedExportRowResult(
                    nodeId: row.nodeId,
                    exporter: .fallback,
                    strategy: row.strategy,
                    status: outcome.status,
                    exportName: nil,
                    friendlyName: row.friendlyName,
                    outputPath: nil,
                    imagesetPath: nil,
                    xcassetsImported: false,
                    sharedPath: outcome.sharedPath,
                    reason: outcome.reason
                ))
            } else {
                finalResults.append(UnifiedExportRowResult(
                    nodeId: row.nodeId,
                    exporter: row.exporter,
                    strategy: row.strategy,
                    status: .failed,
                    exportName: row.exportName,
                    friendlyName: row.friendlyName,
                    outputPath: nil,
                    imagesetPath: nil,
                    xcassetsImported: false,
                    sharedPath: nil,
                    reason: "No outcome found for row — internal pipeline error"
                ))
            }
        }

        // Lottie placeholders are pass-through (no download) — emit a `done` row.
        for row in lottieRows {
            finalResults.append(UnifiedExportRowResult(
                nodeId: row.nodeId,
                exporter: .fallback,
                strategy: .lottiePlaceholder,
                status: .done,
                exportName: nil,
                friendlyName: row.friendlyName,
                outputPath: nil,
                imagesetPath: nil,
                xcassetsImported: false,
                sharedPath: nil,
                reason: nil
            ))
        }

        let finalCoverage: UnifiedExportCoverage? = coverage.map { c in
            let exported = finalResults.filter { $0.status == .done }.count
            let autoIds = Set(c.autoAddedRows)
            let skipped = finalResults
                .filter { autoIds.contains($0.nodeId) && $0.status != .done }
                .map(\.nodeId)
            return UnifiedExportCoverage(
                discoveredCount: c.discoveredCount,
                exportedCount: exported,
                autoAddedRows: c.autoAddedRows,
                skippedNodeIds: skipped,
                animationNodeIds: c.animationNodeIds
            )
        }

        return UnifiedExportSummary(
            rows: finalResults,
            warnings: taggedSummary?.warnings ?? [],
            assetCatalogPath: taggedSummary?.assetCatalogImport?.catalogPath,
            coverage: finalCoverage
        )
    }

    // MARK: - Tagged outcome mapping

    /// Correlates AssetExporter results back to the input rows by nodeId.
    /// AssetExporter emits SavedFile/ExportFailure tagged with the originating
    /// nodeId, so this is now a strict equality match (no exportName substring).
    private func mapTaggedOutcomes(
        rows: [UnifiedExportRow],
        summary: ExportSummary?
    ) -> [String: UnifiedExportRowResult] {
        guard let summary else { return [:] }

        let savedByNode: [String: [SavedFile]] = Dictionary(grouping: summary.savedFiles, by: \.nodeId)
        let skippedByNode: [String: [SavedFile]] = Dictionary(grouping: summary.skipped, by: \.nodeId)
        let renderErrors: [String: ExportFailure] = Dictionary(
            summary.errors.map { ($0.nodeId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let importedByNode: [String: [SavedFile]] = Dictionary(
            grouping: summary.assetCatalogImport?.savedFiles ?? [],
            by: \.nodeId
        )
        let importErrors: [String: ExportFailure] = Dictionary(
            (summary.assetCatalogImport?.errors ?? []).map { ($0.nodeId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var byNode: [String: UnifiedExportRowResult] = [:]
        for row in rows where row.exporter == .tagged {
            let savedFiles = (savedByNode[row.nodeId] ?? []) + (skippedByNode[row.nodeId] ?? [])
            let savedAt3x = savedFiles.first(where: { $0.scale == 3 })?.path
                ?? savedFiles.first?.path
            let imagesetPath = importedByNode[row.nodeId]?.first.map {
                URL(fileURLWithPath: $0.path).deletingLastPathComponent().path
            }
            let xcassetsImported = imagesetPath != nil
            let saved = savedAt3x != nil

            let renderError = renderErrors[row.nodeId]
            let importError = importErrors[row.nodeId]
            let exportName = row.exportName
                ?? savedFiles.first?.renamed
                ?? renderError?.figmaName
                ?? importError?.figmaName

            let status: UnifiedRowStatus
            let reason: String?
            if let importError, !saved {
                status = .failed
                reason = importError.reason
            } else if let renderError, !saved {
                status = .failed
                reason = renderError.reason
            } else if saved {
                status = .done
                reason = nil
            } else {
                status = .failed
                reason = "Không tìm thấy file đã render cho node \(row.nodeId)"
            }

            byNode[row.nodeId] = UnifiedExportRowResult(
                nodeId: row.nodeId,
                exporter: .tagged,
                strategy: row.strategy,
                status: status,
                exportName: exportName,
                friendlyName: row.friendlyName,
                outputPath: savedAt3x,
                imagesetPath: imagesetPath,
                xcassetsImported: xcassetsImported,
                sharedPath: nil,
                reason: reason
            )
        }
        return byNode
    }

    // MARK: - Fallback path

    private struct FallbackOutcome: Sendable {
        let nodeId: String
        let status: UnifiedRowStatus
        let sharedPath: String?
        let reason: String?
    }

    private func runFallback(
        fileKey: String,
        rows: [UnifiedExportRow],
        sharedAssetsDir: URL,
        scale: Int,
        overwrite: Bool
    ) async -> [String: FallbackOutcome] {
        guard !rows.isEmpty else { return [:] }
        var outcomes: [String: FallbackOutcome] = [:]

        // Step 1: short-circuit any nodeId already cached
        var pending: [UnifiedExportRow] = []
        for row in rows {
            let path = sharedPath(for: row.nodeId, in: sharedAssetsDir)
            if FileManager.default.fileExists(atPath: path.path), Self.isPNG(at: path), !overwrite {
                outcomes[row.nodeId] = FallbackOutcome(
                    nodeId: row.nodeId,
                    status: .done,
                    sharedPath: path.path,
                    reason: nil
                )
            } else {
                pending.append(row)
            }
        }

        guard !pending.isEmpty else { return outcomes }

        // Step 2: render via /v1/images batch
        let renders: [String: URL]
        do {
            renders = try await api.renderImages(
                fileKey: fileKey,
                nodeIds: pending.map(\.nodeId),
                scale: scale
            )
        } catch {
            for row in pending {
                outcomes[row.nodeId] = FallbackOutcome(
                    nodeId: row.nodeId,
                    status: .failed,
                    sharedPath: nil,
                    reason: "renderImages thất bại: \(error)"
                )
            }
            return outcomes
        }

        // Step 3: download each in parallel, validate PNG signature
        await withTaskGroup(of: FallbackOutcome.self) { group in
            var iterator = pending.makeIterator()
            for _ in 0..<downloadConcurrency {
                guard let row = iterator.next() else { break }
                group.addTask { [self] in
                    await downloadFallback(
                        row: row,
                        renders: renders,
                        sharedAssetsDir: sharedAssetsDir
                    )
                }
            }
            while let outcome = await group.next() {
                outcomes[outcome.nodeId] = outcome
                if let row = iterator.next() {
                    group.addTask { [self] in
                        await downloadFallback(
                            row: row,
                            renders: renders,
                            sharedAssetsDir: sharedAssetsDir
                        )
                    }
                }
            }
        }

        return outcomes
    }

    private func downloadFallback(
        row: UnifiedExportRow,
        renders: [String: URL],
        sharedAssetsDir: URL
    ) async -> FallbackOutcome {
        guard let url = renders[row.nodeId] else {
            return FallbackOutcome(
                nodeId: row.nodeId,
                status: .failed,
                sharedPath: nil,
                reason: "Figma không trả URL render cho node \(row.nodeId)"
            )
        }
        let dest = sharedPath(for: row.nodeId, in: sharedAssetsDir)
        do {
            let data = try await api.download(url)
            guard Self.dataIsPNG(data) else {
                return FallbackOutcome(
                    nodeId: row.nodeId,
                    status: .failed,
                    sharedPath: nil,
                    reason: "Output không phải PNG (có thể là SVG/XML) — skill phải re-fetch riêng"
                )
            }
            try data.write(to: dest)
            return FallbackOutcome(
                nodeId: row.nodeId,
                status: .done,
                sharedPath: dest.path,
                reason: nil
            )
        } catch {
            return FallbackOutcome(
                nodeId: row.nodeId,
                status: .failed,
                sharedPath: nil,
                reason: "Download thất bại: \(error)"
            )
        }
    }

    private func sharedPath(for nodeId: String, in dir: URL) -> URL {
        let safe = nodeId.replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent("\(safe).png")
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func dataIsPNG(_ data: Data) -> Bool {
        guard data.count >= pngSignature.count else { return false }
        for (offset, byte) in pngSignature.enumerated() where data[offset] != byte {
            return false
        }
        return true
    }

    static func isPNG(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: pngSignature.count)) ?? Data()
        return dataIsPNG(data)
    }
}
