import Foundation
import MCPFigmaCore

@main
struct MCPFigmaServerApp {
    static func main() async {
        guard let token = ProcessInfo.processInfo.environment["FIGMA_ACCESS_TOKEN"], !token.isEmpty else {
            FileHandle.standardError.write(Data(
                "[mcp-figma] Missing FIGMA_ACCESS_TOKEN env var — set it in your MCP client config.\n".utf8
            ))
            exit(1)
        }

        let api = FigmaClient(token: token)
        let runner = FigmaMCPServer(api: api)

        do {
            try await runner.run()
        } catch {
            FileHandle.standardError.write(Data("[mcp-figma] fatal: \(error)\n".utf8))
            exit(2)
        }
    }
}
