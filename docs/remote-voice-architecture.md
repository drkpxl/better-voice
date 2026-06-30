# WE Remote Voice Architecture Plan

## 1. Problem

The Windows PC controls the Mac Mini via Remote Desktop. The screen belongs to the Mac Mini, but the microphone is on the Windows side. WE depends on Apple's SpeechAnalyzer, which only runs on macOS. We need to get the audio from Windows over to WE on the Mac Mini, with the resulting text injected directly into the focused window.

## 2. Design Principle: Modeled on Taildrop

Taildrop (file transfer) is a first-class citizen feature of Tailscale:
- `ipnext.Extension` registers with `tailscaled` and is enabled by default along with the daemon
- **PeerAPI** handles node-to-node transfer (receiving-side HTTP handler)
- **LocalAPI** handles communication from the local client to the daemon (sending side)
- **CLI** `tailscale file cp` is the thin client for sending
- The build flag `ts_omit_taildrop` can remove it

VoiceRelay fully replicates this pattern. Voice is essentially a special kind of "file transfer" — what's sent is a WAV file, and the receiving side writes it into WE's directory.

## 3. System Topology

```
Windows PC                                        Mac Mini (mac-dev)
┌────────────────────────────────┐                ┌──────────────────────────────────┐
│                                │                │                                  │
│  tailscaled (Windows Service)  │                │  tailscaled (launchd)            │
│  ┌──────────────────────────┐  │    PeerAPI     │  ┌──────────────────────────┐    │
│  │ Extension: voicerelay    │  │ ═══════════►   │  │ Extension: voicerelay    │    │
│  │                          │  │   Tailnet      │  │                          │    │
│  │ LocalAPI:                │  │   WireGuard    │  │ PeerAPI:                 │    │
│  │ POST /voice-send/{node} │  │                │  │ PUT /v0/voice/{file}     │    │
│  │  ↑ recv WAV → fwd PeerAPI│  │                │  │  → ~/.we/remote-inbox/   │    │
│  └──────────────────────────┘  │                │  └──────────────────────────┘    │
│           ↑ LocalAPI                            │             │ write file          │
│  ┌────────┴───────────────┐    │                │  ┌──────────▼─────────────────┐  │
│  │ tailscale voice        │    │                │  │ WE App                     │  │
│  │ (CLI, persistent       │    │                │  │                            │  │
│  │  user-mode process)    │    │                │  │ FSEvents watcher           │  │
│  │ • Global hotkey (RAlt) │    │                │  │ ~/.we/remote-inbox/        │  │
│  │ • Mic recording(WASAPI)│    │                │  │   ↓                        │  │
│  │ • WAV → LocalAPI POST  │    │                │  │ SpeechAnalyzer (file input)│  │
│  └────────────────────────┘    │                │  │   ↓                        │  │
│                                │                │  │ VoicePipeline (L1+L2)      │  │
│  Remote Desktop client        │                │  │   ↓                        │  │
│  (sees Mac Mini screen)       │ ◄── screen ──── │  │ TextInjector → focused win │  │
│                                │                │  │   ↓                        │  │
│                                │                │  │ VoiceHistory (local debug)  │ │
└────────────────────────────────┘                └──────────────────────────────────┘
```

## 4. Data Flow

```
1. User holds down RAlt (the tailscale voice process listens for the Win32 global hotkey)
2. Windows microphone starts recording (WASAPI, 16kHz/16bit/mono PCM)
3. User releases RAlt
4. Recording stops, WAV data is POSTed to LocalAPI:
   POST /localapi/v0/voice-send/{mac-dev-stableID}
   Body: WAV binary
5. tailscaled Extension receives it → forwards via PeerAPI:
   PUT {mac-dev-PeerAPI}/v0/voice/{timestamp}.wav
   (exactly symmetric to Taildrop's PUT /v0/put/{filename})
6. Mac Mini's tailscaled Extension receives it → writes to ~/.we/remote-inbox/{timestamp}.wav
7. WE App's FSEvents detects the new file
8. SpeechAnalyzer.start(inputAudioFile:, finishAfterFile: true)
9. VoicePipeline → L1 + L2 → TextInjector → text appears in the focused window
10. VoiceHistory persists the result (same format as local voice; local debug log)
11. Once processing is done, the WAV in remote-inbox is deleted
```

## 5. Tailscale Side: voicerelay Extension

### 5.1 File Structure

