import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/playback_service.dart';
import '../player/player_state.dart';

/// Channel implemented by `macos/Runner/NowPlayingBridge.swift`.
const macNowPlayingChannelName = 'lastwave/now_playing';

/// Values of the `state` field of the `update` payload.
const macNpStateStopped = 'stopped';
const macNpStatePlaying = 'playing';
const macNpStatePaused = 'paused';

/// Positions that moved further than playback time explains count as a
/// seek (same threshold as the SMTC / MPRIS services).
const macNpSeekThreshold = Duration(seconds: 3);

/// Identical commands arriving closer together than this are treated as
/// one physical action (e.g. a media key reported by two paths).
const macNpDedupeWindow = Duration(milliseconds: 150);

/// Maps a snapshot to the macOS playback state.
///
/// `stopped` only when there is no track. Buffering is still `playing`
/// (the user's intent) but the payload carries `rate: 0` so the system
/// timeline freezes instead of running ahead of the audio.
String macNowPlayingStateFor(PlayerSnapshot snap) {
  if (snap.current == null) return macNpStateStopped;
  return snap.isPlaying ? macNpStatePlaying : macNpStatePaused;
}

/// Full `update` payload for [snap].
///
/// - Duration is `0` while unknown; the native side then omits it.
/// - Position is clamped into `[0, duration]` when duration is known.
/// - `canNext` is supplied by the caller from the queue logic (shuffle /
///   repeat aware) so the system never shows an enabled button that
///   would silently do nothing. `canPrev` is true with any track:
///   `PlaybackService.previous()` restarts the track when there is no
///   earlier item.
/// - `canSeek` requires a resolved stream, a known duration and no
///   buffering, because `seek` before the stream is open is a no-op.
Map<String, Object> macNowPlayingPayload(
  PlayerSnapshot snap, {
  required bool canNext,
}) {
  final track = snap.current;
  final hasTrack = track != null;
  final durationMs = hasTrack ? snap.duration.inMilliseconds : 0;
  var positionMs = hasTrack ? snap.position.inMilliseconds : 0;
  if (positionMs < 0) positionMs = 0;
  if (durationMs > 0 && positionMs > durationMs) positionMs = durationMs;
  final playing = hasTrack && snap.isPlaying;
  return {
    'hasTrack': hasTrack,
    'title': track?.title ?? '',
    'artist': track?.artist ?? '',
    'album': track?.album ?? '',
    'artworkUrl': track?.artworkUrl ?? '',
    'state': macNowPlayingStateFor(snap),
    'positionMs': positionMs,
    'durationMs': durationMs < 0 ? 0 : durationMs,
    'rate': (playing && !snap.isBuffering) ? snap.speed : 0.0,
    'canNext': hasTrack && canNext,
    'canPrev': hasTrack,
    'canSeek': hasTrack &&
        snap.stream != null &&
        durationMs > 0 &&
        !snap.isBuffering,
  };
}

/// Returns the payload to push for [next], or null when nothing worth
/// pushing changed.
///
/// The system extrapolates elapsed time from `rate`, so position alone
/// never triggers a push — only track/state/flag changes, an explicit
/// [force] (seek requested by the system) or a position jump larger than
/// [macNpSeekThreshold] on the same track.
Map<String, Object>? macNowPlayingUpdateFor(
  PlayerSnapshot? prev,
  PlayerSnapshot next, {
  required bool canNext,
  bool prevCanNext = false,
  bool force = false,
}) {
  final payload = macNowPlayingPayload(next, canNext: canNext);
  if (prev == null || force) return payload;

  final before = macNowPlayingPayload(prev, canNext: prevCanNext);
  bool differs = false;
  for (final key in payload.keys) {
    if (key == 'positionMs') continue;
    if (payload[key] != before[key]) {
      differs = true;
      break;
    }
  }
  // Same track, same play state: only a jump larger than the snapshot
  // cadence explains is a seek. A track change is already `differs` via
  // artwork/title, but ids can collide on identical metadata, so compare
  // media ids too.
  if (!differs && prev.current?.mediaId != next.current?.mediaId) {
    differs = true;
  }
  if (!differs) {
    final delta = (next.position - prev.position).abs();
    differs = delta > macNpSeekThreshold && prev.isPlaying == next.isPlaying;
  }
  return differs ? payload : null;
}

