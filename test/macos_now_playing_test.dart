import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/features/nowplaying/macos_now_playing_service.dart';
import 'package:lastwave_desktop/features/player/player_state.dart';

const _a = PlayableTrack(
  title: 'Song A',
  artist: 'Artist',
  album: 'Album',
  artworkUrl: 'https://example.com/a.jpg',
  videoId: 'aaa',
);
const _b = PlayableTrack(
  title: 'Song B',
  artist: 'Artist',
  artworkUrl: 'https://example.com/b.jpg',
  videoId: 'bbb',
);
const _stream = ResolvedStream(url: 'https://example.com/s');

PlayerSnapshot _snap({
  PlayableTrack? current = _a,
  bool isPlaying = true,
  bool isBuffering = false,
  Duration position = Duration.zero,
  Duration duration = const Duration(minutes: 3),
  double speed = 1.0,
  ResolvedStream? stream = _stream,
}) =>
    PlayerSnapshot(
      current: current,
      isPlaying: isPlaying,
      isBuffering: isBuffering,
      position: position,
      duration: duration,
      speed: speed,
      stream: stream,
    );

class _FakeTransport implements NowPlayingTransport {
  bool hasTrackValue = true;
  bool playing = true;
  final calls = <String>[];
  Object? failWith;

  @override
  bool get hasTrack => hasTrackValue;
  @override
  bool get isPlaying => playing;

  Future<void> _rec(String c) async {
    calls.add(c);
    if (failWith != null) throw failWith!;
  }