```
client/feature/voicerelay/
├── ext.go                    Extension registration + lifecycle (modeled on taildrop/ext.go)
├── peerapi.go                PeerAPI handler: PUT /v0/voice/{filename}
├── localapi.go               LocalAPI handler: POST /localapi/v0/voice-send/{stableID}
├── voicerelay.go             Core logic (receive & save file, send & forward)
└── paths.go                  Inbox directory path (~/.we/remote-inbox/)

client/feature/buildfeatures/
├── feature_voicerelay_enabled.go     const HasVoiceRelay = true
└── feature_voicerelay_disabled.go    const HasVoiceRelay = false (ts_omit_voicerelay)

client/feature/condregister/
└── maybe_voicerelay.go               //go:build !ts_omit_voicerelay
                                      import _ "tailscale.com/feature/voicerelay"

client/cmd/tailscale/cli/
└── voice.go                          tailscale voice subcommand
```

### 5.2 Extension Core (ext.go)

```go
package voicerelay

import "tailscale.com/ipn/ipnext"

func init() {
    ipnext.RegisterExtension("voicerelay", newExtension)
}

type extension struct {
    host   ipnext.Host
    inboxDir string  // ~/.we/remote-inbox/ (Mac) or empty (other platforms)
}

func newExtension(h ipnext.Host) (ipnext.Extension, error) {
    ext := &extension{host: h}
    
    // Register the PeerAPI handler (receiving side)
    h.RegisterPeerAPIHandler("/v0/voice/", ext.handlePeerVoice)
    
    // Register the LocalAPI handler (sending side)
    h.RegisterLocalAPIHandler("voice-send/", ext.serveVoiceSend)
    
    return ext, nil
}
```

### 5.3 Receiving Side: PeerAPI (peerapi.go)

```go
// The Mac Mini's tailscaled receives audio from Windows
// PUT {PeerAPI}/v0/voice/{timestamp}.wav

func (ext *extension) handlePeerVoice(w http.ResponseWriter, r *http.Request) {
    filename := path.Base(r.URL.Path)
    
    // Write to ~/.we/remote-inbox/
    dst := filepath.Join(ext.inboxDir, filename)
    f, _ := os.Create(dst + ".partial")
    io.Copy(f, r.Body)
    f.Close()
    os.Rename(dst+".partial", dst)  // Atomic rename, WE only ever sees complete files
    
    w.WriteHeader(http.StatusOK)
}
```

Same partial → rename pattern as Taildrop's `handlePeerPut`.

### 5.4 Sending Side: LocalAPI (localapi.go)

```go
// The Windows tailscale voice CLI calls the local daemon
// POST /localapi/v0/voice-send/{stableID}
// Body: WAV binary

func (ext *extension) serveVoiceSend(w http.ResponseWriter, r *http.Request) {
    stableID := extractStableID(r.URL.Path)
    
    // Look up the target node's PeerAPI URL
    targetURL := ext.host.PeerAPIURL(stableID)
    
    // Build the forwarded PeerAPI request
    filename := time.Now().Format("20060102-150405") + ".wav"
    req, _ := http.NewRequest("PUT", targetURL+"/v0/voice/"+filename, r.Body)
    
    resp, _ := ext.host.DoHTTPRequest(req)  // Send over the Tailnet
    w.WriteHeader(resp.StatusCode)
}
```

Same LocalAPI → PeerAPI forwarding pattern as Taildrop's `serveFilePut`.

### 5.5 CLI Command (voice.go)

```go
// cmd/tailscale/cli/voice.go

// tailscale voice --target mac-dev --hotkey RAlt
// 
// Runs persistently, listens for the global hotkey, and sends the
// recording via LocalAPI once captured.
// Similar to tailscale file cp, but:
//   - A persistent process (not a one-shot command)
//   - Has built-in recording capability (doesn't read a file)
//   - Triggered by a hotkey (not a command-line argument)

var voiceCmd = &cobra.Command{
    Use:   "voice",
    Short: "Voice relay to a remote node",
    Long:  "Record audio and send to a Tailscale peer for speech recognition",
}

func runVoice(ctx context.Context, args []string) error {
    target := voiceArgs.target     // mac-dev
    hotkey := voiceArgs.hotkey     // RAlt
    
    // 1. Resolve the target node
    st, _ := localClient.Status(ctx)
    peer := findPeer(st, target)
    
    // 2. Register the global hotkey (platform-specific)
    hk := registerHotkey(hotkey)
    
    // 3. Event loop
    for {
        select {
        case <-hk.Down:
            recorder.Start()
        case <-hk.Up:
            wav := recorder.Stop()
            // Send via LocalAPI
            localClient.VoiceSend(ctx, peer.ID, wav)
        case <-ctx.Done():
            return nil
        }
    }
}
```

### 5.6 Windows Auto-Start at Boot

