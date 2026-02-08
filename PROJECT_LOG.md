# WisprClaw Project Log

## Project Overview

WisprClaw is a macOS menu bar voice assistant that captures audio input, transcribes it locally using OpenAI's Whisper model, and sends the transcript to an OpenClaw AI agent for processing. The response is displayed in a floating popup panel and the menu bar. The goal: a hands-free, privacy-respecting voice-to-AI pipeline that runs entirely on local hardware (except the agent call).

### Architecture

```
[macOS Menu Bar App (Swift)] → [Whisper Gateway (Python/FastAPI)] → [OpenClaw Agent (WebSocket)]
         ↑                              ↑                                    ↑
   Audio capture              Local transcription                  Remote AI processing
   UI / hotkey                Optional LLMLingua                   Device-authenticated
   Response display           compression
```

Three decoupled layers:
1. **Swift app** — native macOS menu bar client, audio recording, UI, hotkey
2. **Python gateway** — local Whisper STT server with optional LLMLingua compression
3. **OpenClaw gateway** — remote WebSocket service for AI agent requests

---

## Goals

1. **Hands-free voice interaction** — Double-tap Command to start/stop recording, no windows to manage.
2. **Local-first transcription** — Audio never leaves the machine; Whisper runs locally via Python gateway.
3. **Low-latency agent calls** — Minimize overhead in the OpenClaw WebSocket protocol.
4. **Clean native UI** — Frosted glass popup, menu bar state indicators, system-native settings.
5. **Zero external Swift dependencies** — Pure AppKit/SwiftUI, CryptoKit for device identity.

---

## Progress & Feature Timeline

### Phase 1: Foundation
**Commits:** `0880a2b` (first commit), `0fca0d5` (basic voice implementation)

- Set up Swift Package Manager project targeting macOS 13+
- Implemented `AudioRecorder` using AVAudioEngine to capture microphone input as 16-bit PCM WAV
- Created the `AppDelegate` → `StatusItemManager` lifecycle
- Menu bar icon with basic start/stop recording controls

### Phase 2: Transcription Pipeline
**Commit:** `eb61a8e` (basic functionality)

- Built `whisper_gateway.py` — FastAPI server hosting Whisper model
- Implemented `TranscriptionClient` — multipart form upload of audio to gateway
- Added `EnvLoader` for .env file configuration (searches project root, executable dir, gateway/, ~/.wisprclaw/)
- End-to-end flow working: record → upload → transcribe → display transcript

### Phase 3: OpenClaw Integration
**Commit:** `eb61a8e` continued

- Implemented OpenClaw WebSocket Gateway Protocol v3 in `OpenClawClient`
- Built `DeviceIdentity` — Curve25519 keypair generation, payload signing, persisted to `~/.openclaw/wisprclaw-device.json`
- Implemented `MessageBridge` actor — routes WebSocket messages to awaiting Swift continuations
- Challenge/connect handshake with nonce-based authentication
- Agent request/response cycle with "accepted" → "ok"/"error" two-phase protocol

### Phase 4: UI Polish
**Commit:** `50bcb80` (basically done)

- `ResponsePopupPanel` — floating HUD-style NSPanel with frosted glass effect
- Auto-dismiss after 30 seconds, pauses on mouse hover
- `SettingsView` — two-tab SwiftUI settings (General + AI Agent) with @AppStorage persistence
- `GlobalHotkeyManager` — double-tap Command detection via NSEvent monitor
- State machine in StatusItemManager: idle → listening → transcribing → thinking
- Menu shows last transcript and response with tooltips, clipboard copy support

### Phase 5: LLMLingua Transcript Compression & Cleanup
**Commit:** `0d413af` (cleanup)

- Code organization and cleanup pass
- Integrated LLMLingua into the Whisper gateway for input token compression
- LLMLingua compresses transcripts before they reach the AI agent, reducing token count by ~40% (configurable rate)
- Uses `microsoft/llmlingua-2-xlm-roberta-large-meetingbank` model by default with LLMLingua-2 API
- Auto-detects compute device: MPS on Apple Silicon, CUDA on NVIDIA, CPU fallback
- Configurable via environment variables: `LLMLINGUA_ENABLED`, `LLMLINGUA_MODEL`, `LLMLINGUA_RATE`, `LLMLINGUA_DEVICE`, `LLMLINGUA_USE_V2`
- Gateway logs both original and compressed transcripts with timestamps for comparison
- Handles multiple LLMLingua output formats via `extract_compressed_text()` normalizer
- Falls back to original text gracefully if compression fails or returns unexpected format

