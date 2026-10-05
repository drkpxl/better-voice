import XCTest
@testable import BetterVoiceCore

final class VocabularyBoostTermsTests: XCTestCase {
    func testTermsAndReplacementsBecomeTermsWithAliases() {
        let out = VocabularyBoostTerms.build(
            terms: ["Kubernetes", "Priya"],
            replacements: [VocabularyReplacement(from: "cooper net ease", to: "Kubernetes"),
                           VocabularyReplacement(from: "summit pass", to: "Summit Pass")]
        )
        XCTAssertEqual(out, [
            .init(text: "Kubernetes", aliases: ["cooper net ease"]),
            .init(text: "Priya", aliases: []),
            .init(text: "Summit Pass", aliases: []),   // alias equal to the term is dropped
        ])
    }

    func testCaseInsensitiveMergeKeepsFirstSpelling() {
        let out = VocabularyBoostTerms.build(terms: ["iPhone", "IPHONE"], replacements: [])
        XCTAssertEqual(out, [.init(text: "iPhone", aliases: [])])
    }

    func testShortTermsDropped() {
        let out = VocabularyBoostTerms.build(terms: ["VR", "AI", "Ada"], replacements: [VocabularyReplacement(from: "or", to: "OR")])
        XCTAssertEqual(out.map(\.text), ["Ada"])
    }

    func testDuplicateAliasesCollapse() {
        let out = VocabularyBoostTerms.build(
            terms: [],
            replacements: [VocabularyReplacement(from: "jet hub", to: "GitHub"),
                           VocabularyReplacement(from: "Jet Hub", to: "github")]
        )
        XCTAssertEqual(out, [.init(text: "GitHub", aliases: ["jet hub"])])
    }
}
