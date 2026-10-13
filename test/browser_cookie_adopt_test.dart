import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/innertube/browser_cookie_adopt.dart';

void main() {
  group('BrowserSessionAdopt key derivation', () {
    test('deriveChromiumKey derives a 16-byte key for peanuts', () {
      final key = deriveChromiumKey('peanuts');
      expect(key.length, equals(16));
    });

    test('deriveChromiumKey is deterministic', () {
      final key1 = deriveChromiumKey('test_password_123');
      final key2 = deriveChromiumKey('test_password_123');
      expect(key1, equals(key2));
    });

    test('different passwords produce distinct keys', () {
      final key1 = deriveChromiumKey('passwordA');
      final key2 = deriveChromiumKey('passwordB');
      expect(key1, isNot(equals(key2)));
    });
  });

  group('BrowserProfile model', () {
    test('displayName formats browser and profile name correctly', () {
      const profile = BrowserProfile(
        browserId: 'arc',
        browserName: 'Arc',
        profileName: 'Default',
        profilePath: '/mock/path/Default',
        cookiesPath: '/mock/path/Default/Cookies',
      );
      expect(profile.displayName, equals('Arc (Default)'));
      expect(profile.toString(), equals('Arc (Default)'));
    });
  });

  group('AdoptException hierarchy', () {
    test('all specific adopt exceptions extend AdoptException', () {
      expect(
        const AdoptNotFoundException('not found'),
        isA<AdoptException>(),
      );
      expect(
        const AdoptPermissionException('permission denied'),
        isA<AdoptException>(),
      );
      expect(
        const AdoptDecryptionException('decryption failed'),
        isA<AdoptException>(),
      );
      expect(
        const AdoptValidationException('validation failed'),
        isA<AdoptException>(),
      );
    });

    test('exception toString returns message', () {
      const exc = AdoptPermissionException('Sandbox restricted');
      expect(exc.toString(), equals('Sandbox restricted'));
    });
  });
}
