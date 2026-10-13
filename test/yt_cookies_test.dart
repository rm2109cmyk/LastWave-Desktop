import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';

void main() {
  test('header string passes through normalized', () {
    final out = InnerTubeMusicApi.normalizeCookies(
        'SID=aaa; __Secure-3PAPISID=bbb; HSID=ccc');
    expect(out, contains('SID=aaa'));
    expect(out, contains('__Secure-3PAPISID=bbb'));
    expect(out, contains('HSID=ccc'));
  });

  test('netscape cookies.txt extracts pairs', () {
    const txt = '# Netscape HTTP Cookie File\n'
        '.youtube.com\tTRUE\t/\tTRUE\t123\tSID\taaa\n'
        '#HttpOnly .youtube.com\tTRUE\t/\tTRUE\t123\t__Secure-3PAPISID\tbbb\n'
        '.youtube.com\tTRUE\t/\tTRUE\t123\tLOGIN_INFO\tccc\n';
    final out = InnerTubeMusicApi.normalizeCookies(txt);
    expect(out, contains('SID=aaa'));
    expect(out, contains('__Secure-3PAPISID=bbb'));
    expect(out, contains('LOGIN_INFO=ccc'));
  });

  test('multiline + Cookie: prefix handled', () {
    const raw = 'Cookie: SID=aaa; HSID=zzz\nSAPISID=mmm; SSID=nnn';
    final out = InnerTubeMusicApi.normalizeCookies(raw);
    expect(out, contains('SAPISID=mmm'));
    expect(out, contains('SSID=nnn'));
  });

  test('JSON array export handled', () {
    const raw =
        '[{"name":"SID","value":"aaa"},{"name":"SAPISID","value":"bbb"}]';
    final out = InnerTubeMusicApi.normalizeCookies(raw);
    expect(out, contains('SID=aaa'));
    expect(out, contains('SAPISID=bbb'));
  });

  test('missing SAPISID throws', () {
    expect(() => InnerTubeMusicApi.normalizeCookies('SID=aaa; HSID=bbb'),
        throwsFormatException);
  });

  test('empty throws', () {
    expect(() => InnerTubeMusicApi.normalizeCookies('   '),
        throwsFormatException);
  });

  group('mergeSetCookieHeaders', () {
    test('returns current jar if setCookies is empty', () {
      const jar = 'SID=aaa; SAPISID=bbb';
      final out = InnerTubeMusicApi.mergeSetCookieHeaders(jar, []);
      expect(out, equals(jar));
    });

    test('absorbs rotated __Secure-1PSIDTS and updates jar', () {
      const jar = 'SID=aaa; SAPISID=bbb; __Secure-1PSIDTS=old_val';
      final setCookies = [
        '__Secure-1PSIDTS=new_val; Domain=.youtube.com; Path=/; Secure; HttpOnly; SameSite=none',
      ];
      final out = InnerTubeMusicApi.mergeSetCookieHeaders(jar, setCookies);
      expect(out, contains('__Secure-1PSIDTS=new_val'));
      expect(out, isNot(contains('__Secure-1PSIDTS=old_val')));
      expect(out, contains('SID=aaa'));
      expect(out, contains('SAPISID=bbb'));
    });

    test('adds new rotated cookie if not previously in jar', () {
      const jar = 'SID=aaa; SAPISID=bbb';
      final setCookies = [
        '__Secure-3PSIDTS=rot_3p; Domain=.youtube.com; Path=/',
      ];
      final out = InnerTubeMusicApi.mergeSetCookieHeaders(jar, setCookies);
      expect(out, contains('__Secure-3PSIDTS=rot_3p'));
      expect(out, contains('SID=aaa'));
      expect(out, contains('SAPISID=bbb'));
    });
  });

  group('extractCookiesFromList domain specificity', () {
    test('prioritizes music.youtube.com over .youtube.com over .google.com', () {
      final list = [
        const _TestCookie(domain: '.google.com', name: 'SAPISID', value: 'google_sapisid'),
        const _TestCookie(domain: '.youtube.com', name: 'SAPISID', value: 'yt_sapisid'),
        const _TestCookie(domain: 'music.youtube.com', name: 'SAPISID', value: 'music_sapisid'),
        const _TestCookie(domain: '.youtube.com', name: 'LOGIN_INFO', value: 'login_val'),
      ];
      final out = YtWebLogin.extractCookiesFromList(list);
      expect(out, isNotNull);
      expect(out, contains('SAPISID=music_sapisid'));
      expect(out, contains('LOGIN_INFO=login_val'));
    });

    test('returns null if LOGIN_INFO or SAPISID is missing', () {
      final listNoLogin = [
        const _TestCookie(domain: 'music.youtube.com', name: 'SAPISID', value: 'music_sapisid'),
      ];
      expect(YtWebLogin.extractCookiesFromList(listNoLogin), isNull);

      final listNoSapisid = [
        const _TestCookie(domain: 'music.youtube.com', name: 'LOGIN_INFO', value: 'login_val'),
      ];
      expect(YtWebLogin.extractCookiesFromList(listNoSapisid), isNull);
    });
  });
}

class _TestCookie {
  final String? domain;
  final String? name;
  final String? value;
  const _TestCookie({this.domain, this.name, this.value});
}
