import XCTest
@testable import BetterVoiceCore

final class SpeechLanguageRulesTests: XCTestCase {
    func testExplicitEnglishStrips() {
        XCTAssertTrue(SpeechLanguageRules.fillerStrippingApplies(speechLanguage: "en", preferredLanguages: ["de-DE"]))
    }

    func testExplicitOtherLanguageDoesNotStrip() {
        XCTAssertFalse(SpeechLanguageRules.fillerStrippingApplies(speechLanguage: "de", preferredLanguages: ["en-US"]))
    }

    func testAutomaticFollowsPrimarySystemLanguage() {
        XCTAssertTrue(SpeechLanguageRules.fillerStrippingApplies(speechLanguage: nil, preferredLanguages: ["en-GB", "fr-FR"]))
        XCTAssertFalse(SpeechLanguageRules.fillerStrippingApplies(speechLanguage: "", preferredLanguages: ["nl-NL", "en-US"]))
    }

    func testAutomaticWithNoSystemLanguagesKeepsDefault() {
        XCTAssertTrue(SpeechLanguageRules.fillerStrippingApplies(speechLanguage: nil, preferredLanguages: []))
    }

    func testPrimarySubtag() {
        XCTAssertEqual(SpeechLanguageRules.primarySubtag("zh-Hans-CN"), "zh")
        XCTAssertEqual(SpeechLanguageRules.primarySubtag("EN_us"), "en")
    }
}
