# macOS Now Playing / media keys

## Architecture (audited)

- Flutter desktop app (Dart ^3.13, `macos/` runner in Swift, deployment target macOS 12.0, sandboxed).
- **Playback is `media_kit` / libmpv, audio only** (`PlaybackService.ensurePlayer`, `lib/features/player/playback_service.dart`). There is no WKWebView/HTML media element playing music: YouTube Music is reached through InnerTube API calls, streams are resolved to URLs and opened in mpv.
- The only WebViews are the hidden BotGuard poToken engine (`potoken_engine.dart`, `desktop_webview_window`) and the YouTube login window. They never play audio. The WebKit `MediaSessionCoordinator` / `MediaElementSession` log lines come from those pages and are unrelated to playback; WebKit's Media Session cannot see mpv audio.
- Existing system-media integrations: SMTC (Windows, `smtc_service.dart` + `windows/runner/smtc_channel.cpp`) and MPRIS (Linux). **macOS had none**: no `MPNowPlayingInfoCenter`, no `MPRemoteCommandCenter`, nothing in `macos/Runner` except the window-appearance channel. Hence no Control Center entry and dead media keys. `wave_hotkeys.dart` deliberately ignores media keys (single-owner contract).

## Design

```
PlayerSnapshot (Dart, authoritative)
   └─ MacNowPlayingService.onSnapshot ── update ──► NowPlayingBridge.swift ──► MPNowPlayingInfoCenter
macOS media key / Control Center / AirPods
   └─ MPRemoteCommandCenter ── command ──► MacNowPlayingService ► NowPlayingCommandRouter ► PlaybackService
```

- Channel `lastwave/now_playing` (`update`, `clear` Dart→native; `command` native→Dart).
- Native never changes state itself; the player's next snapshot is what updates the system UI (no feedback loop).
- Commands are serialized, de-duplicated (150 ms window), and `play`/`pause` are idempotent.
- Supported: play, pause, toggle, next (only enabled when the queue can advance), previous, seek (`changePlaybackPosition`, only when stream + duration known). Everything else (stop, skip ±, rating, like, repeat/shuffle, …) is explicitly disabled.
- Handlers are registered only while a track exists and removed (with metadata and playback state cleared) when the queue empties, on `clear`, on Dart service dispose and on `NSApplication.willTerminate`.
- Artwork is fetched natively (http/https/file, 10 MB cap) and applied only if it still matches the current track (generation counter).

## Manual verification (requires a real Mac)

1. `flutter run -d macos`, play a track.
2. Control Center → Now Playing shows LastWave's title/artist/artwork (not "mpv" / not blank).
3. Click pause/play in Control Center; the in-app dock must follow, and vice versa.
4. Press the keyboard play/pause, next and previous keys: each acts once (watch for double toggles).
5. Scrub in Control Center; audio seeks and the scrubber stays in sync.
6. Change tracks (in-app and via next/previous): title, artwork and duration refresh with no stale cover.
7. Reach the end of a queue with repeat off: Next greys out.
8. Open Apple Music/Spotify and play there: media keys must go to that app. Quit it, play in LastWave: keys return to LastWave.
9. Test with LastWave in the background and with another window focused.
10. Quit/close LastWave: Now Playing entry disappears; hot-restart: no stale entry.
11. Check that mpv's own macOS media-key handling does not double-fire (a key press must toggle exactly once).

Run `flutter test test/macos_now_playing_test.dart` and the `RunnerTests` XCTest target (`NowPlayingBridgeTests`).
