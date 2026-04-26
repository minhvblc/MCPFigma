import Foundation
import MCP

enum ToolDefinitions {
    static let all: [Tool] = [listAssets, exportAssets]

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
}
