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

    @Test("appendSizeSuffix appends WxH for valid dims, rounded to nearest int")
    func appendSizeSuffixHappyPath() {
        #expect(
            AssetNameRewriter.appendSizeSuffix(renamed: "icAIFacebook", width: 24, height: 24)
                == "icAIFacebook24x24"
        )
        #expect(
            AssetNameRewriter.appendSizeSuffix(renamed: "imageAIBanner", width: 375.4, height: 812.6)
                == "imageAIBanner375x813"
        )
    }

    @Test("appendSizeSuffix returns renamed unchanged when dims missing or non-positive")
    func appendSizeSuffixFallback() {
        #expect(
            AssetNameRewriter.appendSizeSuffix(renamed: "icAIHome", width: nil, height: nil)
                == "icAIHome"
        )
        #expect(
            AssetNameRewriter.appendSizeSuffix(renamed: "icAIHome", width: 24, height: nil)
                == "icAIHome"
        )
        #expect(
            AssetNameRewriter.appendSizeSuffix(renamed: "icAIHome", width: 0, height: 24)
                == "icAIHome"
        )
        #expect(
            AssetNameRewriter.appendSizeSuffix(renamed: "icAIHome", width: 0.4, height: 0.4)
                == "icAIHome"
        )
    }

    // ── rewriteFlexible: case recovery for designer typos ────────────────────

    @Test("rewriteFlexible matches canonical prefixes strictly (no flag set)")
    func rewriteFlexibleStrict() throws {
        let r = try rewriter.rewriteFlexible("eICHome")
        #expect(r.kind == .icon)
        #expect(r.renamed == "icAIHome")
        #expect(r.prefixCaseMismatch == false)
        #expect(r.originalPrefix == nil)
    }

    @Test(
        "rewriteFlexible recovers from case-variant prefix and flags case mismatch",
        arguments: [
            ("EICHome",   "icAIHome",      "EIC"),
            ("EicHome",   "icAIHome",      "Eic"),
            ("eIcHome",   "icAIHome",      "eIc"),
            ("EIMAGEBanner", "imageAIBanner", "EIMAGE"),
            ("EIMageBanner", "imageAIBanner", "EIMage"),
            ("eANIMSplash", "eAnimSplash",  "eANIM"),
        ]
    )
    func rewriteFlexibleCaseRecovery(input: String, expectedRenamed: String, expectedOriginalPrefix: String) throws {
        let r = try rewriter.rewriteFlexible(input)
        #expect(r.renamed == expectedRenamed)
        #expect(r.prefixCaseMismatch == true)
        #expect(r.originalPrefix == expectedOriginalPrefix)
    }

    @Test("rewriteFlexible auto-uppercases lowercase first remainder char")
    func rewriteFlexibleAutoUppercaseRemainder() throws {
        // `eichome` — prefix and first remainder char both lowercase. Recovery
        // canonicalizes the prefix AND auto-uppercases `h` → `H`, otherwise
        // strict validate() would reject "home" as invalidName.
        let r = try rewriter.rewriteFlexible("eichome")
        #expect(r.renamed == "icAIHome")
        #expect(r.prefixCaseMismatch == true)
        #expect(r.originalPrefix == "eic")
    }

    @Test(
        "rewriteFlexible passes through notExportable for non-Figma names",
        arguments: ["Home", "icon_home", "iconHome", "random_thing"]
    )
    func rewriteFlexibleNotExportable(input: String) {
        #expect(throws: RewriteError.self) {
            _ = try rewriter.rewriteFlexible(input)
        }
    }

    @Test("rewriteFlexible still rejects illegal chars in the remainder")
    func rewriteFlexibleIllegalCharsStillRejected() {
        #expect(throws: RewriteError.self) {
            _ = try rewriter.rewriteFlexible("EICHome-2")  // hyphen illegal
        }
    }
}