When initialized, the Extension registers a Windows scheduled task or Run registry key (similar to how Taildrop registers a shell extension):

```go
// In ext.go
func (ext *extension) Init(h ipnext.Host) error {
    // Windows: register auto-start for "tailscale voice --target mac-dev"
    if runtime.GOOS == "windows" {
        registerAutoStart("tailscale voice --target " + ext.defaultTarget)
    }
    return nil
}
```

The user configures `tailscale voice --target mac-dev` once, and afterward it starts automatically with the system.

---

## 6. WE Side: Directory Watching

### 6.1 Design Choice

| Option | Notes |
|------|------|
| ~~WE opens an HTTP port~~ | WE would become a network server, increasing attack surface and complexity |
| **WE watches a local directory** | tailscaled writes the file, WE reads it. The two are decoupled via the filesystem |

The directory-watching approach is exactly the same as Taildrop's "relay pattern": the daemon writes files to a local directory, and the upper-level app consumes them.

### 6.2 File Structure

```
client/Sources/              (WE project)
├── RemoteInbox.swift        (new: FSEvents directory watcher + SA processing)
├── WEApp.swift              (changed: AppDelegate starts RemoteInbox)
├── StatusBarController.swift (changed: menu shows remote status)
└── ... other files untouched
```

Only one new file is added, and two files are modified. No RemoteServer, no NWListener, no HTTP needed.

### 6.3 RemoteInbox Design

```swift
// Sources/RemoteInbox.swift

/// Watches the ~/.we/remote-inbox/ directory
/// The tailscaled voicerelay Extension writes WAV files here
/// On detecting a new WAV → SpeechAnalyzer → Pipeline → TextInjector
@MainActor
final class RemoteInbox {
    private let inboxURL = WEDataDir.url.appendingPathComponent("remote-inbox")
    private var watcher: DispatchSourceFileSystemObject?
    private let pipeline = VoicePipeline()
    
    func start() {
        // Make sure the directory exists
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        
        // FSEvents watch (same approach used for watching RuntimeConfig's config.json)
        let fd = open(inboxURL.path, O_EVTONLY)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in self?.processInbox() }
        source.resume()
        watcher = source
    }
    
    private func processInbox() {
        // Scan the directory and process all .wav files (skip .partial)
        let files = try? FileManager.default.contentsOfDirectory(at: inboxURL, ...)
        for file in files where file.pathExtension == "wav" {
            Task { await processWAV(file) }
        }
    }
    
    private func processWAV(_ url: URL) async {
        // Reuse the file-input API already validated by MeetingSession
        let transcriber = SpeechTranscriber(locale: bestLocale, ...)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let inputFile = try AVAudioFile(forReading: url)
        try await analyzer.start(inputAudioFile: inputFile, finishAfterFile: true)
        
        // Collect results → Pipeline (L1 + L2 + TextInjector + VoiceHistory)
        let result = collectResults(from: transcriber)
        await pipeline.process(transcription: result, targetApp: .current())
        
        // Once processing is done, delete or move to the audio/ archive
        try? FileManager.default.moveItem(at: url, to: audioArchiveURL)
    }
}
```

### 6.4 Why RemoteServer Is No Longer Needed

| Previous approach | Current approach |
|---------|---------|
| WE opens an NWListener HTTP port | WE opens no ports at all |
| Windows connects directly to WE's :9800 | Windows → tailscaled → PeerAPI → tailscaled → file → WE |
| WE has to do its own authentication | Already authenticated by Tailscale (PeerAPI does capability checks) |
| WE becomes a network service | WE stays a purely local app |
| Bypasses Tailscale | Uses Tailscale's native transport |

**The only thing WE adds is a directory watcher.** Network transport is handled entirely by Tailscale.

---

## 7. Overall Architecture Placement