/// What the router needs from the player. Implemented over
/// [PlaybackService]; faked in tests.
abstract class NowPlayingTransport {
  bool get hasTrack;
  bool get isPlaying;
  Future<void> play();
  Future<void> pause();
  Future<void> toggle();
  Future<void> next();
  Future<void> previous();
  Future<void> seek(Duration position);
}

enum NowPlayingCommandResult {
  executed,

  /// Identical command inside [macNpDedupeWindow] — dropped.
  duplicate,

  /// Nothing to do (no track, already in the requested state).
  ignored,

  /// Command name not supported by LastWave.
  unsupported,
  failed,
}

/// Routes system transport commands to the player.
///
/// Single owner of command handling on macOS: serialized (a command never
/// interleaves with the previous one), de-duplicated, and idempotent for
/// `play` / `pause`.
class NowPlayingCommandRouter {
  NowPlayingCommandRouter(
    this._transport, {
    DateTime Function()? clock,
    this.onSeekCommand,
  }) : _clock = clock ?? DateTime.now;

  final NowPlayingTransport _transport;
  final DateTime Function() _clock;

  /// Called after a system-initiated seek so the service can force-push
  /// the new position (small seeks are below [macNpSeekThreshold]).
  final void Function()? onSeekCommand;

  Future<void> _tail = Future<void>.value();
  String? _lastKey;
  DateTime? _lastAt;

  Future<NowPlayingCommandResult> handle(String name, {int? positionMs}) {
    // Duplicate detection happens at arrival time, before queueing.
    final key = name == 'seek' ? 'seek:${positionMs ?? -1}' : name;
    final now = _clock();
    final lastAt = _lastAt;
    if (_lastKey == key &&
        lastAt != null &&
        now.difference(lastAt) < macNpDedupeWindow) {
      return Future.value(NowPlayingCommandResult.duplicate);
    }
    _lastKey = key;
    _lastAt = now;

    final completer = Completer<NowPlayingCommandResult>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await _run(name, positionMs));
      } catch (_) {
        completer.complete(NowPlayingCommandResult.failed);
      }
    });
    return completer.future;
  }

  Future<NowPlayingCommandResult> _run(String name, int? positionMs) async {
    final t = _transport;
    switch (name) {
      case 'play':
        if (!t.hasTrack || t.isPlaying) return NowPlayingCommandResult.ignored;
        await t.play();
      case 'pause':
        if (!t.hasTrack || !t.isPlaying) {
          return NowPlayingCommandResult.ignored;
        }
        await t.pause();
      case 'toggle':
        if (!t.hasTrack) return NowPlayingCommandResult.ignored;
        await t.toggle();
      case 'next':
        if (!t.hasTrack) return NowPlayingCommandResult.ignored;
        await t.next();
      case 'previous':
        if (!t.hasTrack) return NowPlayingCommandResult.ignored;
        await t.previous();
      case 'seek':
        if (!t.hasTrack || positionMs == null || positionMs < 0) {
          return NowPlayingCommandResult.ignored;
        }
        await t.seek(Duration(milliseconds: positionMs));
        onSeekCommand?.call();
      default:
        return NowPlayingCommandResult.unsupported;
    }
    return NowPlayingCommandResult.executed;
  }
}

class _PlaybackTransport implements NowPlayingTransport {
  _PlaybackTransport(this._ref);
  final Ref _ref;

  PlaybackService get _p => _ref.read(playbackServiceProvider.notifier);
  PlayerSnapshot get _s => _ref.read(playbackServiceProvider);

  @override
  bool get hasTrack => _s.current != null;
  @override
  bool get isPlaying => _s.isPlaying;
  @override
  Future<void> play() => _p.playResume();
  @override
  Future<void> pause() => _p.pause();
  @override
  Future<void> toggle() => _p.toggle();
  @override
  Future<void> next() => _p.next();
  @override
  Future<void> previous() => _p.previous();
  @override
  Future<void> seek(Duration position) => _p.seek(position);
}