### Phase 6: Persistent WebSocket Connection
**Current work**

- Refactored `OpenClawClient` from per-request WebSocket lifecycle to persistent connection
- Added `ensureConnected()` with fast-path for existing connections
- Automatic reconnection on failure with retry-once semantics
- Re-reads URL/token from UserDefaults on each reconnect (Settings changes take effect without restart)
- `MessageBridge.reset()` for clean state on reconnect
- Eliminates ~300-500ms handshake overhead on subsequent requests

### Phase 7: Markdown Stripping in Popup
**Current work**

- Agent responses often contain markdown formatting (headers, bold, links, code blocks)
- Added markdown stripping before display in the popup panel
- Clean plain text display in the frosted glass popup

### Phase 8: LLMLingua Settings Toggle
**Current work**

- Added per-request `compress` query parameter to gateway's `/transcribe` endpoint, overriding the server-wide `LLMLINGUA_ENABLED` default
- Added "Compress with LLMLingua" toggle to the General tab in Settings
- TranscriptionClient reads the toggle from UserDefaults and passes `?compress=1` or `?compress=0` on each request
- Allows users to enable/disable compression on the fly without restarting the gateway

---

## Challenges & Solutions

### 1. WebSocket Message Ordering Race Condition
**Problem:** The OpenClaw server sends a `connect.challenge` event immediately on WebSocket connection. If the challenge arrived before `waitForChallenge()` was called, the continuation was never set and the nonce was dropped — causing a deadlock.

**Solution:** Added buffering to `MessageBridge`. If a challenge arrives before anyone is waiting, it's stored in `bufferedNonce`/`challengeBuffered`. When `waitForChallenge()` is called, it checks the buffer first and returns immediately if the challenge was already received.

### 2. Settings Window Not Opening
**Problem:** Clicking "Settings..." in the menu bar did nothing in a menu-bar-only (accessory) app.

**Root cause:** Calling `NSApp.setActivationPolicy(.regular)` and immediately `window.makeKeyAndOrderFront(nil)` in the same run loop iteration fails because macOS hasn't processed the policy change yet. Additionally, the SwiftUI `Settings` scene was competing with the manual NSWindow approach.

**Solution:** Changed SwiftUI Settings scene to wrap `EmptyView()`, and dispatched window presentation asynchronously via `DispatchQueue.main.async` after setting the activation policy, giving the run loop a tick to process the change. Used `orderFrontRegardless()` for reliability.

### 3. Per-Request WebSocket Overhead
**Problem:** Every agent call opened a new TCP connection, performed a full challenge/connect handshake, sent the request, then tore everything down. This added 300-500ms per request.

**Solution:** Persistent WebSocket connection that stays open across `send()` calls. `ensureConnected()` provides a fast path when already connected, and automatically reconnects on failure. Connection errors trigger a single retry after reconnect. Config is re-read from UserDefaults on each reconnect so Settings changes take effect naturally.

### 4. Swift Concurrency & Actor Isolation
**Problem:** Bridging URLSessionWebSocketTask's callback-based API with Swift's async/await required careful continuation management. Multiple in-flight requests needed routing to the correct awaiter.

**Solution:** `MessageBridge` as a Swift actor with a dictionary of `CheckedContinuation` keyed by request ID. The receive loop runs in a background Task, parses JSON, and delivers to the actor. The actor routes responses by ID and handles the two-phase agent protocol (ignoring "accepted", resolving on "ok"/"error").

### 5. Device Identity & Signing
**Challenge:** OpenClaw requires Curve25519 device signatures for authentication. The signing payload format differs based on whether a nonce is present (v1 vs v2).

**Approach:** `DeviceIdentity` generates a keypair on first run, persists it to disk, and signs payloads using CryptoKit. Base64-URL encoding (no padding) used for WebSocket transmission. The device ID is derived from SHA256 of the public key.

### 6. LLMLingua Integration & Output Normalization
**Challenge:** LLMLingua's API returns different result formats depending on the version and method called (`compress_prompt` vs `compress_prompt_llmlingua2`). The result can be a raw string, or a dict with keys like `compressed_prompt`, `compressed_text`, `prompt`, or `text`.

**Solution:** `extract_compressed_text()` tries multiple known keys in priority order and falls back to the original text if nothing matches. The gateway also tries `compress_prompt_llmlingua2` first when LLMLingua v2 is enabled (checking via `hasattr`), with a `TypeError` fallback to the v1 method.

