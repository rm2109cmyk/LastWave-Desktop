/// Browser session adoption for YouTube Music on macOS.
///
/// Discovers Chromium-family browser profiles (Arc, Chrome, Brave, Edge,
/// Chromium, Vivaldi), retrieves Safe Storage passwords from the macOS
/// Keychain, decrypts cookie databases using PBKDF2 and CommonCrypto AES-128-CBC,
/// filters for YouTube session cookies with domain specificity sorting, and
/// validates required login markers.
///
/// Diagnostics use safe metadata only: stage names, success/failure booleans,
/// error categories, row counts, and cookie name lists.
/// NEVER logs cookie values, passwords, keys, tokens, or auth headers.
library browser_cookie_adopt;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha1, sha256;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import 'innertube_api.dart';

// ---------------------------------------------------------------------------
// Privacy-safe Diagnostic Logger
// ---------------------------------------------------------------------------

/// Diagnostic logger for browser adoption stages.
/// Grep prefix: `[AdoptDiag]`
void _adoptLog(String stage, Map<String, dynamic> metadata) {
  final metaStr = metadata.entries.map((e) => '${e.key}=${e.value}').join(' ');
  debugPrint('[AdoptDiag] $stage | $metaStr');
}

// ---------------------------------------------------------------------------
// Public Models & Exceptions
// ---------------------------------------------------------------------------

class BrowserProfile {
  final String browserId;
  final String browserName;
  final String profileName;
  final String profilePath;
  final String cookiesPath;

  const BrowserProfile({
    required this.browserId,
    required this.browserName,
    required this.profileName,
    required this.profilePath,
    required this.cookiesPath,
  });

  String get displayName => '$browserName ($profileName)';

  @override
  String toString() => displayName;
}

sealed class AdoptException implements Exception {
  final String message;
  const AdoptException(this.message);
  @override
  String toString() => message;
}

class AdoptNotFoundException extends AdoptException {
  const AdoptNotFoundException(super.message);
}

class AdoptPermissionException extends AdoptException {
  const AdoptPermissionException(super.message);
}

class AdoptDecryptionException extends AdoptException {
  const AdoptDecryptionException(super.message);
}

class AdoptValidationException extends AdoptException {
  const AdoptValidationException(super.message);
}

// ---------------------------------------------------------------------------
// Supported Chromium Browsers
// ---------------------------------------------------------------------------

class _BrowserConfig {
  final String id;
  final String name;
  final String relativeUserDataDir;
  final String keychainService;
  final String keychainAccount;

  const _BrowserConfig({
    required this.id,
    required this.name,
    required this.relativeUserDataDir,
    required this.keychainService,
    required this.keychainAccount,
  });
}

const _supportedBrowsers = <_BrowserConfig>[
  _BrowserConfig(
    id: 'arc',
    name: 'Arc',
    relativeUserDataDir: 'Library/Application Support/Arc/User Data',
    keychainService: 'Arc Safe Storage',
    keychainAccount: 'Arc',
  ),
  _BrowserConfig(
    id: 'chrome',
    name: 'Google Chrome',
    relativeUserDataDir: 'Library/Application Support/Google/Chrome',
    keychainService: 'Chrome Safe Storage',
    keychainAccount: 'Chrome',
  ),
  _BrowserConfig(
    id: 'brave',
    name: 'Brave',
    relativeUserDataDir:
        'Library/Application Support/BraveSoftware/Brave-Browser',
    keychainService: 'Brave Safe Storage',
    keychainAccount: 'Brave',
  ),
  _BrowserConfig(
    id: 'edge',
    name: 'Microsoft Edge',
    relativeUserDataDir: 'Library/Application Support/Microsoft Edge',
    keychainService: 'Microsoft Edge Safe Storage',
    keychainAccount: 'Microsoft Edge',
  ),
  _BrowserConfig(
    id: 'chromium',
    name: 'Chromium',
    relativeUserDataDir: 'Library/Application Support/Chromium',
    keychainService: 'Chromium Safe Storage',
    keychainAccount: 'Chromium',
  ),
  _BrowserConfig(
    id: 'vivaldi',
    name: 'Vivaldi',
    relativeUserDataDir: 'Library/Application Support/Vivaldi',
    keychainService: 'Vivaldi Safe Storage',
    keychainAccount: 'Vivaldi',
  ),
];

