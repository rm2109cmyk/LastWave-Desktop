import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/innertube/yt_web_login.dart';

// Synthetic stand-in for the plugin's WebviewCookie (only the fields read by
// YtWebLogin.extractCookiesFromList). No real credentials.
class _FakeCookie {
  final String name;
  final String value;
  final String domain;
  const _FakeCookie(this.name, this.value, this.domain);
}

void main() {
  group('extractCookiesFromList', () {
    test('returns null without LOGIN_INFO', () {
      expect(
        YtWebLogin.extractCookiesFromList(const [
          _FakeCookie('SAPISID', 'fake-a', '.youtube.com'),
        ]),
        isNull,
      );
    });

    test('returns null without a SAPISID-family cookie', () {
      expect(
        YtWebLogin.extractCookiesFromList(const [
          _FakeCookie('LOGIN_INFO', 'fake-b', '.youtube.com'),
        ]),
        isNull,
      );
    });

    test('returns a header when both markers exist; ignores other sites', () {
      final header = YtWebLogin.extractCookiesFromList(const [
        _FakeCookie('SAPISID', 'fake-a', '.youtube.com'),
        _FakeCookie('LOGIN_INFO', 'fake-b', '.youtube.com'),
        _FakeCookie('TRACKER', 'fake-c', 'example.com'),
      ]);
      expect(header, isNotNull);
      expect(header, contains('SAPISID=fake-a'));
      expect(header, contains('LOGIN_INFO=fake-b'));
      expect(header, isNot(contains('TRACKER')));
    });

    test('strips a trailing NUL from cookie names', () {
      final header = YtWebLogin.extractCookiesFromList(const [
        _FakeCookie('SAPISID\u0000', 'fake-a', '.youtube.com'),
        _FakeCookie('LOGIN_INFO\u0000', 'fake-b', '.youtube.com'),
      ]);
      expect(header, isNotNull);
      expect(header, contains('SAPISID=fake-a'));
    });

    test('more specific domain wins a name collision', () {
      final header = YtWebLogin.extractCookiesFromList(const [
        _FakeCookie('SAPISID', 'fake-google', '.google.com'),
        _FakeCookie('SAPISID', 'fake-music', 'music.youtube.com'),
        _FakeCookie('LOGIN_INFO', 'fake-b', '.youtube.com'),
      ]);
      expect(header, contains('SAPISID=fake-music'));
      expect(header, isNot(contains('fake-google')));
    });
  });

  test('detects the passkey verification stall text', () {
    expect(
      YtWebLogin.isPasskeyVerificationStall(
        "Mrinmoy Haloi\nVerifying that it's you...\n"
        'Complete sign-in using your passkey\nTry another way',
      ),
      isTrue,
    );
  });

  test('ignores ordinary login pages', () {
    expect(YtWebLogin.isPasskeyVerificationStall('Sign in'), isFalse);
    expect(
      YtWebLogin.isPasskeyVerificationStall(
          'Verify it\'s you\nEnter your password'),
      isFalse,
    );
    expect(YtWebLogin.isPasskeyVerificationStall(''), isFalse);
  });

  test('matching is case-insensitive', () {
    expect(
      YtWebLogin.isPasskeyVerificationStall(
          'VERIFYING THAT IT\'S YOU — use passkey'),
      isTrue,
    );
  });
}
