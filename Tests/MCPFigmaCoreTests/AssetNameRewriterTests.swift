import Testing
@testable import MCPFigmaCore

@Suite("AssetNameRewriter")
struct AssetNameRewriterTests {
    let rewriter = AssetNameRewriter()

    @Test(
        "eIC prefix rewrites to icAI icon",
        arguments: [
            ("eICHome", "icAIHome"),
            ("eICArrowRight", "icAIArrowRight"),
            ("eICUser", "icAIUser"),
            ("eICHome123", "icAIHome123"),
            ("eICHome_2", "icAIHome_2"),
            ("eICA", "icAIA")
        ]
    )
    func iconRewrite(input: String, expected: String) throws {
        let result = try rewriter.rewrite(input)
        #expect(result.kind == .icon)
        #expect(result.renamed == expected)
    }

    @Test(
        "eImage prefix rewrites to imageAI image",
        arguments: [
            ("eImageBanner", "imageAIBanner"),
            ("eImageAvatar", "imageAIAvatar"),
            ("eImageBackgroundHero", "imageAIBackgroundHero"),
            ("eImageOnboarding1", "imageAIOnboarding1")
        ]
    )
    func imageRewrite(input: String, expected: String) throws {
        let result = try rewriter.rewrite(input)
        #expect(result.kind == .image)
        #expect(result.renamed == expected)
    }

    @Test("Trims whitespace before matching")
    func trimsWhitespace() throws {
        let result = try rewriter.rewrite("  eICHome  ")
        #expect(result.renamed == "icAIHome")
    }

    @Test(
        "Prefix with empty remainder is rejected",
        arguments: ["eIC", "eImage"]
    )
    func emptyRemainderRejected(input: String) {
        #expect(throws: RewriteError.self) {
            _ = try rewriter.rewrite(input)
        }
    }

    @Test(
        "Lowercase char after prefix is rejected",
        arguments: ["eICh", "eImagebanner", "eIChome"]
    )
    func lowercaseRemainderRejected(input: String) {
        #expect(throws: RewriteError.self) {
            _ = try rewriter.rewrite(input)
        }
    }

    @Test(
        "Non-matching names are notExportable",
        arguments: ["Home", "icon_home", "iconHome", "e", "eI", ""]
    )
    func noPrefixRejected(input: String) {
        #expect(throws: RewriteError.self) {
            _ = try rewriter.rewrite(input)
        }
    }

    @Test(
        "Illegal characters are rejected",
        arguments: ["eICHome-2", "eICHome 2", "eImageBanner!", "eICHomé", "eImageBánner"]
    )
    func illegalCharsRejected(input: String) {
        #expect(throws: RewriteError.self) {
            _ = try rewriter.rewrite(input)
        }
    }

    @Test("fileName composes @2x/@3x.png correctly")
    func fileNameComposition() {
        #expect(AssetNameRewriter.fileName(renamed: "icAIHome", scale: 2) == "icAIHome@2x.png")
        #expect(AssetNameRewriter.fileName(renamed: "imageAIBanner", scale: 3) == "imageAIBanner@3x.png")
    }
}