### 7. Dynamic LLMLingua Toggle from macOS Settings
**Challenge:** The gateway reads `LLMLINGUA_ENABLED` from environment at startup — a server-side constant. But the user needs to toggle compression from the Swift Settings UI without restarting the gateway.

**Solution:** Added an optional `compress` query parameter to the `/transcribe` endpoint that overrides the server default per-request. The Swift client reads the toggle from UserDefaults and appends `?compress=1` or `?compress=0` to every transcription request. This keeps the gateway stateless (no mutable config) while giving the client full control.

---

## Key Technical Decisions

| Decision | Rationale |
|----------|-----------|
| **No external Swift deps** | Minimizes build complexity; AppKit/SwiftUI/CryptoKit provide everything needed |
| **Python gateway for Whisper** | Whisper's Python ecosystem is mature; running it as a local HTTP service decouples it cleanly from the Swift app |
| **Actor for MessageBridge** | Swift actors provide safe concurrent access to the continuation dictionary without manual locking |
| **Persistent WebSocket** | Amortizes handshake cost across requests; natural fit since the app is long-lived |
| **UserDefaults for config** | Integrates with SwiftUI @AppStorage; .env fallback via EnvLoader for dev workflows |
| **NSPanel for popup** | Floating panel that doesn't steal focus, works across spaces, supports frosted glass via NSVisualEffectView |
| **Double-tap Command hotkey** | Ergonomic for voice input; uses NSEvent global monitor (requires accessibility permissions) |
| **LLMLingua for compression** | Voice transcripts are often verbose; compressing before agent call reduces token cost and latency with minimal quality loss |
| **Per-request compress param** | Client controls compression toggle via query param rather than server restart; keeps gateway stateless |

---

## Learnings

1. **Race conditions in async protocols are subtle.** The challenge buffering bug was a classic case of assuming a certain ordering that isn't guaranteed. Always design message bridges to handle out-of-order delivery.

2. **macOS menu bar apps have activation quirks.** Setting activation policy to `.regular` doesn't take effect immediately — you need to yield to the run loop before presenting windows. `orderFrontRegardless()` is more reliable than `makeKeyAndOrderFront()` for accessory apps.

3. **Persistent connections need clear lifecycle management.** The `ensureConnected()` / `disconnect()` pattern with `isConnected` flag and WebSocket state checking provides a clean abstraction. Re-reading config on reconnect is a simple way to pick up Settings changes.

4. **Swift's `[weak self]` in Task closures changes the return type.** `Task { [weak self] in await self?.foo() }` produces `Task<()?, Never>` instead of `Task<Void, Never>`. Drop the `[weak self]` when the Task is stored and canceled in `deinit`/`disconnect()`.

5. **Two-phase response protocols need explicit handling.** OpenClaw's agent sends "accepted" then "ok"/"error". The bridge must know to ignore "accepted" and only resolve on the final response — otherwise the caller gets a partial result.

6. **Local-first architecture pays off.** By running Whisper locally, there's no cloud dependency for transcription, no audio data leaving the machine, and no API costs. The only network call is to the OpenClaw agent.

---

## File Reference

| File | Lines | Purpose |
|------|-------|---------|
| `App/WisprClawApp.swift` | 13 | SwiftUI app entry point |
| `App/AppDelegate.swift` | 9 | Creates StatusItemManager on launch |
| `Services/StatusItemManager.swift` | ~210 | Core orchestrator: menu bar, state machine, recording flow |
| `Services/AudioRecorder.swift` | 80 | AVAudioEngine microphone capture to WAV |
| `Services/TranscriptionClient.swift` | 58 | HTTP multipart upload to Whisper gateway |
| `Services/OpenClawClient.swift` | ~325 | Persistent WebSocket client with device auth |
| `Services/GlobalHotkeyManager.swift` | 172 | Double-tap Command hotkey detection |
| `Services/EnvLoader.swift` | 65 | .env file parser with multi-path search |
| `Services/DeviceIdentity.swift` | 56 | Curve25519 keypair, signing, persistence |
| `Views/SettingsView.swift` | 77 | Two-tab settings panel |
| `Views/ResponsePopupPanel.swift` | ~240 | Floating HUD popup with auto-dismiss |
| `gateway/whisper_gateway.py` | 293 | FastAPI Whisper STT server |
