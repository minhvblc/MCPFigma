# MCPFigma

MCP server viết bằng Swift native, giúp Claude Code / Claude Desktop tự động tải icon và image PNG từ Figma về dự án iOS SwiftUI — đúng scale `@2x` / `@3x`, đúng naming convention, không kéo thả tay.

```
Figma node (eICHome, eImageBanner, …)
        │
        ▼   figma_list_assets / figma_export_assets
  MCP server (Swift)
        │
        ▼   PNG @2x + @3x, tên chuẩn iOS
  /your/ios/project/Resources/icAIHome@2x.png, …
```

## Tính năng

- Quét node Figma, chỉ chọn asset có prefix `eIC*` (icon) hoặc `eImage*` (image) — dừng đệ quy khi gặp, không vét vào con
- Tải PNG ở scale `@2x` và `@3x` (bỏ `@1x`, iOS hiện đại không cần)
- Đổi tên theo convention iOS: `eICHome` → `icAIHome@2x.png`, `eImageBanner` → `imageAIBanner@3x.png`
- Lưu vào folder phẳng do user chỉ định (không `.xcassets`)
- Tự handle rate limit (429), tôn trọng `Retry-After`, retry 5xx với exponential backoff
- Tự xử lý trùng tên: `icAIHome` + `icAIHome_2` nếu có 2 node cùng tên
- Surface warning cho tên gần-đúng-nhưng-sai (ví dụ typo `eIChome` lowercase)

## Yêu cầu

- macOS 13+ (Ventura)
- Swift 6.0+ (Xcode 16+ hoặc toolchain đi kèm)
- Figma Personal Access Token — tạo tại https://www.figma.com/settings, cần scope *File content read*

## Cài đặt & build

```bash
git clone <repo-url> MCPFigma
cd MCPFigma
swift build -c release
```

Binary sẽ ở `.build/release/mcp-figma`.

## Cấu hình Claude

### Claude Desktop

