import Foundation
import MCP

enum ToolDefinitions {
    static let all: [Tool] = [
        listAssets,
        exportAssets,
        buildRegistry,
        exportAssetsUnified,
        extractTokens
    ]

    static let listAssets = Tool(
        name: "figma_list_assets",
        description: """
        Liệt kê các asset có prefix eIC* (icon) hoặc eImage* (image) trong một node Figma. \
        Node có prefix eAnim* (Lottie placeholder) sẽ bị bỏ qua, không đào sâu vào con. \
        Không tải file — chỉ preview để người dùng confirm trước khi export.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("fileKey"), .string("nodeId")]),
            "properties": .object([
                "fileKey": .object([
                    "type": .string("string"),
                    "description": .string("Figma file key (phần giữa /file/ và / tên trong URL).")
                ]),
                "nodeId": .object([
                    "type": .string("string"),
                    "description": .string("Node ID root cần quét, dạng 123:456.")
                ]),
                "depth": .object([
                    "type": .string("integer"),
                    "description": .string("Độ sâu tối đa khi fetch cây. Bỏ qua để fetch toàn cây.")
                ])
            ])
        ])
    )

    static let exportAssets = Tool(
        name: "figma_export_assets",
        description: """
        Tải các asset eIC*/eImage* trong một node Figma về thư mục đích dưới dạng PNG \
        @2x và @3x, đổi tên theo convention iOS (icAI*/imageAI*). Node có prefix \
        eAnim* (Lottie placeholder) sẽ bị bỏ qua, không đào sâu vào con. Nếu truyền \
        xcodeProjectPath hoặc assetCatalogPath thì asset export xong sẽ được import \
        vào .xcassets, nhóm theo folder mang tên màn (root node). Mặc định bỏ qua \
        các imageset đã tồn tại sẵn trong catalog (đặt skipIfExistsInCatalog=false để re-import).
        """,
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("fileKey"), .string("nodeId"), .string("outputDir")]),
            "properties": .object([
                "fileKey": .object([
                    "type": .string("string"),
                    "description": .string("Figma file key.")
                ]),
                "nodeId": .object([
                    "type": .string("string"),
                    "description": .string("Node ID root để quét và export.")
                ]),
                "outputDir": .object([
                    "type": .string("string"),
                    "description": .string("Đường dẫn tuyệt đối thư mục đích. Sẽ tự tạo nếu chưa có.")
                ]),
                "xcodeProjectPath": .object([
                    "type": .string("string"),
                    "description": .string("Tùy chọn: đường dẫn tuyệt đối tới .xcodeproj, .xcworkspace hoặc thư mục gốc project để tự resolve .xcassets.")
                ]),
                "assetCatalogPath": .object([
                    "type": .string("string"),
                    "description": .string("Tùy chọn: đường dẫn tuyệt đối trực tiếp tới .xcassets cần import icon vào.")
                ]),
                "nodeIds": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Tùy chọn: chỉ export subset các node đã liệt kê.")
                ]),
                "scales": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("integer")]),
                    "description": .string("Scale cần export, mặc định [2, 3].")
                ]),
                "overwrite": .object([
                    "type": .string("boolean"),
                    "description": .string("Ghi đè file sẵn có, mặc định true.")
                ]),
                "skipIfExistsInCatalog": .object([
                    "type": .string("boolean"),
                    "description": .string("Nếu imageset đã tồn tại trong .xcassets (bất kỳ folder con nào) thì bỏ qua hẳn, không download/import lại. Mặc định true.")
                ])
            ])
        ])
    )

    static let buildRegistry = Tool(
        name: "figma_build_registry",
        description: """
        Trả về registry tổng hợp cho 1 node Figma trong 1 lần gọi: \
        (1) screens — danh sách FRAME giống màn iOS (children trực tiếp của root); \
        (2) taggedAssets — eIC*/eImage* đã đổi tên iOS (icAI*/imageAI*); \
        (3) lottiePlaceholders — eAnim* với kích thước frame; \
        (4) warnings cho tên không hợp lệ. Skill dùng output này thay cho việc gọi \
        figma_list_assets + walk metadata.json riêng lẻ.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("fileKey"), .string("nodeId")]),
            "properties": .object([
                "fileKey": .object([
                    "type": .string("string"),
                    "description": .string("Figma file key.")
                ]),
                "nodeId": .object([
                    "type": .string("string"),
                    "description": .string("Node ID root cần quét, dạng 123:456.")
                ]),
                "depth": .object([
                    "type": .string("integer"),
                    "description": .string("Độ sâu tối đa khi fetch cây. Mặc định 10.")
                ])
            ])
        ])
    )

    static let exportAssetsUnified = Tool(
        name: "figma_export_assets_unified",
        description: """
        Export pipeline thống nhất cho mọi loại asset trong 1 lần gọi. Mỗi row \
        khai báo exporter='tagged' (eIC*/eImage*, đi xcassets pipeline với @2x/@3x) \
        hoặc exporter='fallback' (untagged hoặc FLATTEN region, render qua /v1/images \
        scale 3, dedupe vào sharedAssetsDir, validate PNG signature). Tagged row bị \
        render lỗi sẽ tự động chuyển sang fallback. Lottie placeholder (strategy= \
        'lottiePlaceholder') được pass-through, không download. Trả manifest đầy đủ \
        per-row để skill chỉ việc ghi xuống manifest.json.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("fileKey"), .string("nodeId"), .string("outputDir"), .string("sharedAssetsDir")]),
            "properties": .object([
                "fileKey": .object([
                    "type": .string("string"),
                    "description": .string("Figma file key.")
                ]),
                "nodeId": .object([
                    "type": .string("string"),
                    "description": .string("Root node — dùng để fetch tree cho phần tagged.")
                ]),
                "outputDir": .object([
                    "type": .string("string"),
                    "description": .string("Đường dẫn tuyệt đối: thư mục output cho tagged path. Tagged PNG được lưu ở outputDir/_mcpfigma/ rồi copy sang xcassets.")
                ]),
                "sharedAssetsDir": .object([
                    "type": .string("string"),
                    "description": .string("Đường dẫn tuyệt đối: thư mục chia sẻ cho fallback path (dedup theo nodeId).")
                ]),
                "assetCatalogPath": .object([
                    "type": .string("string"),
                    "description": .string("Tùy chọn: .xcassets path để import imageset cho tagged row.")
                ]),
                "rows": .object([
                    "type": .string("array"),
                    "description": .string("Mỗi phần tử: { nodeId, exporter ('tagged'|'fallback'), exportName?, friendlyName?, strategy ('atomic'|'flatten'|'lottiePlaceholder', mặc định 'atomic') }."),
                    "items": .object([
                        "type": .string("object"),
                        "required": .array([.string("nodeId"), .string("exporter")]),
                        "properties": .object([
                            "nodeId": .object(["type": .string("string")]),
                            "exporter": .object([
                                "type": .string("string"),
                                "enum": .array([.string("tagged"), .string("fallback")])
                            ]),
                            "exportName": .object(["type": .string("string")]),
                            "friendlyName": .object(["type": .string("string")]),
                            "strategy": .object([
                                "type": .string("string"),
                                "enum": .array([.string("atomic"), .string("flatten"), .string("lottiePlaceholder")])
                            ])
                        ])
                    ])
                ]),
                "scales": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("integer")]),
                    "description": .string("Scale cho tagged path, mặc định [2, 3].")
                ]),
                "fallbackScale": .object([
                    "type": .string("integer"),
                    "description": .string("Scale cho fallback path, mặc định 3.")
                ]),
                "overwrite": .object([
                    "type": .string("boolean"),
                    "description": .string("Ghi đè file sẵn có, mặc định true.")
                ]),
                "skipIfExistsInCatalog": .object([
                    "type": .string("boolean"),
                    "description": .string("Bỏ qua tagged row có imageset đã tồn tại sẵn, mặc định true.")
                ]),
                "autoDiscover": .object([
                    "type": .string("boolean"),
                    "description": .string("Nếu true, server tự quét subtree dưới nodeId qua AssetScanner, sinh tagged row cho mọi eIC*/eImage* tìm được, và merge với rows[] (caller-supplied wins on duplicates by nodeId). eAnim* (Lottie) chỉ được liệt kê trong coverage.animationNodeIds, KHÔNG auto-add. Response thêm khối 'coverage' (discoveredCount, exportedCount, autoAddedRows, skippedNodeIds, animationNodeIds). Mặc định false.")
                ])
            ])
        ])
    )

    static let extractTokens = Tool(
        name: "figma_extract_tokens",
        description: """
        Đọc Figma local variables + shared text styles và map sang SwiftUI \
        naming convention. Trả về colors (lightHex/darkHex theo mode), spacing, \
        radius (đánh dấu isCapsule cho value >= 999), opacity, other, và \
        typography (fontFamily, fontPostScriptName, fontWeight, fontSize, \
        lineHeightPx, letterSpacing, textCase, textAlignHorizontal, italic — \
        đọc từ /v1/files/<key>/styles + /v1/files/<key>/nodes). Tên Figma \
        'primary/500' → swiftName 'primary500'; 'spacing/md' → swiftName 'md'; \
        'Heading 3 28px' → swiftName 'heading328px'. Variables API + /styles \
        có thể fail độc lập — phần nào fail trả empty + warning, phần khác vẫn \
        ra output.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("fileKey")]),
            "properties": .object([
                "fileKey": .object([
                    "type": .string("string"),
                    "description": .string("Figma file key.")
                ])
            ])
        ])
    )
}
