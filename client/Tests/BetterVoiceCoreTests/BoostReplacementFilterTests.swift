import XCTest
@testable import BetterVoiceCore

final class BoostReplacementFilterTests: XCTestCase {
    typealias Swap = BoostReplacementFilter.Swap

    func testOneForOneSwapKeepsPunctuation() {
        let out = BoostReplacementFilter.apply(
            to: "About the Xylequist migration.",
            swaps: [Swap(original: "Xylequist", replacement: "Zylquist")],
            aliases: [:]
        )
        XCTAssertEqual(out, "About the Zylquist migration.")
    }

    func testSpanThatShrinksIsRejected() {
        // Measured regression: the rescorer replaced a whole span that merely contained the term.
        let text = "and ask Wyn to review the Terraform Plan in Grafana."
        let out = BoostReplacementFilter.apply(
            to: text,
            swaps: [Swap(original: "Terraform Plan in Grafana.", replacement: "Grafana")],
            aliases: [:]
        )
        XCTAssertEqual(out, text)
    }

    func testShrinkingSwapAllowedForKnownAlias() {
        let out = BoostReplacementFilter.apply(
            to: "Deploy it to cooper net ease, please.",
            swaps: [Swap(original: "cooper net ease,", replacement: "Kubernetes")],
            aliases: ["kubernetes": ["Cooper Net Ease"]]
        )
        XCTAssertEqual(out, "Deploy it to Kubernetes, please.")
    }

    func testMixedSwapsApplyOnlyTheSafeOnes() {
        let out = BoostReplacementFilter.apply(
            to: "The Xylequist plan in Grafana.",
            swaps: [Swap(original: "Xylequist", replacement: "Zylquist"),
                    Swap(original: "plan in Grafana.", replacement: "Grafana")],
            aliases: [:]
        )
        XCTAssertEqual(out, "The Zylquist plan in Grafana.")
    }

    func testMissingSpanIsIgnored() {
        let out = BoostReplacementFilter.apply(to: "Hello there.", swaps: [Swap(original: "nope", replacement: "Nope")], aliases: [:])
        XCTAssertEqual(out, "Hello there.")
    }

    func testRepeatedWordReplacesInOrder() {
        let out = BoostReplacementFilter.apply(
            to: "Tig said Tig.",
            swaps: [Swap(original: "Tig", replacement: "Tadhg"), Swap(original: "Tig.", replacement: "Tadhg")],
            aliases: [:]
        )
        XCTAssertEqual(out, "Tadhg said Tadhg.")
    }

    func testSwapsOutOfTranscriptOrderStillApply() {
        // Measured: the rescorer listed 'SAOIS' after swaps later in the sentence.
        let out = BoostReplacementFilter.apply(
            to: "Remind SAOIS about the icon pass.",
            swaps: [Swap(original: "icon pass.", replacement: "Ikon Pass"), Swap(original: "SAOIS", replacement: "Saoirse")],
            aliases: [:]
        )
        XCTAssertEqual(out, "Remind Saoirse about the Ikon Pass.")
    }

    func testShrinkingSwapWithSimilarLettersIsAllowed() {
        let out = BoostReplacementFilter.apply(
            to: "the Kuba needs cluster",
            swaps: [Swap(original: "Kuba needs", replacement: "Kubernetes")],
            aliases: [:]
        )
        XCTAssertEqual(out, "the Kubernetes cluster")
    }

    func testSpanContainingTermPlusExtrasIsRejected() {
        let text = "for baseline makes is failing"
        let out = BoostReplacementFilter.apply(
            to: text,
            swaps: [Swap(original: "baseline makes is", replacement: "Baseline Makes"),
                    Swap(original: "for Palisades Tahoe", replacement: "Palisades Tahoe")],
            aliases: [:]
        )
        XCTAssertEqual(out, text)
    }

    func testShrinkingSwapWithUnrelatedLettersIsRejected() {
        let text = "send it to the whole team"
        let out = BoostReplacementFilter.apply(to: text, swaps: [Swap(original: "whole team", replacement: "Grafana")], aliases: [:])
        XCTAssertEqual(out, text)
    }

    func testSpanInsideALongerWordIsNotReplaced() {
        let out = BoostReplacementFilter.apply(
            to: "A tight deadline for Tig.",
            swaps: [Swap(original: "Tig", replacement: "Tadhg")],
            aliases: [:]
        )
        XCTAssertEqual(out, "A tight deadline for Tadhg.")
    }

    func testCaseSensitiveWordMatchSkipsEarlierSubstring() {
        let out = BoostReplacementFilter.apply(
            to: "Tight timeline, ask Tig.",
            swaps: [Swap(original: "Tig", replacement: "Tadhg")],
            aliases: [:]
        )
        XCTAssertEqual(out, "Tight timeline, ask Tadhg.")
    }
}
