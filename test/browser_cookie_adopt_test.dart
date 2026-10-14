import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/innertube/browser_cookie_adopt.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:sqlite3/sqlite3.dart';

// All cookie names/values below are synthetic. No real credentials.

/// True when this SQLite build rejects `"double-quoted"` string literals
/// (SQLITE_DQS=0), which is what produced the original
/// `no such column: "%google.com"` failure.
bool _sqliteRejectsDoubleQuotedLiterals() {
  try {
    final db = sqlite3.openInMemory();
    try {
      db.select('SELECT "no_such_column_probe"');
      return false;
    } on SqliteException {
      return true;
    } finally {
      db.dispose();
    }
  } catch (_) {
    return false;
  }
}

/// In-memory DB with Chromium's cookie-table columns (subset) and `meta`.
Database _cookieDb({int? metaVersion}) {
  final db = sqlite3.openInMemory();
  db.execute('CREATE TABLE cookies ('
      'host_key TEXT NOT NULL, name TEXT NOT NULL, '
      'value TEXT NOT NULL, encrypted_value BLOB NOT NULL)');
  db.execute('CREATE TABLE meta ('
      'key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)');
  if (metaVersion != null) {
    db.execute('INSERT INTO meta (key, value) VALUES (?, ?)',
        ['version', '$metaVersion']);
  }
  return db;
}

void _insert(Database db, String host, String name,
    {String value = '', Uint8List? encrypted}) {
  db.execute(
    'INSERT INTO cookies (host_key, name, value, encrypted_value) '
    'VALUES (?, ?, ?, ?)',
    [host, name, value, encrypted ?? Uint8List(0)],
  );
}

/// Fake "v10" blob: prefix + bytes that [_identityDecrypt] returns verbatim.
Uint8List _fakeV10(List<int> plaintext) =>
    Uint8List.fromList([0x76, 0x31, 0x30, ...plaintext]);

Uint8List? _identityDecrypt(Uint8List key, Uint8List ciphertext) =>
    Uint8List.fromList(ciphertext);

Uint8List? _failingDecrypt(Uint8List key, Uint8List ciphertext) => null;

final _key = Uint8List(16);
/// Correct Chromium v24 prefix: SHA-256 of the EXACT stored host_key.
List<int> _hostHash(String hostKey) => sha256.convert(utf8.encode(hostKey)).bytes;

