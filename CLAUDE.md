# CLAUDE.md — MCPFigma

Swift MCP server export PNG icons/images từ Figma về project iOS. Trước khi sửa bất kỳ thứ gì, đọc hết file này. Không assume. Không tự chế. Không bypass.

## Nguyên tắc làm việc

1. **Đi vào trọng tâm.** User hỏi A thì trả lời A, không kèm refactor B/C "nhân tiện".
2. **Không tự suy diễn intent.** Nếu yêu cầu mơ hồ hoặc va chạm với logic hiện có → hỏi lại, không tự chọn.
3. **Test là contract, không phải gánh nặng.** Test failing không bao giờ được "fix" bằng cách loosen assertion hoặc xóa test. Hiểu test trước, sửa code sau. Nếu cảm thấy test sai → confirm với user trước khi đổi.
4. **Output JSON chỉ được thêm field, không bao giờ remove/rename.** Tool name và `inputSchema` keys giữ nguyên — caller (skill, Claude Desktop) đang phụ thuộc.
5. **Comment chỉ khi WHY không hiển nhiên.** Không "// added for refactor", "// fix bug X", "// see PR #..." — git blame có sẵn rồi.

## Logic prefix — SACRED, không đổi

| Prefix    | Hành vi                                                                                |
|-----------|----------------------------------------------------------------------------------------|
| `eIC*`    | icon. Stop descent. Tải qua tagged pipeline (`@2x`/`@3x` → `.xcassets`).               |
| `eImage*` | image. Stop descent. Tải qua tagged pipeline.                                          |
| `eAnim*`  | lottie placeholder. Stop descent. **KHÔNG tải.** Skill SwiftUI tự đặt placeholder.    |
| khác      | Descend vào children, tiếp tục tìm.                                                     |

Validate remainder: ký tự đầu tiên sau prefix phải ASCII uppercase; chỉ cho phép `[A-Za-z0-9_]`.

**Edge case đã quyết:** node có prefix tagged nhưng remainder malformed (vd `eIChome`, `eImage`) → emit warning **VÀ vẫn descend** (coi như typo trên parent, con vẫn có thể valid). Có 2 test enforce điều này: `invalidPrefixWarnsAndStillRecurses`, `invalidImageContainerStillRecurses` trong `AssetScannerTests.swift`. **Không sửa hành vi này nếu chưa hỏi user.**

## Invariants kiến trúc

- **Single source of truth cho prefix strings:** chỉ `AssetNameRewriter` biết `"eIC"`, `"eImage"`, `"eAnim"`. Không hardcode prefix ở chỗ khác.
- **Single tree traversal:** `AssetScanner.scan` đi qua cây 1 lần, phân loại vào `matches` (icon/image) và `animations` (eAnim). `RegistryBuilder` tiêu thụ kết quả đó — không tự walk lại.
- **Single tree fetch trong UnifiedExporter:** khi `autoDiscover=true`, chỉ 1 lần `api.fetchNodes` cho root. `AssetExporter` có overload nhận sẵn `root` + `scan` — dùng overload đó, không gọi `fetchNodes` lần 2.
- **Correlation strict theo `nodeId`:** `mapTaggedOutcomes` dùng nodeId map, KHÔNG dùng `String.contains` trên `exportName` (sẽ misfire `icAIChevron` ↔ `icAIChevronDown`). `SavedFile`/`ExportFailure` mang `nodeId` end-to-end.
- **eAnim không bao giờ chạm pipeline tải:** autoDiscover không add eAnim vào rows. Nếu caller pass row trỏ vào eAnim node → coerce sang `.lottiePlaceholder` strategy (no-op pass-through).

## Layout source

```
Sources/MCPFigmaCore/
  Domain/
    AssetNameRewriter.swift     # prefix → kind, tên iOS
    AssetScanner.swift          # 1 walk, 3 prefix
    RegistryBuilder.swift       # screens + assets + lottie từ scan
    AssetExporter.swift         # tagged pipeline (@2x/@3x → xcassets)
    UnifiedExporter.swift       # orchestrator: tagged + fallback + lottie
    AssetCatalogWriter.swift    # ghi imageset vào .xcassets
    AssetCatalogResolver.swift  # tìm .xcassets từ project path
    TokenExtractor.swift        # variables → SwiftUI tokens
    TextStyleExtractor.swift    # /styles → typography tokens
    SwiftNameMapper.swift       # 'primary/500' → 'primary500'
  Figma/                        # FigmaClient, models, endpoints
  Utils/RetryPolicy.swift

Sources/MCPFigmaServer/
  Server/FigmaMCPServer.swift   # tool dispatch + JSON encode
  Server/ToolDefinitions.swift  # MCP tool schemas (5 tools)
  Entry.swift
```

## Tools MCP (không thêm tool mới nếu chưa hỏi)

1. `figma_list_assets` — preview, không tải.
2. `figma_export_assets` — tải tagged về dir + import xcassets.
3. `figma_build_registry` — screens + tagged + lottie + warnings trong 1 call.
4. `figma_export_assets_unified` — pipeline thống nhất (tagged + fallback + lottie pass-through), khuyến nghị dùng cái này.
5. `figma_extract_tokens` — colors/spacing/radius/opacity/typography.

## Workflow build & test

```bash
swift build           # debug build
swift test            # toàn bộ test (76 tests, 12 suites)
swift test --filter AssetScannerTests
```

**Không commit** khi `swift test` đỏ. **Không skip test** bằng `.disabled()` hoặc `withKnownIssue` để qua CI — fix root cause.

## Hành vi an toàn bắt buộc

- **PNG signature check** ở fallback path là an toàn, không bypass. Output không phải PNG → fail row, không "auto-convert" silently.
- **Retry policy** ở `FigmaClient` (429/5xx) không bypass bằng `try?`. Lỗi phải bubble lên để caller xử lý.
- **`overwrite` flag** mặc định `true` cho dev nhưng `skipIfExistsInCatalog=true` để không đè imageset đã tồn tại trong xcassets — giữ default này.
- **Path validation:** `outputDir` và `sharedAssetsDir` phải là absolute path (`hasPrefix("/")`). Server reject relative path. Không nới rule này.
- **Token đọc từ env `FIGMA_TOKEN`** — không hardcode, không log token, không echo ra response.

## Khi cần refactor

1. Đọc tests trong `Tests/MCPFigmaCoreTests/` cho module bị động — chúng encode contract.
2. Giữ public API surface tối thiểu. Internal helpers thì `internal`/`private`.
3. Không thêm public type cho dùng nội bộ.
4. Không thêm dependency mới mà chưa confirm — `Package.swift` đang gọn.
5. Không tạo file `.md` mới (skill docs, design notes, v.v.) trừ khi user yêu cầu.

## Khi cần debug

- Reproduce bằng test trước khi sửa code.
- Log qua `FileHandle.standardError` (stdio transport chiếm stdout — log ra stdout sẽ phá MCP protocol).
- Lỗi Figma API: kiểm tra `FigmaAPIError` cases, không catch chung `Error` để swallow.
