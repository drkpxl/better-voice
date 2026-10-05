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
            to: "Grafanna said Grafanna.",
            swaps: [Swap(original: "Grafanna", replacement: "Grafana"), Swap(original: "Grafanna.", replacement: "Grafana")],
            aliases: [:]
        )
        XCTAssertEqual(out, "Grafana said Grafana.")
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
            to: "Use Datadogs tools for Datadob.",
            swaps: [Swap(original: "Datadog", replacement: "DataDog")],
            aliases: [:]
        )
        XCTAssertEqual(out, "Use Datadogs tools for Datadob.", "must not match inside 'Datadogs'")
    }

    func testCaseSensitiveWordMatchSkipsEarlierSubstring() {
        let out = BoostReplacementFilter.apply(
            to: "Ulterras timeline, ask Ulterra.",
            swaps: [Swap(original: "Ulterra", replacement: "Alterra")],
            aliases: [:]
        )
        XCTAssertEqual(out, "Ulterras timeline, ask Alterra.")
    }

    func testUnrelatedOneForOneSwapIsRejected() {
        // Measured in live use: the rescorer swapped a real word for a vocabulary name.
        let text = "It doesn't really match our brand styles, but it works."
        let out = BoostReplacementFilter.apply(
            to: text,
            swaps: [Swap(original: "styles,", replacement: "Emmie"),
                    Swap(original: "functionally it does", replacement: "Ikon Pass"),
                    Swap(original: "top of gray,", replacement: "Allterra")],
            aliases: [:]
        )
        XCTAssertEqual(out, text)
    }

    func testMeasuredCorrectionsStillPass() {
        for (orig, term) in [("Xylequist", "Zylquist"), ("datadob", "Datadog"), ("icon pass", "Ikon Pass"),
                             ("SAOIS", "Saoirse"), ("Ulterra", "Alterra"), ("Kuba needs", "Kubernetes")] {
            XCTAssertTrue(BoostReplacementFilter.isSafe(Swap(original: orig, replacement: term), aliases: [:]), orig)
        }
    }
}
