## Better Voice 1.0.1

A polish release focused on making first-run permissions "just work."

### Fixes

- **Reliable first-run permissions.** Granting **Global hotkey monitoring** (Input Monitoring) during onboarding now shows the real system prompt and lands the app in the list — no more empty "No Items" pane or having to add the app by hand.
- **No restart needed.** The dictation hotkey activates the moment you grant Input Monitoring — Better Voice re-arms itself instead of making you quit and reopen.
- **Cleaner hotkey handling.** The dictation hotkey no longer leaks its shortcut character (e.g. `≥` from ⌥.) into the focused field, and fires on release so the paste can't be corrupted by a still-held modifier. Applies to any combo you set.

### Requirements

macOS 26+, Apple silicon. Apple Intelligence recommended for the zero-setup default.

### Install

Existing users update in place (menu bar → **Check for Updates…**). New users: download the `.dmg` from [voice.baselinemakes.com](https://voice.baselinemakes.com), drag **BetterVoice2.app** to `/Applications`, then launch.