```
┌──────────────────────────────────────────────────────────────────┐
│                  Tailscale Private Network (Headscale)            │
│                                                                   │
│  ┌────────┐  ┌────────┐               ┌───────────────────────┐ │
│  │ hs-vm  │  │  v100  │               │ mac-dev               │ │
│  │Headscale│  │Qwen3.5 │               │                       │ │
│  │Portal  │  │Ollama  │               │ tailscaled            │ │
│  │NanoClaw│  │(remote │               │  ├ taildrop (file xfer)│ │
│  │        │  │ polish)│◄──────────────┤  └ voicerelay (voice)◄─┼─┼── PeerAPI
│  └────────┘  └────────┘               │       ↓ write file     │ │
│                                        │ ~/.we/remote-inbox/   │ │
│                                        │       ↓ FSEvents      │ │
│                                        │ WE App               │ │
│                                        │  ├ Local voice (hotkey)│ │
│                                        │  ├ Remote voice (inbox)│ │
│                                        │  ├ Meeting recording  │ │
│                                        │  └ Local debug logs   │ │
│                                        └───────────────────────┘ │
│                                                                   │
│  Win PC ──────────────────────────────────────────────────────── │
│  ┌─────────────────────────────────┐                             │
│  │ tailscaled (Windows Service)    │                             │
│  │  ├ taildrop (file transfer)     │ ── PeerAPI ──►              │
│  │  └ voicerelay (voice forwarding)│                             │
│  │       ↑ LocalAPI                │                             │
│  │ tailscale voice (user-mode)     │                             │
│  │  ├ Global hotkey (RAlt)         │                             │
│  │  └ WASAPI recording → WAV       │                             │
│  └─────────────────────────────────┘                             │
│                                                                   │
│  Local debug logs (consistent local/remote)                      │
│  voice-history.jsonl + audio/*.wav                               │
│   → inspect transcription/polish behavior locally                │
│  Personalization: ~/.we/personal-context.md → polish prompt      │
└──────────────────────────────────────────────────────────────────┘
```

## 8. Summary of Changes

### Tailscale Client (Go)

| File | Type | Modeled on |
|------|------|------|
| `feature/voicerelay/ext.go` | New | `feature/taildrop/ext.go` |
| `feature/voicerelay/peerapi.go` | New | `feature/taildrop/peerapi.go` |
| `feature/voicerelay/localapi.go` | New | `feature/taildrop/localapi.go` |
| `feature/voicerelay/voicerelay.go` | New | `feature/taildrop/taildrop.go` |
| `feature/voicerelay/paths.go` | New | `feature/taildrop/paths.go` |
| `feature/buildfeatures/feature_voicerelay_*.go` | New | Build flag |
| `feature/condregister/maybe_voicerelay.go` | New | Auto-registration |
| `cmd/tailscale/cli/voice.go` | New | Modeled on `cli/file.go` |
| `cmd/tailscale/cli/voice_windows.go` | New | Hotkey + WASAPI recording |

### WE (Swift)

| File | Type | Notes |
|------|------|------|
| `Sources/RemoteInbox.swift` | New | FSEvents directory watcher + SA file processing |
| `Sources/WEApp.swift` | Changed | AppDelegate starts RemoteInbox |
| `Sources/StatusBarController.swift` | Changed | Menu shows remote status |

### Unchanged

| Component | Why it's unchanged |
|------|----------|
| VoiceSession / VoicePipeline / TextInjector / VoiceHistory | Reused as-is |
| Headscale server / Portal / ACL | Network layer is already in place |
| tailscale-gui | Not part of the GUI, lives in the daemon + CLI |
| go.mod (Tailscale) | `tailscale voice`'s recording uses Windows syscalls, adding no new dependency; or at most adds portaudio |

## 9. Implementation Order

```
Phase 1: Tailscale Extension skeleton
  ├── feature/voicerelay/ copies the taildrop structure
  ├── ext.go: registration + PeerAPI handler (receive and write file)
  ├── localapi.go: LocalAPI handler (forwarding)
  ├── Build flag + condregister
  └── Verify: curl the LocalAPI → a WAV appears in the Mac Mini's ~/.we/remote-inbox/

Phase 2: WE RemoteInbox
  ├── RemoteInbox.swift: FSEvents directory watcher
  ├── Detect WAV → SA file input → Pipeline → TextInjector
  ├── AppDelegate integration
  └── Verify: manually drop a WAV into remote-inbox/ → text appears in the focused window

Phase 3: CLI tailscale voice
  ├── cli/voice.go: command framework + LocalAPI calls
  ├── voice_windows.go: Win32 RegisterHotKey + WASAPI recording
  └── Verify: full chain — press hotkey, speak → text appears on the Mac Mini's remote desktop

Phase 4: Auto-start and experience polish
  ├── Windows auto-start registration
  ├── Recording/sending/ready status feedback (sound cue or Windows Toast)
  └── WE StatusBar shows remote connection count
```

## 10. Design Principles

1. **Copy the Taildrop pattern** — Extension + PeerAPI + LocalAPI + CLI, no new pattern invented
2. **WE opens no ports** — decoupled via the filesystem, WE stays a purely local app
3. **Enabled by default** — the Extension auto-loads with tailscaled, just like Taildrop
4. **No changes to existing code** — VoiceSession/Pipeline/TextInjector/VoiceHistory are fully reused
5. **Removable at build time** — the `ts_omit_voicerelay` tag can fully strip this feature out
