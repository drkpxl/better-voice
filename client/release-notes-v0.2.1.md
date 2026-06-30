# WE v0.2.1

Bugfix release. **No new features** — Meeting Mode L2, custom hotkeys, remote voice, and dictionary correction, all already included in v0.2.0, remain unchanged. This release mainly fixes three real-world issues that left v0.2.0 "unusable" after installation.

## Fixes

### 🔴 Global hotkey unresponsive after install (the hidden root cause)

After installing v0.2.0, pressing Right Option had no effect, the menu bar icon was present, and Accessibility showed as authorized — the root cause is that **CGEventTap requires Input Monitoring permission** (the real requirement on macOS 10.15+), and Accessibility alone isn't enough. `AXIsProcessTrustedWithOptions` returning true and `CGEvent.tapCreate` succeeding do not guarantee that events can actually be delivered.

**Fix**:
- Automatically checks `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` at launch, and shows the system dialog if not authorized
- Startup log now explicitly prints `Input Monitoring: true/false`
- `INSTALL.txt` lists "Input Monitoring" and "Accessibility" separately, making clear that both must be granted

### 🔴 Building from source with `make build` fails (issue #8)

Under Swift 6 strict concurrency mode, the CGEventTap closure in `RemoteInbox.swift` triggers a `SendingRisksDataRace` error (on some toolchains this is promoted from a warning to an error). Locally, Swift 6.2.3 only produces a warning, but that's not guaranteed on every user's toolchain.

**Fix**: Wrapped the state captured by the closure in an `HTTPRequestState` reference type, and used `MainActor.assumeIsolated` to synchronously declare main-actor isolation. **No asynchronous dispatch is introduced** — behavior is fully equivalent to the original. All 471 Swift 6 warnings across the project have been cleared.

### 🔴 Install-path permission recognition

Carried over from the DMG already replaced in v0.2.0: the bundle includes a `PkgInfo` file, and INSTALL.txt walks users through running `lsregister -f` to ensure macOS LaunchServices registers the bundle id (otherwise TCC can't find the app, and the permission dialog never appears).

## Internal engineering improvements (not user-visible)

- Client-side `WEDataDir` upgraded to a full directory-tree manager (subdirectory / filename constants / derived-path helpers); all path access now goes through it uniformly
- Server-side directory tree reorganized: `server/lib/` (8 sub-step scripts) + `server/entry/` (3 main user entry points) + `server/INDEX.md` (the single authoritative entry-point index) + `server/scripts/` (deprecated old scripts, still usable)
- Server-side `lib/paths.py` centralizes path constants, with support for overriding via the `WE_DATA_DIR` environment variable (for sandboxed testing)
- Automatic misrecognition-dictionary builder `build_dictionary.py`: extracts polish-diff tokens plus low-confidence English/mixed tokens from `voice-history.jsonl` — in testing, scanning 1,264 entries automatically discovered 38 new terms
- Bidirectional dictionary markdown review tool `review_dictionary.py`
- AutoResearch experiment environment `server/finetune-research/run_experiment.sh`
- One-click automatic fine-tuning pipeline `server/entry/finetune.sh` (dictionary → AI distillation → grid search → select best → auto-deploy)
- KPI automated test framework `client/scripts/kpi-test/` (6 milestone binaries + 5 continuous baseline metrics + a 250-item test set + monthly report archiving)
- `WE --bench-voice <wav>` CLI entry point (end-to-end evaluation of the live recording pipeline)

## Installation

```bash
# Download WE-0.2.1.dmg, drag WE.app into /Applications, then run:
xattr -cr /Applications/WE.app
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/WE.app
```

After launch, the system will request 4 permissions in turn:

- **Input Monitoring** ← the permission actually required for global hotkeys
- **Accessibility** ← used for injecting text at the cursor
- Microphone
- Screen Recording (only needed when Meeting Mode records system audio)

> ⚠️ Input Monitoring vs. Accessibility: many people confuse these. What CGEventTap actually needs in order to listen for Right Option is "Input Monitoring"; Accessibility is only used to inject text at the cursor. Both must be granted.

## Upgrade instructions

Upgrading from v0.2.0: simply overwrite `/Applications/WE.app`, run `xattr -cr` + `lsregister -f` once, then grant the "Input Monitoring" permission after launch.

## Known issues

- The default `server.model: qwen3:0.6b` is a base model with limited quality (reported in issue #14). For the full experience, use `server/entry/finetune.sh` to fine-tune your own `we-polish` model on a GPU and swap it in. See `server/INDEX.md` for details.
- The two Meeting Mode baselines (key-fact retention rate / meeting WER) are waiting on the meeting test set to be ready.
