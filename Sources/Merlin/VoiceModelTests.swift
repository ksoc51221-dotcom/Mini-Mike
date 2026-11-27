import Foundation

/// The voice model prompt: which fault shows which words, and when a late claim may still change the pill.
extension FeatureTests {
    static func voiceModelChecks(_ check: (String, Bool) -> Void) {
        typealias P = Dictation.ModelProblem
        check("model: no English locale from macOS is a lookup fault, not a missing model",
              P.decide(localeFound: false, onMac: false) == .noLocale)
        check("model: not on this Mac is the only case that asks to download",
              P.decide(localeFound: true, onMac: false) == .notOnMac)
        check("model: on this Mac but not claimed is 'not ready'", P.decide(localeFound: true, onMac: true) == .notReady)

        let probe = Dictation.ModelProbe(locale: "en-US", status: "supported", onMac: true, hasFormat: false, reserved: ["en-US"])
        check("model: a probe of a model on this Mac gives 'not ready'", probe.problem == .notReady)
        check("model: the probe line names status, locale and fault",
              probe.line.contains("status=supported") && probe.line.contains("locale=en-US") && probe.line.contains("notReady"))

        for problem in [P.notReady, .noLocale] {
            let words = VoiceController.modelCaption("English", problem) + " " + VoiceController.modelHint(problem)
            check("model: \(problem) never says 'isn't on this Mac' or 'Download'",
                  !words.contains("isn't on this Mac") && !words.contains("Download"))
        }
        check("model: the missing-model prompt still offers the download",
              VoiceController.modelHint(.notOnMac).contains("Download"))

        typealias V = VoiceController
        check("late claim: may end the wait", V.acceptsLateResult(.working(V.claimingText)))
        check("late claim: may replace the 45 s 'not ready' prompt with Ready", V.acceptsLateResult(.needsModel("English", .notReady)))
        check("late claim: may replace a 'no answer' prompt", V.acceptsLateResult(.needsModel("English", .noLocale)))
        check("late claim: never covers the Download prompt", !V.acceptsLateResult(.needsModel("English", .notOnMac)))
        check("late claim: never covers a new press", !V.acceptsLateResult(.listening))
        check("late claim: never covers another working line", !V.acceptsLateResult(.working("Transcribing…")))
        check("late claim: never covers a message", !V.acceptsLateResult(.message("Ready.")))
        // A stale status (macOS ended the speech helper): the engine is the judge, not the status.
        check("voice model: installed with a format is ready", Dictation.readiness(installed: true, onMac: true, hasFormat: true) == .ready)
        check("voice model: status not installed but on this Mac with a format: try the engine, no prompt yet",
              Dictation.readiness(installed: false, onMac: true, hasFormat: true) == .tryEngine)
        check("voice model: not on this Mac is not ready", Dictation.readiness(installed: false, onMac: false, hasFormat: true) == .notReady)
        check("voice model: no audio format is not ready", Dictation.readiness(installed: false, onMac: true, hasFormat: false) == .notReady)
        check("voice model: installed without a format is not ready", Dictation.readiness(installed: true, onMac: true, hasFormat: false) != .ready)
        let flag = Dictation.Flag()
        flag.set(true)
        check("voice model: the stale-status flag keeps its value", flag.get())
    }
}