/// macOS Now Playing / remote-command endpoint — the counterpart of
/// `SmtcService` (Windows) and `MprisService` (Linux).
///
/// One-way state flow: [PlayerSnapshot] (authoritative) → `update` →
/// native `MPNowPlayingInfoCenter`. The native side never changes state
/// by itself; system commands come back as `command` calls, run through
/// [NowPlayingCommandRouter], mutate the player, and the resulting
/// snapshot change is what updates the system UI. No optimistic native
/// state, so there is no feedback loop.
///
/// macOS only; every failure degrades to silence.
class MacNowPlayingService {
  MacNowPlayingService({
    required NowPlayingTransport transport,
    required PlayerSnapshot Function() readSnapshot,
    required bool Function() readCanSkipNext,
    MethodChannel? channel,
    bool? supported,
    DateTime Function()? clock,
    void Function(String message)? log,
  })  : _readSnapshot = readSnapshot,
        _readCanSkipNext = readCanSkipNext,
        _channel = channel ?? const MethodChannel(macNowPlayingChannelName),
        _supported = supported ?? Platform.isMacOS,
        _log = log ?? ((m) => debugPrint('[now-playing] $m')) {
    router = NowPlayingCommandRouter(
      transport,
      clock: clock,
      onSeekCommand: () => _forcePush = true,
    );
  }

  final PlayerSnapshot Function() _readSnapshot;
  final bool Function() _readCanSkipNext;
  final MethodChannel _channel;
  final bool _supported;
  final void Function(String) _log;
  late final NowPlayingCommandRouter router;

  PlayerSnapshot? _last;
  bool _lastCanNext = false;
  bool _forcePush = false;
  bool _handlerSet = false;
  bool _disposed = false;
  bool _failing = false;

  @visibleForTesting
  bool get isFailing => _failing;

  Future<void> startup() async {
    if (!_supported || _disposed) return;
    if (!_handlerSet) {
      _handlerSet = true;
      _channel.setMethodCallHandler(_onNativeCall);
    }
    _last = null;
    // Flush anything a previous engine/session left in the system UI
    // (hot restart, crash recovery) before publishing fresh state.
    await _invoke('clear');
    onSnapshot(_readSnapshot());
  }

  void onSnapshot(PlayerSnapshot snap) {
    if (!_supported || _disposed) return;
    final canNext = snap.current != null && _readCanSkipNext();
    final update = macNowPlayingUpdateFor(
      _last,
      snap,
      canNext: canNext,
      prevCanNext: _lastCanNext,
      force: _forcePush,
    );
    _last = snap;
    _lastCanNext = canNext;
    if (update == null) return;
    _forcePush = false;
    unawaited(_invoke('update', update));
  }

  Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
      _failing = false;
    } catch (e) {
      // Bridge missing / engine tearing down / native error. Forget what
      // we last sent so the next snapshot change republishes everything.
      _last = null;
      if (!_failing) _log('$method failed: $e');
      _failing = true;
    }
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method != 'command' || _disposed) return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final name = args['name'];
    if (name is! String) return null;
    final pos = args['positionMs'];
    final result = await router.handle(
      name,
      positionMs: pos is num ? pos.toInt() : null,
    );
    if (result == NowPlayingCommandResult.failed) {
      _log('command $name failed');
    }
    return null;
  }

  /// Clears the system Now Playing entry and removes native handlers.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _last = null;
    if (_supported) {
      unawaited(_channel.invokeMethod<void>('clear').catchError((_) {}));
      if (_handlerSet) _channel.setMethodCallHandler(null);
    }
  }
}

final macNowPlayingProvider = Provider<MacNowPlayingService>((ref) {
  final svc = MacNowPlayingService(
    transport: _PlaybackTransport(ref),
    readSnapshot: () => ref.read(playbackServiceProvider),
    readCanSkipNext: () =>
        ref.read(playbackServiceProvider.notifier).canSkipNext,
  );
  ref.listen<PlayerSnapshot>(
      playbackServiceProvider, (prev, next) => svc.onSnapshot(next));
  ref.onDispose(svc.dispose);
  return svc;
});
