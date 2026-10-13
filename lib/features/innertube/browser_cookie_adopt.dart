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

import 'package:crypto/crypto.dart' show Hmac, sha1;
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
// Main Adoption Logic
// ---------------------------------------------------------------------------

class BrowserSessionAdopt {
  BrowserSessionAdopt._();

  static const _v10Prefix = [0x76, 0x31, 0x30]; // "v10"

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
  static Future<String> getSafeStoragePassword(BrowserProfile profile) async {
    _BrowserConfig? config;
    for (final c in _supportedBrowsers) {
      if (c.id == profile.browserId) {
        config = c;
        break;
      }
    }
    if (config == null) return 'peanuts';

    try {
      final res = await Process.run('/usr/bin/security', [
        'find-generic-password',
        '-w',
        '-s',
        config.keychainService,
        '-a',
        config.keychainAccount,
      ]);

      if (res.exitCode == 0) {
        final pw = (res.stdout as String).trim();
        _adoptLog('Stage3_Keychain', {
          'browser': config.name,
          'service': config.keychainService,
          'exitCode': 0,
          'hasPassword': pw.isNotEmpty,
        });
        if (pw.isNotEmpty) return pw;
      } else {
        _adoptLog('Stage3_Keychain', {
          'browser': config.name,
          'service': config.keychainService,
          'exitCode': res.exitCode,
          'status': 'FALLBACK_TO_DEFAULT',
        });
      }
    } catch (e) {
      _adoptLog('Stage3_Keychain', {
        'browser': config.name,
        'error': e.runtimeType.toString(),
        'status': 'FALLBACK_TO_DEFAULT',
      });
    }

    // Chromium default fallback password on macOS/Linux
    return 'peanuts';
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

      final rawCookies = _readAndDecryptCookies(tempDb, key);
      _adoptLog('Stage4_Decryption', {
        'extractedCount': rawCookies.length,
        'names': rawCookies.keys.toList(),
      });

      // Stage 4 validation
      final cookieHeader = _filterAndFormatCookies(rawCookies);
      _adoptLog('Stage4_Validation', {'success': true, 'headerLength': cookieHeader.length});

      return cookieHeader;
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  static Map<String, String> _readAndDecryptCookies(File dbFile, Uint8List key) {
    final db = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
    final results = <String, String>{};

    // Domain specificity map: keeps track of domain rank per cookie name
    // rank: 3 = music.youtube.com, 2 = .youtube.com, 1 = .google.com
    final rankMap = <String, int>{};

    try {
      final rows = db.select(
        'SELECT host_key, name, value, encrypted_value '
        'FROM cookies '
        'WHERE host_key LIKE "%youtube.com" OR host_key LIKE "%google.com"',
      );

      for (final row in rows) {
        final hostKey = (row['host_key'] as String? ?? '').toLowerCase();
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

        // If we already have this cookie from a higher or equal rank domain, skip
        final currentRank = rankMap[name] ?? 0;
        if (currentRank > rank) continue;

        String? val = row['value'] as String?;
        if (val == null || val.isEmpty) {
          final encBlob = row['encrypted_value'];
          if (encBlob is Uint8List && encBlob.length > 3) {
            // Check v10 prefix
            if (encBlob[0] == _v10Prefix[0] &&
                encBlob[1] == _v10Prefix[1] &&
                encBlob[2] == _v10Prefix[2]) {
              final ciphertext = encBlob.sublist(3);
              final decrypted = _CommonCrypto.decryptAes128Cbc(key, ciphertext);
              if (decrypted != null) {
                val = utf8.decode(decrypted, allowMalformed: true).trim();
              }
            }
          }
        }

        if (val != null && val.isNotEmpty) {
          results[name] = val;
          rankMap[name] = rank;
        }
      }
    } finally {
      db.dispose();
    }

    return results;
  }

  static String _filterAndFormatCookies(Map<String, String> cookies) {
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
