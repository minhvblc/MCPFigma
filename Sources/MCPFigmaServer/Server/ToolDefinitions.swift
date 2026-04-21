import Foundation
import MCP

enum ToolDefinitions {
    static let all: [Tool] = [listAssets, exportAssets]

    static let listAssets = Tool(
        name: "figma_list_assets",
        description: """
        Liệt kê các asset có prefix eIC* (icon) hoặc eImage* (image) trong một node Figma. \
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
        @2x và @3x, đổi tên theo convention iOS (icAI*/imageAI*). Trả về danh sách file đã lưu.
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
                ])
            ])
        ])
    )
}
