import Cocoa
import FlutterMacOS
import MediaPlayer

// Native half of lib/features/nowplaying/macos_now_playing_service.dart.
//
// Dart's PlayerSnapshot is the single source of truth. This bridge only
//   1. mirrors the latest `update` payload into MPNowPlayingInfoCenter, and
//   2. forwards system transport commands (media keys, Control Center,
//      AirPods/Bluetooth) to Dart as `command` calls.
// It never changes playback state on its own, so there is no feedback loop
// and no second owner of play/pause. Only public MediaPlayer APIs are used.
//
// Channel `lastwave/now_playing`:
//   Dart -> native: update(payload map) | clear()
//   native -> Dart: command({name: play|pause|toggle|next|previous|seek,
//                            positionMs: Int?})

enum NowPlayingState: String {
  case stopped
  case playing
  case paused
}

/// Parsed `update` payload. Pure value type so it can be unit-tested
/// without touching the system Now Playing center.
struct NowPlayingPayload: Equatable {
  var hasTrack: Bool
  var title: String
  var artist: String
  var album: String
  var artworkUrl: String
  var state: NowPlayingState
  var positionMs: Int64
  var durationMs: Int64
  var rate: Double
  var canNext: Bool
  var canPrev: Bool
  var canSeek: Bool

  /// Returns nil for anything that is not a well-formed payload.
  init?(arguments: Any?) {
    guard let m = arguments as? [String: Any],
      let hasTrack = m["hasTrack"] as? Bool
    else { return nil }
    self.hasTrack = hasTrack
    title = m["title"] as? String ?? ""
    artist = m["artist"] as? String ?? ""
    album = m["album"] as? String ?? ""
    artworkUrl = m["artworkUrl"] as? String ?? ""
    state = NowPlayingState(rawValue: m["state"] as? String ?? "") ?? .stopped
    positionMs = (m["positionMs"] as? NSNumber)?.int64Value ?? 0
    durationMs = (m["durationMs"] as? NSNumber)?.int64Value ?? 0
    rate = (m["rate"] as? NSNumber)?.doubleValue ?? 0
    canNext = m["canNext"] as? Bool ?? false
    canPrev = m["canPrev"] as? Bool ?? false
    canSeek = m["canSeek"] as? Bool ?? false
  }

  /// The `nowPlayingInfo` dictionary for this payload. Empty (= nothing
  /// to show) when there is no track. Empty strings and unknown duration
  /// are omitted rather than published as blanks/zeros.
  func infoDictionary(artwork: MPMediaItemArtwork?) -> [String: Any] {
    guard hasTrack else { return [:] }
    var info: [String: Any] = [
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
      MPNowPlayingInfoPropertyPlaybackRate: max(0, rate),
    ]
    if !title.isEmpty { info[MPMediaItemPropertyTitle] = title }
    if !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
    if !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
    var elapsed = Double(max(0, positionMs)) / 1000.0
    if durationMs > 0 {
      let duration = Double(durationMs) / 1000.0
      info[MPMediaItemPropertyPlaybackDuration] = duration
      elapsed = min(elapsed, duration)
    }
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
    if let artwork = artwork { info[MPMediaItemPropertyArtwork] = artwork }
    return info
  }
}

final class NowPlayingBridge {
  static let shared = NowPlayingBridge()
  static let channelName = "lastwave/now_playing"
  private static let maxArtworkBytes = 10 * 1024 * 1024

  private var channel: FlutterMethodChannel?
  private var payload: NowPlayingPayload?
  private var registered: [(MPRemoteCommand, Any)] = []
  private var active = false

