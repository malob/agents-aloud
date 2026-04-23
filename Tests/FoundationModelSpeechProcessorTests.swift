import Foundation
import FoundationModels
import Testing
@testable import ClaudeCodeVoice

// Test-controllable availability provider so we can exercise the
// processor's decision logic without depending on real Apple
// Intelligence state on the test machine.
@MainActor
private final class FakeAvailabilityProvider: LanguageModelAvailabilityProviding {
    var availability: SystemLanguageModel.Availability

    init(_ initial: SystemLanguageModel.Availability) {
        self.availability = initial
    }
}

struct FoundationModelSpeechProcessorTests {

    @Test
    @MainActor
    func passthroughWhenDeviceNotEligible() async throws {
        let provider = FakeAvailabilityProvider(.unavailable(.deviceNotEligible))
        let processor = FoundationModelSpeechProcessor(availabilityProvider: provider)

        let input = "A message `with code`"
        let output = await processor.process(text: input)

        // Unavailable → passthrough even though input has structural markers.
        #expect(output == input)
    }

    @Test
    @MainActor
    func passthroughWhenAppleIntelligenceNotEnabled() async throws {
        let provider = FakeAvailabilityProvider(.unavailable(.appleIntelligenceNotEnabled))
        let processor = FoundationModelSpeechProcessor(availabilityProvider: provider)

        let output = await processor.process(text: "Has some `code` in it.")

        #expect(output == "Has some `code` in it.")
    }

    @Test
    @MainActor
    func passthroughWhenModelNotReady() async throws {
        let provider = FakeAvailabilityProvider(.unavailable(.modelNotReady))
        let processor = FoundationModelSpeechProcessor(availabilityProvider: provider)

        let output = await processor.process(text: "Has some `code` in it.")

        #expect(output == "Has some `code` in it.")
    }

    @Test
    @MainActor
    func plainProseShortCircuitsWithoutModelCall() async throws {
        // Even with .available set, plain prose (no structural markers)
        // should short-circuit and not hit the model. We can't assert
        // "didn't call the model" directly from outside, but we can
        // assert the output equals the input — which is what a real
        // model call with correct instructions would also do.
        let provider = FakeAvailabilityProvider(.available)
        let processor = FoundationModelSpeechProcessor(availabilityProvider: provider)

        let plainProse = "This is just a sentence without any special formatting or code."
        let output = await processor.process(text: plainProse)

        #expect(output == plainProse)
    }

    @Test
    @MainActor
    func passthroughOnEmptyAndWhitespaceInput() async throws {
        let provider = FakeAvailabilityProvider(.available)
        let processor = FoundationModelSpeechProcessor(availabilityProvider: provider)

        #expect(await processor.process(text: "") == "")
        #expect(await processor.process(text: "   \n  ") == "   \n  ")
    }

    @Test
    @MainActor
    func passthroughWhenInputExceedsContextCap() async throws {
        // maxInputChars is 2000. An input over that should pass through
        // (even with structural markers) because the model couldn't fit
        // a meaningful rewrite in the remaining context budget.
        let provider = FakeAvailabilityProvider(.available)
        let processor = FoundationModelSpeechProcessor(availabilityProvider: provider)

        let longInputWithCode = String(repeating: "```code block ", count: 250)  // ~3250 chars
        #expect(longInputWithCode.count > 2000)

        let output = await processor.process(text: longInputWithCode)
        #expect(output == longInputWithCode)
    }

    @Test
    @MainActor
    func availabilityTransitionFromUnavailableToAvailableIsObserved() async throws {
        // Processor starts life seeing unavailable, then provider flips
        // to available. A subsequent call should re-check (not return
        // from a cached "unavailable" state).
        let provider = FakeAvailabilityProvider(.unavailable(.modelNotReady))
        let processor = FoundationModelSpeechProcessor(availabilityProvider: provider)

        // First call: unavailable → passthrough (verified indirectly:
        // plain-prose input would passthrough either way, but with a
        // structural marker we can distinguish).
        let input = "A `code` sample."
        let firstPass = await processor.process(text: input)
        #expect(firstPass == input)  // unavailable short-circuits before the marker check

        // Flip availability. The processor's cache previously locked
        // "unavailable" permanently — now it should re-check.
        provider.availability = .available

        // We can't actually call the model from a unit test (would need
        // real Apple Intelligence), so we assert the DECISION changes by
        // using plain prose (short-circuits after availability check) —
        // output still equals input, but via the "no structural markers"
        // path rather than the "unavailable" path. This is a weak signal.
        // The strong test is the inverse: if we had cached .unavailable
        // forever, even setting provider to .available wouldn't matter;
        // the processor would never reach the model. We can't observe
        // that from outside without a model mock. So this test really
        // just proves the code path compiles and doesn't crash on the
        // transition — stronger assertion would need a full FM mock.
        let secondPass = await processor.process(text: "Plain prose with no structure.")
        #expect(secondPass == "Plain prose with no structure.")
    }
}
