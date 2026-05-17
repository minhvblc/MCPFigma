import Foundation
import MCP

enum ToolDefinitions {
    static let all: [Tool] = [
        listAssets,
        exportAssets,
        buildRegistry,
        exportAssetsUnified,
        extractTokens,
        extractFills
    ]

    static let listAssets = Tool(
        name: "figma_list_assets",
        description: """
        Liệt kê các asset có prefix eIC* (icon) hoặc eImage* (image) trong một node Figma. \
        Node có prefix eAnim* (Lottie placeholder) sẽ bị bỏ qua, không đào sâu vào con. \
        Ngoài ra, node graphic-leaf chưa đặt tên (VECTOR hoặc có IMAGE fill, không có con) \
        cũng được tự nhận diện và đặt tên icAI*/imageAI* suy từ tên layer. \
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
        Tải các asset eIC*/eImage* — và node graphic-leaf untagged tự nhận diện (VECTOR \
        hoặc có IMAGE fill, không có con) — trong một node Figma về thư mục đích dưới dạng PNG \
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
        (2) candidateScreens — phone-sized FRAME nodes nested under a Group root (P0-1 fix: \
        khi root là Group thay vì Board, screens sẽ rỗng — đọc candidateScreens thay); \
        (3) taggedAssets — eIC*/eImage* đã đổi tên iOS (icAI*/imageAI*), kèm cả node graphic-leaf \
        untagged (VECTOR / IMAGE fill, không có con) tự nhận diện cùng tên icAI*/imageAI*; \
        (4) taggedAssetsTotalCount + nextCursor — pagination cho asset list (P0-3 fix); \
        (5) lottiePlaceholders — eAnim* với kích thước frame; \
        (6) warnings — non-screen-detection warnings + ROOT_IS_GROUP/NO_DIRECT_SCREENS reasons; \
        (7) recommendedNextCall — server-side hint về tool kế tiếp nên gọi (P1-2). \
        Skill dùng output này thay cho việc gọi figma_list_assets + walk metadata.json riêng lẻ.
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
                ]),
                "summaryOnly": .object([
                    "type": .string("boolean"),
                    "description": .string("Nếu true, taggedAssets[] chỉ trả 10 sample đầu + nextCursor để paginate; full count vẫn được show qua taggedAssetsTotalCount. Mặc định false. Hữu ích khi caller chỉ muốn biết screen count + asset count mà không cần list chi tiết.")
                ]),
                "pageSize": .object([
                    "type": .string("integer"),
                    "description": .string("P0-3: trang taggedAssets[] tối đa N entries. Khi set, dùng kèm cursor để paginate. Bỏ qua nếu cần full list (size không vượt context limit).")
                ]),
                "cursor": .object([
                    "type": .string("integer"),
                    "description": .string("P0-3: offset bắt đầu của trang taggedAssets[]. Lấy giá trị nextCursor từ lần gọi trước. Mặc định 0.")
                ]),
                "renameRules": .object([
                    "type": .string("array"),
                    "description": .string("P1-1: custom prefix rules cho project không dùng convention eIC*/eImage*. Mỗi entry: {figmaPrefix: string, renamedPrefix: string, kind: 'icon'|'image'|'animation'}. Custom rules được check trước built-in. Kebab/snake-case remainder được tự normalize sang camelCase.")
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
        scale 3 mặc định, dedupe vào sharedAssetsDir, validate PNG signature). Tagged \
        row bị render lỗi sẽ tự động chuyển sang fallback. Lottie placeholder \
        (strategy='lottiePlaceholder') được pass-through, không download. Trả manifest \
        đầy đủ per-row để skill chỉ việc ghi xuống manifest.json. \
        Fallback exporter cũng dùng được để render full-frame PNG bất kỳ node nào (vd \
        làm visual reference cho C5 side-by-side compare khi figma-desktop \
        get_screenshot không khả dụng) — pass row {nodeId, exporter='fallback', \
        strategy='flatten'} với fallbackScale=2 (xem note ở field fallbackScale về \
        Claude many-image 2000px limit).
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
                    "description": .string("Scale cho fallback path, mặc định 3. Lưu ý: scale 3 trên iPhone-frame ≈1125×2436 (X) / 1179×2556 (14 Pro) → vượt 2000px là Claude many-image dimension limit. Khi render full-frame để Claude đọc song song với ảnh khác (vd C5 visual diff), dùng 2 (≈750×1624) để tránh lỗi 'exceeds the dimension limit for many-image requests'. Per-asset icon export vẫn nên giữ scale 3.")
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
                    "description": .string("Nếu true, server tự quét subtree dưới nodeId qua AssetScanner, sinh tagged row cho mọi eIC*/eImage* + node graphic-leaf untagged tìm được, và merge với rows[] (caller-supplied wins on duplicates by nodeId). eAnim* (Lottie) chỉ được liệt kê trong coverage.animationNodeIds, KHÔNG auto-add. Response thêm khối 'coverage' (discoveredCount, exportedCount, autoAddedRows, skippedNodeIds, animationNodeIds). Mặc định false.")
                ])
            ])
        ])
    )

    static let extractFills = Tool(
        name: "figma_extract_fills",
        description: """
        Trích cấu trúc paint fills của một subtree Figma — bao quát các trường hợp \
        figma_extract_tokens không xử lý: background image (IMAGE fill với imageRef + \
        scaleMode), gradient overlay (GRADIENT_LINEAR/RADIAL với stops + handle \
        positions), và stack image+gradient (nhiều fill trên cùng node). Chỉ trả về \
        node "đáng quan tâm": fill duy nhất kiểu SOLID 100% opacity bị filter (đã có \
        trong design-context.md / tokens.json). Mỗi gradient có stops chuẩn hoá \
        position+hex, startPoint/endPoint trong unit space (SwiftUI UnitPoint), \
        opacity paint-level. Mỗi IMAGE fill kèm imageRef đã resolve sang CDN URL \
        thông qua /v1/files/<key>/images. Skill ghi output vào \
        .figma-cache/<nodeId>/fills.json và đọc khi codegen ZStack { Image; \
        LinearGradient }. Nếu /nodes endpoint fail → throw; nếu /files/<key>/images \
        fail → trả fills không kèm imageUrl + warning.
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
                    "description": .string("Node ID root — server sẽ walk subtree và lọc node có fill đáng quan tâm (gradient/image/stacked/translucent).")
                ]),
                "depth": .object([
                    "type": .string("integer"),
                    "description": .string("Độ sâu tối đa khi fetch cây. Mặc định 10 (đủ cho hầu hết screen Figma).")
                ]),
                "resolveImageUrls": .object([
                    "type": .string("boolean"),
                    "description": .string("Nếu true (mặc định), gọi /v1/files/<key>/images để resolve imageRef → CDN URL cho mọi IMAGE fill. Đặt false để bỏ qua khi không cần URL (tiết kiệm 1 HTTP call).")
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