/// v10 blob whose "decryption" yields `SHA-256(host) || value` (identity
/// decrypt in tests; real AES is macOS-only and not exercised here).
Uint8List _v24Blob(String hostKey, String value) =>
    _fakeV10([..._hostHash(hostKey), ...utf8.encode(value)]);

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

  group('cookie query (SQLite quoting regression)', () {
    test('query binds its LIKE patterns instead of inlining them', () {
      expect(cookieQuerySql.contains('"'), isFalse,
          reason: 'double quotes are parsed as identifiers by SQLite');
      expect('?'.allMatches(cookieQuerySql).length,
          equals(cookieQueryParams.length));
      expect(cookieQueryParams, equals(['%youtube.com', '%google.com']));
    });

    test(
      'legacy double-quoted query fails with "no such column" (original bug)',
      () {
        final db = _cookieDb();
        addTearDown(db.dispose);
        expect(
          () => db.select(
            'SELECT host_key, name, value, encrypted_value FROM cookies '
            'WHERE host_key LIKE "%youtube.com" OR host_key LIKE "%google.com"',
          ),
          throwsA(isA<SqliteException>()
              .having((e) => e.message, 'message', contains('no such column'))),
        );
      },
      skip: _sqliteRejectsDoubleQuotedLiterals()
          ? null
          : 'This SQLite build accepts double-quoted literals; the structural '
              'test above still guards the production query.',
    );

    test('production query executes against the Chromium cookie schema', () {
      final db = _cookieDb(metaVersion: 20);
      addTearDown(db.dispose);
      _insert(db, '.youtube.com', 'YT_ONLY', value: 'fake-a');
      _insert(db, '.google.com', 'G_ONLY', value: 'fake-b');
      _insert(db, 'example.com', 'OTHER', value: 'fake-c');

      final rows = db.select(cookieQuerySql, cookieQueryParams);
      expect(rows.map((r) => r['name']).toSet(), equals({'YT_ONLY', 'G_ONLY'}));
    });
  });

  group('readCookiesFromDatabase selection', () {
    test('skips unrelated hosts, including look-alike suffix matches', () {
      final db = _cookieDb(metaVersion: 20);
      addTearDown(db.dispose);
      _insert(db, '.youtube.com', 'A', value: 'fake-a');
      _insert(db, 'evilgoogle.com', 'B', value: 'fake-b'); // matches LIKE
      _insert(db, 'example.com', 'C', value: 'fake-c');

      final r = readCookiesFromDatabase(db, _key, decrypt: _failingDecrypt);
      expect(r.cookies.keys, equals(['A']));
    });

    test('most specific domain wins regardless of row order', () {
      for (final order in [
        ['.google.com', '.youtube.com', 'music.youtube.com'],
        ['music.youtube.com', '.youtube.com', '.google.com'],
      ]) {
        final db = _cookieDb(metaVersion: 20);
        addTearDown(db.dispose);
        for (final host in order) {
          _insert(db, host, 'SID', value: 'fake-from-$host');
        }
        final r = readCookiesFromDatabase(db, _key);
        expect(r.cookies['SID'], equals('fake-from-music.youtube.com'),
            reason: 'order: $order');
      }
    });

    test('plain value column is used without decrypting', () {
      final db = _cookieDb(metaVersion: 24);
      addTearDown(db.dispose);
      _insert(db, '.youtube.com', 'PLAIN', value: 'fake-plain');
      final r = readCookiesFromDatabase(db, _key,
          decrypt: (k, c) => fail('decrypt must not be called'));
      expect(r.cookies['PLAIN'], equals('fake-plain'));
      expect(r.encryptedSeen, equals(0));
    });
  });

  group('cookie decryption', () {
    test('meta version >= 24: verifies the host hash, then strips it', () {
      final db = _cookieDb(metaVersion: 24);
      addTearDown(db.dispose);
      _insert(db, '.youtube.com', 'SAPISID',
          encrypted: _v24Blob('.youtube.com', 'fake-value'));

      final r = readCookiesFromDatabase(db, _key, decrypt: _identityDecrypt);
      expect(r.metaVersion, equals(24));
      expect(r.cookies['SAPISID'], equals('fake-value'));
      expect(r.decryptFailed, equals(0));
      expect(r.hashMismatch, equals(0));
    });

    test('hash covers the exact stored host_key (case and leading dot)', () {
      final db = _cookieDb(metaVersion: 24);
      addTearDown(db.dispose);
      // SQLite LIKE is ASCII case-insensitive, so this row is selected.
      _insert(db, '.YouTube.com', 'EXACT',
          encrypted: _v24Blob('.YouTube.com', 'fake-exact'));
      // Hash computed over the lower-cased form must NOT verify.
      _insert(db, '.YouTube.com', 'LOWERED',
          encrypted: _v24Blob('.youtube.com', 'fake-lowered'));
      // Hash computed without the leading dot must NOT verify.
      _insert(db, '.youtube.com', 'NODOT',
          encrypted: _v24Blob('youtube.com', 'fake-nodot'));

      final r = readCookiesFromDatabase(db, _key, decrypt: _identityDecrypt);
      expect(r.cookies.keys, equals(['EXACT']));
      expect(r.hashMismatch, equals(2));
    });

    test('v24 wrong host hash is rejected and counted, not accepted', () {
      final db = _cookieDb(metaVersion: 24);
      addTearDown(db.dispose);
      // Valid hash, but for a different host (cookie moved/forged).
      _insert(db, '.youtube.com', 'SAPISID',
          encrypted: _v24Blob('.google.com', 'fake-value'));

      final r = readCookiesFromDatabase(db, _key, decrypt: _identityDecrypt);
      expect(r.cookies, isEmpty);
      expect(r.encryptedSeen, equals(1));
      expect(r.decryptFailed, equals(1));
      expect(r.hashMismatch, equals(1));
    });

    test('hash mismatch never falls back to using the bytes as a value', () {
      final db = _cookieDb(metaVersion: 24);
      addTearDown(db.dispose);
      // 32 bytes of printable ASCII + text: the WHOLE plaintext is valid
      // UTF-8, so an unverified fallback would happily accept it.
      final bogusPrefix = List<int>.filled(32, 0x41);
      _insert(db, '.youtube.com', 'SAPISID',
          encrypted: _fakeV10([...bogusPrefix, ...utf8.encode('fake-value')]));

      final r = readCookiesFromDatabase(db, _key, decrypt: _identityDecrypt);
      expect(r.cookies.containsKey('SAPISID'), isFalse);
      expect(r.cookies.values.any((v) => v.contains('fake-value')), isFalse);
      expect(r.hashMismatch, equals(1));

      final direct = decodeChromiumCookieValue(
        hostKey: '.youtube.com',
        plainValue: '',
        encryptedValue:
            _fakeV10([...bogusPrefix, ...utf8.encode('fake-value')]),
        key: _key,
        metaVersion: 24,
        decrypt: _identityDecrypt,
      );
      expect(direct.value, isNull);
      expect(direct.failure, equals(CookieDecodeFailure.hostHashMismatch));
    });

    test('v24 plaintext shorter than the hash is rejected', () {
      final db = _cookieDb(metaVersion: 24);
      addTearDown(db.dispose);
      _insert(db, '.youtube.com', 'SHORT', encrypted: _fakeV10([1, 2, 3]));
      final r = readCookiesFromDatabase(db, _key, decrypt: _identityDecrypt);
      expect(r.cookies, isEmpty);
      expect(r.decryptFailed, equals(1));
      expect(r.hashMismatch, equals(0));
    });

    test('meta version < 24: no hash expected, value not trimmed', () {
      final db = _cookieDb(metaVersion: 23);
      addTearDown(db.dispose);
      _insert(db, '.youtube.com', 'SAPISID',
          encrypted: _fakeV10(utf8.encode('fake-value')));

      final r = readCookiesFromDatabase(db, _key, decrypt: _identityDecrypt);
      expect(r.metaVersion, equals(23));
      expect(r.cookies['SAPISID'], equals('fake-value'));
    });

    test('undecryptable or non-UTF-8 values are dropped and counted', () {
      final db = _cookieDb(metaVersion: 20);
      addTearDown(db.dispose);
      _insert(db, '.youtube.com', 'BAD_BYTES',
          encrypted: _fakeV10([0xFF, 0xFE, 0xFD, 0xFC])); // invalid UTF-8

      final bad = readCookiesFromDatabase(db, _key, decrypt: _identityDecrypt);
      expect(bad.cookies, isEmpty);
      expect(bad.decryptFailed, equals(1));

      final nulls = readCookiesFromDatabase(db, _key, decrypt: _failingDecrypt);
      expect(nulls.cookies, isEmpty);
      expect(nulls.encryptedSeen, equals(1));
      expect(nulls.decryptFailed, equals(1));
    });
  });

  group('meta.version: unknown is not pre-v24', () {
    test('missing meta table -> null (not 0)', () {
      final db = _cookieDb();
      addTearDown(db.dispose);
      db.execute('DROP TABLE meta');
      expect(readCookieMetaVersion(db), isNull);
    });

    test('missing version row -> null', () {
      final db = _cookieDb();
      addTearDown(db.dispose);
      expect(readCookieMetaVersion(db), isNull);
    });

    test('non-numeric version -> null', () {
      final db = _cookieDb();
      addTearDown(db.dispose);
      db.execute('INSERT INTO meta (key, value) VALUES (?, ?)',
          ['version', 'not-a-number']);
      expect(readCookieMetaVersion(db), isNull);
    });

    test('numeric version parses (text or integer storage)', () {
      final db = _cookieDb(metaVersion: 24);
      addTearDown(db.dispose);
      expect(readCookieMetaVersion(db), equals(24));
    });

    test('unknown version fails closed for encrypted cookies', () {
      final db = _cookieDb(); // no version row
      addTearDown(db.dispose);
      _insert(db, '.youtube.com', 'ENC',
          encrypted: _fakeV10(utf8.encode('fake-value')));
      _insert(db, '.youtube.com', 'PLAIN', value: 'fake-plain');

      final r = readCookiesFromDatabase(db, _key, decrypt: _identityDecrypt);
      expect(r.metaVersion, isNull);
      expect(r.cookies.keys, equals(['PLAIN']),
          reason: 'plain values need no version; encrypted ones must not '
              'be guessed');
      expect(r.decryptFailed, equals(1));

      final direct = decodeChromiumCookieValue(
        hostKey: '.youtube.com',
        plainValue: '',
        encryptedValue: _fakeV10(utf8.encode('fake-value')),
        key: _key,
        metaVersion: null,
        decrypt: (k, c) => fail('must not decrypt with unknown version'),
      );
      expect(direct.failure, equals(CookieDecodeFailure.versionUnknown));
    });
  });

  group('session validation', () {
    const loginCookies = {
      'SAPISID': 'fake-sapisid',
      'SID': 'fake-sid',
      'HSID': 'fake-hsid',
    };

    test('rejects a session without a SAPISID-family cookie', () {
      expect(
        () => BrowserSessionAdopt.filterAndFormatCookies({'SID': 'fake-sid'}),
        throwsA(isA<AdoptValidationException>()),
      );
    });

    test('rejects a session without a login marker', () {
      expect(
        () => BrowserSessionAdopt.filterAndFormatCookies(
            {'SAPISID': 'fake-sapisid', 'HSID': 'fake-hsid'}),
        throwsA(isA<AdoptValidationException>()),
      );
    });

    test('header is accepted unchanged by the API client normalizer', () {
      final header = BrowserSessionAdopt.filterAndFormatCookies(loginCookies);
      final normalized = InnerTubeMusicApi.normalizeCookies(header);

      Map<String, String> parse(String h) => {
            for (final part in h.split('; '))
              part.substring(0, part.indexOf('=')):
                  part.substring(part.indexOf('=') + 1),
          };
      expect(parse(normalized), equals(loginCookies));
    });
  });
}