// ---------------------------------------------------------------------------
// Native Crypto (CommonCrypto AES-128-CBC via FFI)
// ---------------------------------------------------------------------------

typedef _CCCryptNative = Int32 Function(
  Uint32 op,
  Uint32 alg,
  Uint32 options,
  Pointer<Void> key,
  Size keyLength,
  Pointer<Void> iv,
  Pointer<Void> dataIn,
  Size dataInLength,
  Pointer<Void> dataOut,
  Size dataOutAvailable,
  Pointer<Size> dataOutMoved,
);

typedef _CCCryptDart = int Function(
  int op,
  int alg,
  int options,
  Pointer<Void> key,
  int keyLength,
  Pointer<Void> iv,
  Pointer<Void> dataIn,
  int dataInLength,
  Pointer<Void> dataOut,
  int dataOutAvailable,
  Pointer<Size> dataOutMoved,
);

class _CommonCrypto {
  static _CCCryptDart? _ccCrypt;
  static bool _initDone = false;

  static bool init() {
    if (_initDone) return _ccCrypt != null;
    _initDone = true;
    if (!Platform.isMacOS) return false;

    try {
      final lib = DynamicLibrary.process();
      _ccCrypt = lib.lookupFunction<_CCCryptNative, _CCCryptDart>('CCCrypt');
      return true;
    } catch (_) {
      try {
        final lib = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
        _ccCrypt = lib.lookupFunction<_CCCryptNative, _CCCryptDart>('CCCrypt');
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  /// Decrypts AES-128-CBC with PKCS#7 padding using 16-space IV.
  static Uint8List? decryptAes128Cbc(Uint8List key, Uint8List ciphertext) {
    if (!init() || _ccCrypt == null) return null;
    if (ciphertext.isEmpty) return Uint8List(0);

    const kCCDecrypt = 1;
    const kCCAlgorithmAES = 0;
    const kCCOptionPKCS7Padding = 1;

    // Chromium legacy IV: 16 ASCII spaces (0x20)
    final iv = Uint8List(16)..fillRange(0, 16, 0x20);

    final keyPtr = calloc<Uint8>(key.length);
    final ivPtr = calloc<Uint8>(iv.length);
    final inPtr = calloc<Uint8>(ciphertext.length);
    final outBufferSize = ciphertext.length + 16;
    final outPtr = calloc<Uint8>(outBufferSize);
    final outMovedPtr = calloc<Size>();

    try {
      keyPtr.asTypedList(key.length).setAll(0, key);
      ivPtr.asTypedList(iv.length).setAll(0, iv);
      inPtr.asTypedList(ciphertext.length).setAll(0, ciphertext);

      final status = _ccCrypt!(
        kCCDecrypt,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding,
        keyPtr.cast<Void>(),
        key.length,
        ivPtr.cast<Void>(),
        inPtr.cast<Void>(),
        ciphertext.length,
        outPtr.cast<Void>(),
        outBufferSize,
        outMovedPtr,
      );

      if (status != 0) return null;

      final moved = outMovedPtr.value;
      return Uint8List.fromList(outPtr.asTypedList(moved));
    } catch (_) {
      return null;
    } finally {
      calloc.free(keyPtr);
      calloc.free(ivPtr);
      calloc.free(inPtr);
      calloc.free(outPtr);
      calloc.free(outMovedPtr);
    }
  }
}

// ---------------------------------------------------------------------------
// Pure-Dart PBKDF2-HMAC-SHA1
// ---------------------------------------------------------------------------

/// RFC 2898 standard PBKDF2-HMAC-SHA1 key derivation.
Uint8List deriveChromiumKey(String password) {
  const salt = 'saltysalt'; // 9 bytes ASCII
  const iterations = 1003;
  const keyLength = 16; // AES-128

  final pwBytes = utf8.encode(password);
  final saltBytes = utf8.encode(salt);
  final hmac = Hmac(sha1, pwBytes);

  // Block 1 (keyLength 16 <= 20 bytes SHA1 digest)
  final initialData = Uint8List(saltBytes.length + 4);
  initialData.setRange(0, saltBytes.length, saltBytes);
  initialData[saltBytes.length] = 0;
  initialData[saltBytes.length + 1] = 0;
  initialData[saltBytes.length + 2] = 0;
  initialData[saltBytes.length + 3] = 1;

  var u = Uint8List.fromList(hmac.convert(initialData).bytes);
  final block = Uint8List.fromList(u);

  for (var i = 1; i < iterations; i++) {
    u = Uint8List.fromList(hmac.convert(u).bytes);
    for (var j = 0; j < block.length; j++) {
      block[j] ^= u[j];
    }
  }

  return block.sublist(0, keyLength);
}

// ---------------------------------------------------------------------------
// Cookie database access (pure helpers; unit-tested without a browser)
// ---------------------------------------------------------------------------

/// Query for YouTube/Google cookies. The LIKE patterns are BOUND parameters
/// ([cookieQueryParams]). Inlining them as `"%google.com"` is a bug: SQLite
/// parses a double-quoted token as an identifier first, so it fails with
/// `no such column: "%google.com"`.
const String cookieQuerySql = 'SELECT host_key, name, value, encrypted_value '
    'FROM cookies WHERE host_key LIKE ? OR host_key LIKE ?';

/// Bound values for [cookieQuerySql].
const List<Object?> cookieQueryParams = ['%youtube.com', '%google.com'];

/// From Chromium cookie-DB `meta.version` 24 onward, the plaintext inside every
/// encrypted value is `SHA-256(host_key) || value`. Chromium itself verifies
/// the hash on load and rejects the cookie on mismatch (CookieLoadProblem::
/// kHashFailed in sqlite_persistent_cookie_store.cc); so do we.
const int cookieHashPrefixMinMetaVersion = 24;

/// AES-128-CBC decryptor signature (injectable so tests need no CommonCrypto).
typedef CookieDecryptFn = Uint8List? Function(
    Uint8List key, Uint8List ciphertext);

/// Reads Chromium's `meta.version`.
///
/// Returns null when it cannot be determined (no `meta` table, no `version`
/// row, a non-numeric value, or a SQLite error). That is deliberately NOT
/// mapped to 0: "unknown" is not the same as "genuinely pre-v24", and
/// guessing wrong either way corrupts or mis-validates cookie values.
int? readCookieMetaVersion(Database db) {
  try {
    final rows =
        db.select('SELECT value FROM meta WHERE key = ?', ['version']);
    if (rows.isEmpty) return null;
    final v = rows.first['value'];
    if (v is int) return v;
    return int.tryParse(v?.toString().trim() ?? '');
  } on SqliteException {
    return null;
  }
}

/// Why a cookie row could not be turned into a value. Never carries values.
enum CookieDecodeFailure {
  /// Not a `v10` blob (or too short to be one).
  unsupportedFormat,

  /// `meta.version` unreadable, so the plaintext layout is unknown.
  versionUnknown,

  /// AES decryption itself failed (bad key/padding).
  decryptFailed,

  /// v24+ plaintext shorter than the 32-byte host hash.
  plaintextTooShort,

  /// v24+ host hash does not match SHA-256 of the stored `host_key`.
  hostHashMismatch,

  /// Remaining bytes are not valid UTF-8.
  invalidUtf8,

  /// Decoded fine but the cookie value is empty.
  emptyValue,

  /// Both the plaintext and encrypted cookie fields are populated.
  valuesBothPresent,
}

/// Either a decoded [value] or a [failure] reason; never both.
class CookieDecodeResult {
  final String? value;
  final CookieDecodeFailure? failure;
  const CookieDecodeResult.ok(this.value) : failure = null;
  const CookieDecodeResult.failed(this.failure) : value = null;
}

bool _hasHostHashPrefix(Uint8List plaintext, String hostKey) {
  final expected = sha256.convert(utf8.encode(hostKey)).bytes;
  if (plaintext.length < expected.length) return false;
  var diff = 0;
  for (var i = 0; i < expected.length; i++) {
    diff |= expected[i] ^ plaintext[i];
  }
  return diff == 0;
}

/// Decodes one cookie row to its value or a failure reason.
///
/// [hostKey] must be the EXACT stored `host_key` string (not lower-cased,
/// leading dot kept): Chromium hashes that representation.
///
/// Plain `value` wins. Otherwise a `v10` blob is decrypted. For
/// [metaVersion] >= 24 the first 32 bytes must equal SHA-256([hostKey]); on
/// mismatch the cookie is rejected and the bytes are NEVER reinterpreted as a
/// value. An unknown [metaVersion] fails closed for encrypted values.
CookieDecodeResult decodeChromiumCookieValue({
  required String hostKey,
  required Object? plainValue,
  required Object? encryptedValue,
  required Uint8List key,
  required int? metaVersion,
  CookieDecryptFn? decrypt,
}) {
  if (plainValue is String && plainValue.isNotEmpty) {
    if (encryptedValue is Uint8List && encryptedValue.isNotEmpty) {
      return const CookieDecodeResult.failed(
          CookieDecodeFailure.valuesBothPresent);
    }
    return CookieDecodeResult.ok(plainValue);
  }
  if (encryptedValue is! Uint8List || encryptedValue.length <= 3) {
    return const CookieDecodeResult.failed(
        CookieDecodeFailure.unsupportedFormat);
  }
  // "v10" prefix (macOS Chromium AES-128-CBC). Other prefixes unsupported.
  if (encryptedValue[0] != 0x76 ||
      encryptedValue[1] != 0x31 ||
      encryptedValue[2] != 0x30) {
    return const CookieDecodeResult.failed(
        CookieDecodeFailure.unsupportedFormat);
  }
  if (metaVersion == null) {
    return const CookieDecodeResult.failed(CookieDecodeFailure.versionUnknown);
  }

  final plaintext = (decrypt ?? _CommonCrypto.decryptAes128Cbc)(
      key, Uint8List.sublistView(encryptedValue, 3));
  if (plaintext == null) {
    return const CookieDecodeResult.failed(CookieDecodeFailure.decryptFailed);
  }

  var bytes = plaintext;
  if (metaVersion >= cookieHashPrefixMinMetaVersion) {
    if (bytes.length < 32) {
      return const CookieDecodeResult.failed(
          CookieDecodeFailure.plaintextTooShort);
    }
    if (!_hasHostHashPrefix(bytes, hostKey)) {
      return const CookieDecodeResult.failed(
          CookieDecodeFailure.hostHashMismatch);
    }
    bytes = Uint8List.sublistView(bytes, 32);
  }

  final String value;
  try {
    value = utf8.decode(bytes).trim();
  } on FormatException {
    return const CookieDecodeResult.failed(CookieDecodeFailure.invalidUtf8);
  }
  if (value.isEmpty) {
    return const CookieDecodeResult.failed(CookieDecodeFailure.emptyValue);
  }
  return CookieDecodeResult.ok(value);
}

/// Outcome of reading the cookie table (counts only; never values).
class CookieReadResult {
  final Map<String, String> cookies;

  /// Null when `meta.version` could not be read (see [readCookieMetaVersion]).
  final int? metaVersion;
  final int encryptedSeen;

  /// Encrypted rows that failed for any reason (includes [hashMismatch]).
  final int decryptFailed;

  /// Subset of [decryptFailed]: v24+ host-hash verification failures.
  final int hashMismatch;

  const CookieReadResult({
    required this.cookies,
    required this.metaVersion,
    required this.encryptedSeen,
    required this.decryptFailed,
    required this.hashMismatch,
  });
}

/// Runs [cookieQuerySql] on [db], decodes each row and keeps the most
/// specific domain per cookie name (music.youtube.com > youtube.com >
/// google.com). Hosts that merely end in the same letters (e.g.
/// `evilgoogle.com`) match the LIKE pattern but are skipped.
CookieReadResult readCookiesFromDatabase(
  Database db,
  Uint8List key, {
  CookieDecryptFn? decrypt,
}) {
  final metaVersion = readCookieMetaVersion(db);
  final results = <String, String>{};
  final rankMap = <String, int>{};
  var encryptedSeen = 0;
  var decryptFailed = 0;
  var hashMismatch = 0;

  final rows = db.select(cookieQuerySql, cookieQueryParams);
  for (final row in rows) {
    // Exact stored representation: this is what Chromium hashes.
    final storedHostKey = row['host_key'] as String? ?? '';
    final hostKey = storedHostKey.toLowerCase();
    final name = (row['name'] as String? ?? '').trim();
    if (name.isEmpty) continue;

    int rank = 0;
    if (hostKey == 'music.youtube.com') {
      rank = 3;
    } else if (hostKey == 'youtube.com' || hostKey.endsWith('.youtube.com')) {
      rank = 2;
    } else if (hostKey == 'google.com' || hostKey.endsWith('.google.com')) {
      rank = 1;
    }
    if (rank == 0) continue;

    final currentRank = rankMap[name] ?? 0;
    if (currentRank > rank) continue;

    final plain = row['value'];
    final enc = row['encrypted_value'];
    final hasEncrypted = enc is Uint8List && enc.isNotEmpty;
    final needsDecrypt = !(plain is String && plain.isNotEmpty) && hasEncrypted;
    if (hasEncrypted) encryptedSeen++;

    final result = decodeChromiumCookieValue(
      hostKey: storedHostKey,
      plainValue: plain,
      encryptedValue: enc,
      key: key,
      metaVersion: metaVersion,
      decrypt: decrypt,
    );
    final val = result.value;
    if (val == null) {
      if (hasEncrypted && result.failure != CookieDecodeFailure.emptyValue) {
        decryptFailed++;
        if (result.failure == CookieDecodeFailure.hostHashMismatch) {
          hashMismatch++;
        }
      }
      continue;
    }
    results[name] = val;
    rankMap[name] = rank;
  }

  return CookieReadResult(
    cookies: results,
    metaVersion: metaVersion,
    encryptedSeen: encryptedSeen,
    decryptFailed: decryptFailed,
    hashMismatch: hashMismatch,
  );
}

// ---------------------------------------------------------------------------
// Main Adoption Logic
// ---------------------------------------------------------------------------

class BrowserSessionAdopt {
  BrowserSessionAdopt._();

  /// Stage 1: Discovers installed Chromium browser profiles on macOS.
  static List<BrowserProfile> discoverProfiles() {
    if (!Platform.isMacOS) {
      _adoptLog('Stage1_Discovery', {'platform': Platform.operatingSystem, 'supported': false});
      return const [];
    }

    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      _adoptLog('Stage1_Discovery', {'error': 'HOME_NOT_SET'});
      return const [];
    }

    final discovered = <BrowserProfile>[];

    for (final config in _supportedBrowsers) {
      final userDir = Directory('$home/${config.relativeUserDataDir}');
      var exists = false;
      try {
        exists = userDir.existsSync();
      } catch (e) {
        _adoptLog('Stage1_Discovery', {
          'browser': config.name,
          'error': 'ACCESS_DENIED_SANDBOX',
          'type': e.runtimeType.toString(),
        });
        continue;
      }

      if (!exists) continue;

      final profilesToCheck = <Directory>[];

      // Default profile
      final defaultDir = Directory('${userDir.path}/Default');
      if (defaultDir.existsSync()) {
        profilesToCheck.add(defaultDir);
      }

      // Profile 1, Profile 2, etc.
      try {
        for (final entity in userDir.listSync()) {
          if (entity is Directory) {
            final basename = entity.path.split('/').last;
            if (basename.startsWith('Profile ') && basename != 'Default') {
              profilesToCheck.add(entity);
            }
          }
        }
      } catch (_) {}

      for (final pDir in profilesToCheck) {
        final profileName = pDir.path.split('/').last;

        // Modern Chromium: <profile>/Network/Cookies, Legacy/Arc: <profile>/Cookies
        String? validCookiesPath;
        for (final candidate in [
          '${pDir.path}/Cookies',
          '${pDir.path}/Network/Cookies',
        ]) {
          try {
            if (File(candidate).existsSync()) {
              validCookiesPath = candidate;
              break;
            }
          } catch (_) {}
        }

        if (validCookiesPath != null) {
          discovered.add(BrowserProfile(
            browserId: config.id,
            browserName: config.name,
            profileName: profileName,
            profilePath: pDir.path,
            cookiesPath: validCookiesPath,
          ));
        }
      }
    }

    _adoptLog('Stage1_Discovery', {
      'discoveredCount': discovered.length,
      'profiles': discovered.map((p) => p.displayName).toList(),
    });

    return discovered;
  }

  /// Stage 3: Retrieves Chromium Safe Storage password from macOS Keychain.
  ///
  /// Throws [AdoptDecryptionException] when the password cannot be read.
  /// macOS Chromium browsers always derive their cookie key from this
  /// Keychain item, so guessing a default password would only yield a wrong
  /// key and silently undecryptable cookies.
  static Future<String> getSafeStoragePassword(BrowserProfile profile) async {
    _BrowserConfig? config;
    for (final c in _supportedBrowsers) {
      if (c.id == profile.browserId) {
        config = c;
        break;
      }
    }
    if (config == null) {
      throw AdoptDecryptionException(
          'Unsupported browser: ${profile.browserName}');
    }

    try {
      final res = await Process.run('/usr/bin/security', [
        'find-generic-password',
        '-w',
        '-s',
        config.keychainService,
        '-a',
        config.keychainAccount,
      ]);

      final pw = res.exitCode == 0 ? (res.stdout as String).trim() : '';
      _adoptLog('Stage3_Keychain', {
        'browser': config.name,
        'service': config.keychainService,
        'exitCode': res.exitCode,
        'hasPassword': pw.isNotEmpty,
      });
      if (pw.isNotEmpty) return pw;
      throw AdoptDecryptionException(
        'Could not read "${config.keychainService}" from the macOS Keychain '
        '(exit code ${res.exitCode}). If a Keychain prompt appeared, choose '
        '"Allow" or "Always Allow", then try again.',
      );
    } on AdoptException {
      rethrow;
    } catch (e) {
      _adoptLog('Stage3_Keychain', {
        'browser': config.name,
        'error': e.runtimeType.toString(),
      });
      throw AdoptDecryptionException(
          'Could not run the macOS Keychain lookup (${e.runtimeType}).');
    }
  }

  /// Runs the full 6-stage adoption flow for a selected [profile].
  static Future<String> adoptCookies(BrowserProfile profile) async {
    _adoptLog('Stage0_Initiate', {'profile': profile.displayName});

    // Stage 2: Database access
    final srcCookieFile = File(profile.cookiesPath);
    if (!srcCookieFile.existsSync()) {
      _adoptLog('Stage2_DbAccess', {'error': 'FILE_NOT_FOUND', 'path': profile.cookiesPath});
      throw AdoptNotFoundException('Cookie database not found at ${profile.cookiesPath}');
    }

    int fileSize = 0;
    try {
      fileSize = srcCookieFile.lengthSync();
    } on FileSystemException catch (e) {
      _adoptLog('Stage2_DbAccess', {'error': 'EPERM_SANDBOX', 'osError': e.osError?.message});
      throw AdoptPermissionException(
        'Cannot access browser database due to macOS sandbox restrictions.\n'
        'Please use "Import cookies" to paste session cookies or load a cookies.txt file.',
      );
    }

    _adoptLog('Stage2_DbAccess', {'sizeBytes': fileSize, 'readable': true});

    // Create temp copy to avoid active browser locks
    final tempDir = Directory.systemTemp.createTempSync('lw_adopt_');
    final tempDb = File('${tempDir.path}/Cookies');

    try {
      srcCookieFile.copySync(tempDb.path);

      // Copy -wal and -shm if present
      final wal = File('${srcCookieFile.path}-wal');
      if (wal.existsSync()) wal.copySync('${tempDb.path}-wal');
      final shm = File('${srcCookieFile.path}-shm');
      if (shm.existsSync()) shm.copySync('${tempDb.path}-shm');
    } catch (e) {
      tempDir.deleteSync(recursive: true);
      _adoptLog('Stage2_DbAccess', {'error': 'COPY_FAILED', 'type': e.runtimeType.toString()});
      throw AdoptPermissionException('Failed to copy cookie database: $e');
    }

    try {
      // Stage 3: Keychain access
      final password = await getSafeStoragePassword(profile);

      // Stage 4: Key derivation & Decryption
      final key = deriveChromiumKey(password);
      _adoptLog('Stage4_Decryption', {'keyDerived': true, 'keyBytes': key.length});

      final read = _readAndDecryptCookies(tempDb, key);
      _adoptLog('Stage4_Decryption', {
        'metaVersion': read.metaVersion ?? 'unknown',
        'extractedCount': read.cookies.length,
        'encryptedSeen': read.encryptedSeen,
        'decryptFailed': read.decryptFailed,
        'hashMismatch': read.hashMismatch,
        'names': read.cookies.keys.toList(),
      });

      // Stage 4 validation
      final String cookieHeader;
      try {
        cookieHeader = filterAndFormatCookies(read.cookies);
      } on AdoptValidationException {
        // Missing auth cookies *because* decryption failed is a
        // decryption problem, not a "you are signed out" problem.
        if (read.decryptFailed > 0) {
          final String reason;
          if (read.metaVersion == null) {
            reason = 'The cookie database version could not be read, so '
                'the cookies were not decrypted.';
          } else if (read.hashMismatch > 0) {
            reason = '${read.hashMismatch} cookies failed the host integrity '
                'check (wrong key or an unexpected database format).';
          } else {
            reason = 'Make sure "${profile.browserName} Safe Storage" access '
                'was allowed in the macOS Keychain prompt, then try again.';
          }
          throw AdoptDecryptionException(
            'Could not decrypt ${read.decryptFailed} of ${read.encryptedSeen} '
            'browser cookies, so no usable session was found. $reason',
          );
        }
        rethrow;
      }
      _adoptLog('Stage4_Validation', {'success': true, 'headerLength': cookieHeader.length});

      return cookieHeader;
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  static CookieReadResult _readAndDecryptCookies(
      File dbFile, Uint8List key) {
    final db = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
    try {
      return readCookiesFromDatabase(db, key);
    } finally {
      db.dispose();
    }
  }

  @visibleForTesting
  static String filterAndFormatCookies(Map<String, String> cookies) {
    const sapisidKeys = ['__Secure-3PAPISID', 'SAPISID', 'APISID'];
    const loginMarkers = ['LOGIN_INFO', 'SID', '__Secure-3PSID', '__Secure-1PSID'];

    final hasSapisid = sapisidKeys.any(cookies.containsKey);
    final hasLogin = loginMarkers.any(cookies.containsKey);

    if (!hasSapisid) {
      throw const AdoptValidationException(
        'No SAPISID found in browser session. Please make sure you are signed in to music.youtube.com in your browser.',
      );
    }
    if (!hasLogin) {
      throw const AdoptValidationException(
        'Session is incomplete (missing login markers). Please sign in to music.youtube.com in your browser.',
      );
    }

    final names = cookies.keys.toList()..sort();
    return names.map((n) => '$n=${cookies[n]}').join('; ');
  }
}
