#if BENCH
import AppKit

/// The one entry point the product knows about for offline measurement.
///
/// Everything under `Sources/Bench/` is measurement scaffolding, not product: it is compiled only in
/// debug (`swiftSettings: [.define("BENCH", .when(configuration: .debug))]` in Package.swift), so a
/// release build contains none of it. It lives in its own directory because it used to sit in
/// `Sources/` interleaved alphabetically with the app, which made the shipped surface look bigger than
/// it is and put bench flags in the reader's way while they were trying to follow the product.
///
/// `BetterVoice2Main` calls `runIfRequested()` and nothing else. The dispatch it replaced was ~25
/// lines of flag parsing and `NSApplication` setup inline in the app's entry point, which meant the
/// first thing anyone read about this product was how to benchmark it.
@MainActor
enum BenchEntry {

    /// Run a bench harness if the command line asks for one.
    ///
    /// Returns true when a harness ran and the process should exit rather than launching the GUI.
    /// Each harness needs a live `NSApplication` — the import pipeline awaits main-actor work and the
    /// editor harness drives real views — but as `.accessory`, so nothing appears on screen and no
    /// Dock icon shows up during a scripted run.
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments

        // Offline import-pipeline evaluation. See ImportBenchmark for the flag list.
        if args.contains("--bench-meeting") {
            runAccessory { finish in
                Task {
                    await ImportBenchmark.run()
                    finish()
                }
            }
            return true
        }

        // Editor edit/dirty/save chain sanity check, no GUI interaction needed.
        if args.contains("--bench-editor") {
            let harness = EditorBenchHarness()
            runAccessory { finish in harness.run(onDone: finish) }
            return true
        }

        return false
    }

    /// Start an accessory-policy NSApplication, hand the caller a completion that terminates it, and
    /// block in the run loop until then.
    private static func runAccessory(_ body: (@escaping () -> Void) -> Void) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        body { app.terminate(nil) }
        app.run()
    }
}
#endif
