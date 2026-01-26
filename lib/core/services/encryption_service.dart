import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Service for encrypting and decrypting data using AES-256-GCM.
///
/// Key derivation uses PBKDF2 with SHA-256.
///
/// Encrypted data format:
/// ```
/// ┌─────────────────────────────────────────────────────┐
/// │ Salt (16 bytes): random salt for key derivation     │
/// ├─────────────────────────────────────────────────────┤
/// │ IV/Nonce (12 bytes): random initialization vector   │
/// ├─────────────────────────────────────────────────────┤
/// │ Ciphertext (N bytes): AES-256-GCM encrypted data    │
/// ├─────────────────────────────────────────────────────┤
/// │ Auth Tag (16 bytes): GCM authentication tag         │
/// └─────────────────────────────────────────────────────┘
/// ```
class EncryptionService {
  /// Singleton instance
  static final EncryptionService instance = EncryptionService._();

  EncryptionService._();

  /// Salt size in bytes
  static const int saltSize = 16;

  /// IV/Nonce size in bytes (GCM standard)
  static const int ivSize = 12;

  /// Authentication tag size in bytes
  static const int tagSize = 16;

  /// Key size in bytes (256 bits)
  static const int keySize = 32;

  /// PBKDF2 iteration count
  static const int pbkdf2Iterations = 100000;

  /// Overhead added to data when encrypting
  static const int encryptionOverhead = saltSize + ivSize + tagSize;

  final _secureRandom = _createSecureRandom();

  /// Encrypt data with a password.
  ///
  /// Returns the encrypted data with salt, IV, and auth tag prepended/appended.
  Uint8List encrypt(Uint8List data, String password) {
    // Trim password to avoid whitespace issues
    final trimmedPassword = password.trim();

    // Generate random salt and IV
    final salt = _generateRandomBytes(saltSize);
    final iv = _generateRandomBytes(ivSize);

    // Derive key from password
    final key = _deriveKey(trimmedPassword, salt);

    // Create AES-GCM cipher
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true, // encrypt
        AEADParameters(
          KeyParameter(key),
          tagSize * 8, // tag length in bits
          iv,
          Uint8List(0), // no additional authenticated data
        ),
      );

    // Encrypt
    final ciphertextBuffer = Uint8List(cipher.getOutputSize(data.length));
    var ciphertextLen = cipher.processBytes(data, 0, data.length, ciphertextBuffer, 0);
    ciphertextLen += cipher.doFinal(ciphertextBuffer, ciphertextLen);

    // IMPORTANT: Only use the actual written bytes, not the entire buffer!
    // getOutputSize() over-estimates, but doFinal returns the actual length.
    final ciphertext = Uint8List.sublistView(ciphertextBuffer, 0, ciphertextLen);

    // Combine: salt + iv + ciphertext (includes tag)
    final result = Uint8List(saltSize + ivSize + ciphertext.length);
    result.setRange(0, saltSize, salt);
    result.setRange(saltSize, saltSize + ivSize, iv);
    result.setRange(saltSize + ivSize, result.length, ciphertext);

    return result;
  }

  /// Decrypt data with a password.
  ///
  /// Throws [ArgumentError] if the data is invalid or password is wrong.
  Uint8List decrypt(Uint8List encryptedData, String password) {
    if (encryptedData.length < encryptionOverhead) {
      throw ArgumentError(
        'Data too short to be encrypted: ${encryptedData.length} bytes '
        '(minimum: $encryptionOverhead)',
      );
    }

    // Trim password to avoid whitespace issues
    final trimmedPassword = password.trim();

    // Extract salt, IV, and ciphertext
    final salt = Uint8List.sublistView(encryptedData, 0, saltSize);
    final iv = Uint8List.sublistView(encryptedData, saltSize, saltSize + ivSize);
    final ciphertext = Uint8List.sublistView(encryptedData, saltSize + ivSize);

    // Derive key from password
    final key = _deriveKey(trimmedPassword, salt);

    // Create AES-GCM cipher
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false, // decrypt
        AEADParameters(
          KeyParameter(key),
          tagSize * 8,
          iv,
          Uint8List(0),
        ),
      );

    // Decrypt
    try {
      final plaintextBuffer = Uint8List(cipher.getOutputSize(ciphertext.length));
      var plaintextLen = cipher.processBytes(
        ciphertext,
        0,
        ciphertext.length,
        plaintextBuffer,
        0,
      );
      plaintextLen += cipher.doFinal(plaintextBuffer, plaintextLen);

      // Use actual length from doFinal, not calculated estimate
      return Uint8List.sublistView(plaintextBuffer, 0, plaintextLen);
    } catch (e) {
      throw ArgumentError(
        'Decryption failed: wrong password or corrupted data. '
        'Data size: ${encryptedData.length}, ciphertext: ${ciphertext.length}, '
        'password length: ${trimmedPassword.length}',
      );
    }
  }

  /// Try to decrypt data, returning null if it fails.
  Uint8List? tryDecrypt(Uint8List encryptedData, String password) {
    try {
      return decrypt(encryptedData, password);
    } catch (_) {
      return null;
    }
  }

  /// Derive a key from password using PBKDF2.
  Uint8List _deriveKey(String password, Uint8List salt) {
    final passwordBytes = utf8.encode(password);

    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, pbkdf2Iterations, keySize));

    return pbkdf2.process(Uint8List.fromList(passwordBytes));
  }

  /// Generate random bytes.
  Uint8List _generateRandomBytes(int length) {
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = _secureRandom.nextUint8();
    }
    return bytes;
  }

  /// Create a secure random number generator.
  static SecureRandom _createSecureRandom() {
    final secureRandom = FortunaRandom();
    final random = Random.secure();
    final seeds = List<int>.generate(32, (_) => random.nextInt(256));
    secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));
    return secureRandom;
  }

  /// Calculate encrypted size for given plaintext size.
  int encryptedSize(int plaintextSize) {
    // GCM adds 16-byte tag, we also prepend salt and IV
    return plaintextSize + encryptionOverhead;
  }

  /// Calculate plaintext size from encrypted size.
  int plaintextSize(int encryptedSize) {
    return encryptedSize - encryptionOverhead;
  }

  /// Validate password strength.
  PasswordStrength validatePassword(String password) {
    if (password.length < 8) {
      return PasswordStrength.weak;
    }

    bool hasLower = password.contains(RegExp(r'[a-z]'));
    bool hasUpper = password.contains(RegExp(r'[A-Z]'));
    bool hasDigit = password.contains(RegExp(r'[0-9]'));
    bool hasSpecial = password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));

    int score = 0;
    if (hasLower) score++;
    if (hasUpper) score++;
    if (hasDigit) score++;
    if (hasSpecial) score++;
    if (password.length >= 12) score++;
    if (password.length >= 16) score++;

    if (score >= 5) return PasswordStrength.strong;
    if (score >= 3) return PasswordStrength.medium;
    return PasswordStrength.weak;
  }
}

/// Password strength levels.
enum PasswordStrength {
  weak,
  medium,
  strong,
}

/// Extension for convenience
extension EncryptionExtension on Uint8List {
  /// Encrypt this data with a password.
  Uint8List encryptWithPassword(String password) =>
      EncryptionService.instance.encrypt(this, password);

  /// Decrypt this data with a password.
  Uint8List decryptWithPassword(String password) =>
      EncryptionService.instance.decrypt(this, password);
}