  @override
  Future<void> play() => _rec('play');
  @override
  Future<void> pause() => _rec('pause');
  @override
  Future<void> toggle() => _rec('toggle');
  @override
  Future<void> next() => _rec('next');
  @override
  Future<void> previous() => _rec('previous');
  @override
  Future<void> seek(Duration position) => _rec('seek:${position.inMilliseconds}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('payload mapping', () {
    test('state: stopped without track, playing/paused otherwise', () {
      expect(macNowPlayingStateFor(const PlayerSnapshot()), macNpStateStopped);
      expect(macNowPlayingStateFor(_snap()), macNpStatePlaying);
      expect(macNowPlayingStateFor(_snap(isPlaying: false)), macNpStatePaused);
    });

    test('full metadata, duration and flags', () {
      final p = macNowPlayingPayload(
          _snap(position: const Duration(seconds: 12)),
          canNext: true);
      expect(p['title'], 'Song A');
      expect(p['artist'], 'Artist');
      expect(p['album'], 'Album');
      expect(p['artworkUrl'], 'https://example.com/a.jpg');
      expect(p['positionMs'], 12000);
      expect(p['durationMs'], 180000);
      expect(p['rate'], 1.0);
      expect(p['canNext'], isTrue);
      expect(p['canPrev'], isTrue);
      expect(p['canSeek'], isTrue);
    });

    test('missing metadata is empty strings, unknown duration is 0', () {
      final p = macNowPlayingPayload(
          _snap(
              current: const PlayableTrack(title: '', artist: ''),
              duration: Duration.zero),
          canNext: false);
      expect(p['title'], '');
      expect(p['album'], '');
      expect(p['artworkUrl'], '');
      expect(p['durationMs'], 0);
      expect(p['canSeek'], isFalse);
    });

    test('paused and buffering freeze the system timeline (rate 0)', () {
      expect(macNowPlayingPayload(_snap(isPlaying: false), canNext: true)['rate'],
          0.0);
      final buffering =
          macNowPlayingPayload(_snap(isBuffering: true), canNext: true);
      expect(buffering['rate'], 0.0);
      expect(buffering['state'], macNpStatePlaying);
      expect(buffering['canSeek'], isFalse);
    });

    test('rate follows playback speed while playing', () {
      expect(macNowPlayingPayload(_snap(speed: 1.5), canNext: true)['rate'], 1.5);
    });

    test('position is clamped into [0, duration]', () {
      final over = macNowPlayingPayload(
          _snap(position: const Duration(minutes: 9)),
          canNext: true);
      expect(over['positionMs'], 180000);
      final neg = macNowPlayingPayload(
          _snap(position: const Duration(seconds: -4)),
          canNext: true);
      expect(neg['positionMs'], 0);
    });

    test('canSeek needs a resolved stream (restored session)', () {
      expect(macNowPlayingPayload(_snap(stream: null), canNext: true)['canSeek'],
          isFalse);
    });

    test('no track: everything off', () {
      final p = macNowPlayingPayload(const PlayerSnapshot(), canNext: true);
      expect(p['hasTrack'], isFalse);
      expect(p['state'], macNpStateStopped);
      expect(p['canNext'], isFalse);
      expect(p['canPrev'], isFalse);
      expect(p['canSeek'], isFalse);
    });
  });

  group('update diffing', () {
    test('first snapshot always pushes', () {
      expect(macNowPlayingUpdateFor(null, _snap(), canNext: true), isNotNull);
    });

    test('plain position ticks do not push', () {
      final before = _snap(position: const Duration(seconds: 10));
      final tick = _snap(position: const Duration(seconds: 10, milliseconds: 500));
      expect(macNowPlayingUpdateFor(before, tick, canNext: true, prevCanNext: true),
          isNull);
    });

    test('pause then resume push with the new state', () {
      final playing = _snap();
      final paused = _snap(isPlaying: false);
      final u1 = macNowPlayingUpdateFor(playing, paused,
          canNext: true, prevCanNext: true);
      expect(u1!['state'], macNpStatePaused);
      final u2 = macNowPlayingUpdateFor(paused, playing,
          canNext: true, prevCanNext: true);
      expect(u2!['state'], macNpStatePlaying);
    });

    test('track change pushes new metadata and position 0', () {
      final u = macNowPlayingUpdateFor(
          _snap(position: const Duration(seconds: 100)),
          _snap(current: _b, position: Duration.zero, isBuffering: true,
              duration: Duration.zero),
          canNext: true,
          prevCanNext: true);
      expect(u!['title'], 'Song B');
      expect(u['artworkUrl'], 'https://example.com/b.jpg');
      expect(u['positionMs'], 0);
      expect(u['durationMs'], 0);
    });

    test('rapid A->B->C each push the latest track', () {
      const c = PlayableTrack(title: 'C', artist: 'X', videoId: 'ccc');
      final s1 = _snap();
      final s2 = _snap(current: _b);
      final s3 = _snap(current: c);
      expect(macNowPlayingUpdateFor(s1, s2, canNext: true, prevCanNext: true)!['title'],
          'Song B');
      expect(macNowPlayingUpdateFor(s2, s3, canNext: true, prevCanNext: true)!['title'],
          'C');
    });

    test('same metadata, different media id still pushes', () {
      const twin = PlayableTrack(
          title: 'Song A',
          artist: 'Artist',
          album: 'Album',
          artworkUrl: 'https://example.com/a.jpg',
          videoId: 'other');
      expect(
          macNowPlayingUpdateFor(_snap(), _snap(current: twin),
              canNext: true, prevCanNext: true),
          isNotNull);
    });

    test('canNext change pushes', () {
      final s = _snap();
      expect(macNowPlayingUpdateFor(s, s, canNext: false, prevCanNext: true),
          isNotNull);
    });

    test('seek beyond threshold pushes; within it does not', () {
      final before = _snap(position: const Duration(seconds: 10));
      expect(
          macNowPlayingUpdateFor(
              before, _snap(position: const Duration(seconds: 60)),
              canNext: true, prevCanNext: true)!['positionMs'],
          60000);
      expect(
          macNowPlayingUpdateFor(
              before, _snap(position: const Duration(seconds: 12)),
              canNext: true, prevCanNext: true),
          isNull);
    });

    test('force pushes even without changes (system-initiated seek)', () {
      final s = _snap();
      expect(
          macNowPlayingUpdateFor(s, s,
              canNext: true, prevCanNext: true, force: true),
          isNotNull);
    });

    test('track end / queue cleared pushes stopped', () {
      final u = macNowPlayingUpdateFor(_snap(), const PlayerSnapshot(),
          canNext: false, prevCanNext: true);
      expect(u!['hasTrack'], isFalse);
      expect(u['state'], macNpStateStopped);
    });
  });

  group('command router', () {
    late _FakeTransport t;
    late DateTime now;
    late NowPlayingCommandRouter router;
    var seekHooks = 0;

    setUp(() {
      t = _FakeTransport();
      now = DateTime(2026, 1, 1);
      seekHooks = 0;
      router = NowPlayingCommandRouter(t,
          clock: () => now, onSeekCommand: () => seekHooks++);
    });

    test('routes each supported command exactly once', () async {
      t.playing = false;
      expect(await router.handle('play'), NowPlayingCommandResult.executed);
      now = now.add(const Duration(seconds: 1));
      t.playing = true;
      expect(await router.handle('pause'), NowPlayingCommandResult.executed);
      now = now.add(const Duration(seconds: 1));
      expect(await router.handle('toggle'), NowPlayingCommandResult.executed);
      now = now.add(const Duration(seconds: 1));
      expect(await router.handle('next'), NowPlayingCommandResult.executed);
      now = now.add(const Duration(seconds: 1));
      expect(await router.handle('previous'), NowPlayingCommandResult.executed);
      now = now.add(const Duration(seconds: 1));
      expect(await router.handle('seek', positionMs: 42000),
          NowPlayingCommandResult.executed);
      expect(t.calls,
          ['play', 'pause', 'toggle', 'next', 'previous', 'seek:42000']);
      expect(seekHooks, 1);
    });

    test('identical command inside the window is dropped', () async {
      expect(await router.handle('toggle'), NowPlayingCommandResult.executed);
      now = now.add(const Duration(milliseconds: 40));
      expect(await router.handle('toggle'), NowPlayingCommandResult.duplicate);
      expect(t.calls, ['toggle']);
    });

    test('same command after the window runs again', () async {
      await router.handle('next');
      now = now.add(macNpDedupeWindow + const Duration(milliseconds: 1));
      expect(await router.handle('next'), NowPlayingCommandResult.executed);
      expect(t.calls, ['next', 'next']);
    });

    test('different commands are never treated as duplicates', () async {
      await router.handle('next');
      now = now.add(const Duration(milliseconds: 10));
      expect(await router.handle('previous'), NowPlayingCommandResult.executed);
    });

    test('seeks to different positions are distinct', () async {
      await router.handle('seek', positionMs: 1000);
      now = now.add(const Duration(milliseconds: 10));
      expect(await router.handle('seek', positionMs: 2000),
          NowPlayingCommandResult.executed);
    });

    test('play while playing / pause while paused are no-ops', () async {
      t.playing = true;
      expect(await router.handle('play'), NowPlayingCommandResult.ignored);
      now = now.add(const Duration(seconds: 1));
      t.playing = false;
      expect(await router.handle('pause'), NowPlayingCommandResult.ignored);
      expect(t.calls, isEmpty);
    });

    test('no active session: commands are ignored, not crashed', () async {
      t.hasTrackValue = false;
      for (final c in ['play', 'pause', 'toggle', 'next', 'previous']) {
        now = now.add(const Duration(seconds: 1));
        expect(await router.handle(c), NowPlayingCommandResult.ignored);
      }
      expect(await router.handle('seek', positionMs: 5),
          NowPlayingCommandResult.ignored);
      expect(t.calls, isEmpty);
    });

    test('invalid seek positions are ignored', () async {
      expect(await router.handle('seek'), NowPlayingCommandResult.ignored);
      now = now.add(const Duration(seconds: 1));
      expect(await router.handle('seek', positionMs: -5),
          NowPlayingCommandResult.ignored);
      expect(seekHooks, 0);
    });

    test('unsupported commands report unsupported', () async {
      expect(await router.handle('stop'), NowPlayingCommandResult.unsupported);
      expect(await router.handle('skipForward'),
          NowPlayingCommandResult.unsupported);
      expect(t.calls, isEmpty);
    });

    test('player failure is contained and the router keeps working', () async {
      t.failWith = StateError('mpv gone');
      expect(await router.handle('next'), NowPlayingCommandResult.failed);
      t.failWith = null;
      now = now.add(const Duration(seconds: 1));
      expect(await router.handle('next'), NowPlayingCommandResult.executed);
    });

    test('commands run serially in arrival order', () async {
      final order = <String>[];
      final slow = _OrderedTransport(order);
      final r = NowPlayingCommandRouter(slow, clock: () => now);
      final f1 = r.handle('next');
      now = now.add(const Duration(seconds: 1));
      final f2 = r.handle('previous');
      await Future.wait([f1, f2]);
      expect(order, ['next:start', 'next:end', 'previous:start', 'previous:end']);
    });
  });

  group('service over a mocked native channel', () {
    const channel = MethodChannel(macNowPlayingChannelName);
    late List<MethodCall> sent;
    late _FakeTransport t;
    late PlayerSnapshot current;
    late bool canSkip;
    late DateTime now;
    Object? nativeError;

    MacNowPlayingService make({bool supported = true}) => MacNowPlayingService(
          transport: t,
          readSnapshot: () => current,
          readCanSkipNext: () => canSkip,
          channel: channel,
          supported: supported,
          clock: () => now,
          log: (_) {},
        );

    setUp(() {
      sent = [];
      t = _FakeTransport();
      current = _snap();
      canSkip = true;
      now = DateTime(2026, 1, 1);
      nativeError = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        sent.add(call);
        if (nativeError != null) throw nativeError!;
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<void> nativeCommand(Map<String, Object?> args) async {
      final codec = const StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(macNowPlayingChannelName,
              codec.encodeMethodCall(MethodCall('command', args)), (_) {});
    }

    test('startup clears stale state, then publishes the current snapshot',
        () async {
      final s = make();
      await s.startup();
      await Future<void>.delayed(Duration.zero);
      expect(sent.map((c) => c.method), ['clear', 'update']);
      expect((sent[1].arguments as Map)['title'], 'Song A');
      s.dispose();
    });

    test('unsupported platform sends nothing', () async {
      final s = make(supported: false);
      await s.startup();
      s.onSnapshot(_snap());
      s.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(sent, isEmpty);
    });

    test('state change and track transition are published', () async {
      final s = make();
      await s.startup();
      s.onSnapshot(_snap(isPlaying: false));
      s.onSnapshot(_snap(current: _b, isPlaying: false));
      await Future<void>.delayed(Duration.zero);
      final updates = sent.where((c) => c.method == 'update').toList();
      expect(updates.length, 3);
      expect((updates[1].arguments as Map)['state'], macNpStatePaused);
      expect((updates[2].arguments as Map)['title'], 'Song B');
      s.dispose();
    });

    test('position ticks are not published', () async {
      final s = make();
      await s.startup();
      s.onSnapshot(_snap(position: const Duration(milliseconds: 400)));
      s.onSnapshot(_snap(position: const Duration(milliseconds: 800)));
      await Future<void>.delayed(Duration.zero);
      expect(sent.where((c) => c.method == 'update').length, 1);
      s.dispose();
    });

    test('canNext is read from queue logic, not assumed', () async {
      canSkip = false;
      current = _snap();
      final s = make();
      await s.startup();
      await Future<void>.delayed(Duration.zero);
      expect((sent.last.arguments as Map)['canNext'], isFalse);
      s.dispose();
    });

    test('system commands reach the player once', () async {
      final s = make();
      await s.startup();
      await nativeCommand({'name': 'next'});
      t.playing = true;
      await nativeCommand({'name': 'toggle'});
      expect(t.calls, ['next', 'toggle']);
      s.dispose();
    });

    test('same command delivered twice quickly executes once', () async {
      final s = make();
      await s.startup();
      await nativeCommand({'name': 'toggle'});
      now = now.add(const Duration(milliseconds: 20));
      await nativeCommand({'name': 'toggle'});
      expect(t.calls, ['toggle']);
      s.dispose();
    });

    test('system seek forces a republish of the new position', () async {
      final s = make();
      await s.startup();
      await nativeCommand({'name': 'seek', 'positionMs': 2000});
      // Small (< threshold) jump: only the force flag makes it publish.
      s.onSnapshot(_snap(position: const Duration(seconds: 2)));
      await Future<void>.delayed(Duration.zero);
      final updates = sent.where((c) => c.method == 'update').toList();
      expect(updates.length, 2);
      expect((updates.last.arguments as Map)['positionMs'], 2000);
      expect(t.calls, ['seek:2000']);
      s.dispose();
    });

    test('malformed native calls are ignored', () async {
      final s = make();
      await s.startup();
      await nativeCommand({'nope': 1});
      await nativeCommand({'name': 7});
      await nativeCommand({'name': 'stop'});
      expect(t.calls, isEmpty);
      s.dispose();
    });

    test('bridge failure never throws and the next change republishes',
        () async {
      nativeError = PlatformException(code: 'boom');
      final s = make();
      await s.startup();
      await Future<void>.delayed(Duration.zero);
      expect(s.isFailing, isTrue);

      nativeError = null;
      sent.clear();
      // No state change, but the failed push forgot `_last`, so this
      // identical snapshot is republished in full.
      s.onSnapshot(_snap());
      await Future<void>.delayed(Duration.zero);
      expect(sent.where((c) => c.method == 'update').length, 1);
      expect(s.isFailing, isFalse);
      s.dispose();
    });

    test('missing native plugin degrades silently', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final s = make();
      await s.startup();
      s.onSnapshot(_snap(isPlaying: false));
      await Future<void>.delayed(Duration.zero);
      expect(s.isFailing, isTrue);
      s.dispose();
    });

    test('dispose clears system state and stops handling commands', () async {
      final s = make();
      await s.startup();
      sent.clear();
      s.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(sent.map((c) => c.method), ['clear']);
      await nativeCommand({'name': 'next'});
      s.onSnapshot(_snap(current: _b));
      await Future<void>.delayed(Duration.zero);
      expect(t.calls, isEmpty);
      expect(sent.length, 1);
    });
  });
}

class _OrderedTransport implements NowPlayingTransport {
  _OrderedTransport(this.order);
  final List<String> order;

  @override
  bool get hasTrack => true;
  @override
  bool get isPlaying => true;

  Future<void> _slow(String n) async {
    order.add('$n:start');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    order.add('$n:end');
  }

  @override
  Future<void> next() => _slow('next');
  @override
  Future<void> previous() => _slow('previous');
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> toggle() async {}
  @override
  Future<void> seek(Duration position) async {}
}