Sửa `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "figma-assets": {
      "command": "/ABSOLUTE/PATH/TO/MCPFigma/.build/release/mcp-figma",
      "env": {
        "FIGMA_ACCESS_TOKEN": "figd_xxxxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

### Claude Code

Thêm vào `~/.claude.json` (hoặc `.claude/mcp.json` ở project level):

```json
{
  "mcpServers": {
    "figma-assets": {
      "command": "/ABSOLUTE/PATH/TO/MCPFigma/.build/release/mcp-figma",
      "env": {
        "FIGMA_ACCESS_TOKEN": "figd_xxxxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

Restart Claude (Cmd+Q rồi mở lại) để nạp cấu hình.

## Figma naming convention

Đặt tên **camelCase** cho frame/component trên Figma:

| Prefix Figma | Ý nghĩa | Export thành |
|---|---|---|
| `eIC<Name>` | Icon | `icAI<Name>@2x.png`, `icAI<Name>@3x.png` |
| `eImage<Name>` | Image | `imageAI<Name>@2x.png`, `imageAI<Name>@3x.png` |

**Ví dụ**:
- `eICHome` → `icAIHome@2x.png`, `icAIHome@3x.png`
- `eICArrowRight` → `icAIArrowRight@2x.png`, `icAIArrowRight@3x.png`
- `eImageOnboarding1` → `imageAIOnboarding1@2x.png`, `imageAIOnboarding1@3x.png`

**Quy tắc validate**:
- Ký tự đầu sau prefix phải là chữ cái ASCII viết hoa: `eIC**H**ome` ✅, `eIC**h**ome` ❌
- Phần còn lại chỉ cho `[A-Za-z0-9_]`: `eICHome_2` ✅, `eICHome-2` ❌, `eICHomé` ❌
- Node có prefix nhưng sai quy tắc sẽ **không export** và emit warning trong output

## Tool MCP

### `figma_list_assets`

Preview: liệt kê asset sẽ export, không tải file.

**Input**:
```json
{
  "fileKey": "ABC123xyz",
  "nodeId": "1:2",
  "depth": 10
}
```

**Output** (JSON string trong content):
```json
{
  "matches": [
    { "nodeId": "1:3", "figmaName": "eICHome", "kind": "icon", "exportName": "icAIHome" },
    { "nodeId": "1:4", "figmaName": "eImageBanner", "kind": "image", "exportName": "imageAIBanner" }
  ],
  "warnings": [
    { "nodeId": "1:5", "figmaName": "eIChome", "reason": "Tên 'eIChome' không hợp lệ — …" }
  ]
}
```

### `figma_export_assets`

Tải về PNG `@2x` + `@3x`, lưu vào `outputDir`.

**Input**:
```json
{
  "fileKey": "ABC123xyz",
  "nodeId": "1:2",
  "outputDir": "/Users/you/Projects/MyApp/Resources",
  "nodeIds": ["1:3", "1:4"],
  "scales": [2, 3],
  "overwrite": true
}
```

- `nodeIds` (tùy chọn): chỉ export subset, nếu bỏ qua thì export tất cả matches
- `scales` (tùy chọn): mặc định `[2, 3]`
- `overwrite` (tùy chọn): mặc định `true`

**Output**:
```json
{
  "savedFiles": [
    { "figmaName": "eICHome", "exportName": "icAIHome", "scale": 2, "path": "/.../icAIHome@2x.png" },
    { "figmaName": "eICHome", "exportName": "icAIHome", "scale": 3, "path": "/.../icAIHome@3x.png" }
  ],
  "skipped": [],
  "errors": [],
  "warnings": []
}
```

## Cách dùng trong Claude

Ví dụ prompt:

> Dùng mcp-figma liệt kê asset trong file `ABC123` node `1:2` cho tôi xem.

Claude sẽ gọi `figma_list_assets` và trả về danh sách matches + warnings.

Tiếp theo:

> Export tất cả về `/Users/me/Projects/MyApp/Resources`

Claude gọi `figma_export_assets`, trả về danh sách file đã lưu. Sau đó chỉ việc kéo folder vào Xcode (hoặc dùng `Add Files to "Project"`). Trong SwiftUI:

```swift
Image("icAIHome")
Image("imageAIBanner")
```

Xcode tự pick `@2x` / `@3x` theo device.

## Lấy Figma file key và node ID

URL Figma có dạng:

```
https://www.figma.com/file/ABC123xyz/My-Design?node-id=1-2
                          ^^^^^^^^^             ^^^
                          file key              node id (chuyển `-` thành `:`)
```

Hoặc click phải vào frame → **Copy link** → parse cùng cách. Node ID dùng dạng `1:2` (không phải `1-2`).

## Development

### Chạy test

```bash
swift test
```

32 tests chạy qua 5 suite: `AssetNameRewriter`, `AssetScanner`, `RetryPolicy`, `FigmaClient` (URLProtocol mock), `AssetExporter` (fake API).

### Cấu trúc project

```
MCPFigma/
├── Package.swift
├── Sources/
│   ├── MCPFigmaCore/               # Library — pure logic, không phụ thuộc MCP SDK
│   │   ├── Figma/
│   │   │   ├── FigmaClient.swift   # URLSession + X-Figma-Token + retry
│   │   │   ├── FigmaEndpoints.swift
│   │   │   └── FigmaModels.swift   # Codable types
│   │   ├── Domain/
│   │   │   ├── AssetNameRewriter.swift  # eIC*/eImage* → icAI*/imageAI*
│   │   │   ├── AssetScanner.swift       # duyệt cây, dừng ở prefix match
│   │   │   └── AssetExporter.swift      # orchestrate render + download + save
│   │   └── Utils/
│   │       └── RetryPolicy.swift        # exponential backoff + Retry-After
│   └── MCPFigmaServer/             # Executable — wire MCP SDK với Core
│       ├── Entry.swift             # @main
│       └── Server/
│           ├── FigmaMCPServer.swift     # register handlers
│           └── ToolDefinitions.swift    # JSON Schema của tools
└── Tests/MCPFigmaCoreTests/
    ├── AssetNameRewriterTests.swift
    ├── AssetScannerTests.swift
    ├── RetryPolicyTests.swift
    ├── FigmaClientTests.swift
    └── AssetExporterTests.swift
```

### Debug MCP protocol thủ công

```bash
(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
 sleep 1) | FIGMA_ACCESS_TOKEN=dummy ./.build/release/mcp-figma
```

## Troubleshooting

| Triệu chứng | Nguyên nhân | Fix |
|---|---|---|
| `Missing FIGMA_ACCESS_TOKEN env var` | Chưa set env trong MCP config | Thêm `"env": { "FIGMA_ACCESS_TOKEN": "..." }` vào config |
| `Figma API lỗi: unauthorized` | Token sai hoặc hết hạn | Tạo lại token tại Figma settings |
| `Figma API lỗi: forbidden` | Token không có quyền đọc file | Đảm bảo token có scope *File content read* và file thuộc workspace có quyền |
| `Figma API lỗi: notFound` | `fileKey` hoặc `nodeId` sai | Verify lại URL Figma, `nodeId` dùng dấu `:` không phải `-` |
| Không có file nào được tải | Không có asset nào match prefix `eIC*`/`eImage*` | Check warnings trong output, hoặc rename trên Figma cho đúng |
| Claude không thấy tool | Claude chưa restart sau khi thêm config | Cmd+Q rồi mở lại Claude |

## Architecture

- **Transport**: stdio JSON-RPC — chuẩn MCP local server. Stdout giữ cho protocol, mọi log đi qua stderr.
- **Concurrency**: Swift 6 strict. Download dùng `TaskGroup` với cycling-tasks pattern, concurrency limit mặc định 6.
- **Batch strategy**: `/v1/images` gom tối đa 150 ids/request (URL length safe ≤ 8KB). Hai scale chạy tuần tự để tránh double load Figma.
- **Retry**: chỉ retry 429 + 5xx (tôn trọng `Retry-After`), 401/403/404 fail-fast. Exponential backoff 500ms → 1s → 2s → 4s, cap 10s.
- **URL expiry**: URL PNG từ Figma hết hạn sau 30 ngày — client không cache, luôn request tươi trước khi download.

## License

MIT (xem `LICENSE` nếu có).