  private var artwork: MPMediaItemArtwork?
  private var artworkURL = ""
  private var artworkGeneration = 0
  private var artworkTask: URLSessionDataTask?
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 15
    return URLSession(configuration: config)
  }()

  // Remote-command handlers may run off the main thread, so the only state
  // they read is guarded by this lock.
  private let lock = NSLock()
  private var accepting = false

  private init() {}

  // MARK: Lifecycle

  func attach(messenger: FlutterBinaryMessenger) {
    channel?.setMethodCallHandler(nil)
    let channel = FlutterMethodChannel(
      name: NowPlayingBridge.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handle(call, result: result)
    }
    self.channel = channel
    NotificationCenter.default.removeObserver(
      self, name: NSApplication.willTerminateNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(appWillTerminate),
      name: NSApplication.willTerminateNotification, object: nil)
  }

  @objc private func appWillTerminate() { shutdown() }

  /// Clears the system entry, removes every handler we registered and
  /// detaches from the engine. Safe to call repeatedly.
  func shutdown() {
    deactivate()
    channel?.setMethodCallHandler(nil)
    channel = nil
  }

  // MARK: Dart -> native

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      guard let payload = NowPlayingPayload(arguments: call.arguments) else {
        result(FlutterError(code: "bad_args", message: "Malformed now-playing payload", details: nil))
        return
      }
      apply(payload)
      result(nil)
    case "clear":
      deactivate()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func apply(_ p: NowPlayingPayload) {
    guard p.hasTrack else {
      deactivate()
      return
    }
    activateIfNeeded()
    payload = p
    updateCommandAvailability(p)
    if p.artworkUrl != artworkURL {
      // New track/artwork: drop the old image right away so the system UI
      // never shows the previous track's cover next to the new title.
      artworkTask?.cancel()
      artworkTask = nil
      artwork = nil
      artworkURL = p.artworkUrl
      artworkGeneration += 1
      if !p.artworkUrl.isEmpty { fetchArtwork(p.artworkUrl, generation: artworkGeneration) }
    }
    publish()
  }

  private func publish() {
    guard let p = payload, p.hasTrack else { return }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = p.infoDictionary(artwork: artwork)
    // Required on macOS: there is no AVAudioSession to infer it from.
    switch p.state {
    case .playing: center.playbackState = .playing
    case .paused: center.playbackState = .paused
    case .stopped: center.playbackState = .stopped
    }
  }

  // MARK: Artwork

  private func fetchArtwork(_ urlString: String, generation: Int) {
    guard let url = URL(string: urlString) else { return }
    let finish: (Data?) -> Void = { [weak self] data in
      DispatchQueue.main.async {
        guard let self = self, generation == self.artworkGeneration,
          let data = data, data.count <= NowPlayingBridge.maxArtworkBytes,
          let image = NSImage(data: data), image.size.width > 0, image.size.height > 0
        else { return }
        self.artwork = NowPlayingBridge.makeArtwork(image)
        self.publish()
      }
    }
    switch url.scheme?.lowercased() {
    case "http", "https":
      let task = session.dataTask(with: url) { data, response, _ in
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          finish(nil)
        } else {
          finish(data)
        }
      }
      artworkTask = task
      task.resume()
    case "file":
      DispatchQueue.global(qos: .utility).async { finish(try? Data(contentsOf: url)) }
    default:
      break  // Unsupported scheme: no artwork, metadata still published.
    }
  }

  /// Built outside any actor-isolated context: the request handler is
  /// invoked by MediaPlayer on its own queue.
  private static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
    return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  }

  // MARK: Remote commands

  private func activateIfNeeded() {
    guard !active else { return }
    active = true
    let c = MPRemoteCommandCenter.shared()
    add(c.playCommand, "play")
    add(c.pauseCommand, "pause")
    add(c.togglePlayPauseCommand, "toggle")
    add(c.nextTrackCommand, "next")
    add(c.previousTrackCommand, "previous")
    let seekToken = c.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self = self,
        let e = event as? MPChangePlaybackPositionCommandEvent
      else { return .commandFailed }
      return self.forward("seek", positionMs: Int64((e.positionTime * 1000).rounded()))
    }
    registered.append((c.changePlaybackPositionCommand, seekToken))
    for command in unsupportedCommands(c) { command.isEnabled = false }
    lock.lock(); accepting = true; lock.unlock()
  }

  private func add(_ command: MPRemoteCommand, _ name: String) {
    let token = command.addTarget { [weak self] _ in
      self?.forward(name, positionMs: nil) ?? .commandFailed
    }
    registered.append((command, token))
  }

  /// Commands LastWave does not implement. Disabled so the system hides
  /// them instead of showing controls that do nothing.
  private func unsupportedCommands(_ c: MPRemoteCommandCenter) -> [MPRemoteCommand] {
    return [
      c.stopCommand, c.skipForwardCommand, c.skipBackwardCommand,
      c.seekForwardCommand, c.seekBackwardCommand, c.changePlaybackRateCommand,
      c.ratingCommand, c.likeCommand, c.dislikeCommand, c.bookmarkCommand,
      c.changeRepeatModeCommand, c.changeShuffleModeCommand,
    ]
  }

  private func updateCommandAvailability(_ p: NowPlayingPayload) {
    let c = MPRemoteCommandCenter.shared()
    c.playCommand.isEnabled = true
    c.pauseCommand.isEnabled = true
    c.togglePlayPauseCommand.isEnabled = true
    c.nextTrackCommand.isEnabled = p.canNext
    c.previousTrackCommand.isEnabled = p.canPrev
    c.changePlaybackPositionCommand.isEnabled = p.canSeek
  }

  /// Runs on whatever thread MediaPlayer calls us on.
  private func forward(_ name: String, positionMs: Int64?) -> MPRemoteCommandHandlerStatus {
    lock.lock()
    let ok = accepting
    lock.unlock()
    // No active item: tell the system there is nothing for us to act on.
    guard ok else { return .noActionableNowPlayingItem }
    DispatchQueue.main.async { [weak self] in
      guard let channel = self?.channel else { return }
      var args: [String: Any] = ["name": name]
      if let positionMs = positionMs { args["positionMs"] = positionMs }
      channel.invokeMethod("command", arguments: args)
    }
    return .success
  }

  /// Removes handlers, clears metadata and the playback state.
  private func deactivate() {
    lock.lock(); accepting = false; lock.unlock()
    artworkTask?.cancel()
    artworkTask = nil
    artworkGeneration += 1
    artwork = nil
    artworkURL = ""
    payload = nil
    if active {
      for (command, token) in registered { command.removeTarget(token) }
      registered.removeAll()
      let c = MPRemoteCommandCenter.shared()
      for command in [
        c.playCommand, c.pauseCommand, c.togglePlayPauseCommand,
        c.nextTrackCommand, c.previousTrackCommand, c.changePlaybackPositionCommand,
      ] { command.isEnabled = false }
      active = false
    }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
  }
}
