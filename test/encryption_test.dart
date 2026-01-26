import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/services/encryption_service.dart';
import 'package:nfc_archiver/core/services/compression_service.dart';

void main() {
  group('EncryptionService', () {
    late EncryptionService service;

    setUp(() {
      service = EncryptionService.instance;
    });

    test('encrypt and decrypt with simple password works', () {
      final originalData = Uint8List.fromList(
        List.generate(100, (i) => i % 256),
      );

      // Encrypt
      final encrypted = service.encrypt(originalData, 'password');
      print('Original size: ${originalData.length}');
      print('Encrypted size: ${encrypted.length}');
      print('Expected overhead: ${EncryptionService.encryptionOverhead}');

      // Verify size
      expect(
        encrypted.length,
        equals(originalData.length + EncryptionService.encryptionOverhead),
      );

      // Decrypt
      final decrypted = service.decrypt(encrypted, 'password');
      print('Decrypted size: ${decrypted.length}');

      expect(decrypted, equals(originalData));
    });

    test('encrypt and decrypt with special characters password', () {
      final originalData = Uint8List.fromList([1, 2, 3, 4, 5]);
      const password = 'P@ssw0rd!#\$%^&*()';

      final encrypted = service.encrypt(originalData, password);
      final decrypted = service.decrypt(encrypted, password);

      expect(decrypted, equals(originalData));
    });

    test('wrong password fails authentication', () {
      final originalData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

      final encrypted = service.encrypt(originalData, 'password');

      expect(
        () => service.decrypt(encrypted, 'wrongpassword'),
        throwsArgumentError,
      );
    });

    test('password with spaces is trimmed', () {
      final originalData = Uint8List.fromList([1, 2, 3, 4, 5]);

      // Encrypt with trimmed password
      final encrypted = service.encrypt(originalData, '  password  ');

      // Should decrypt with trimmed version
      final decrypted = service.decrypt(encrypted, 'password');
      expect(decrypted, equals(originalData));

      // Should also work with spaces (they get trimmed)
      final decrypted2 = service.decrypt(encrypted, '  password  ');
      expect(decrypted2, equals(originalData));
    });
  });

  group('Compression + Encryption flow', () {
    test('compress then encrypt, decrypt then decompress', () {
      final compressionService = CompressionService.instance;
      final encryptionService = EncryptionService.instance;

      // Original data (compressible)
      final originalData = Uint8List.fromList(
        List.generate(1000, (i) => i % 10), // Repetitive = compressible
      );
      print('Original size: ${originalData.length}');

      // Step 1: Compress
      final compressed = compressionService.compress(originalData);
      print('Compressed size: ${compressed.length}');

      // Step 2: Encrypt
      final encrypted = encryptionService.encrypt(compressed, 'password');
      print('Encrypted size: ${encrypted.length}');

      // Step 3: Decrypt
      final decrypted = encryptionService.decrypt(encrypted, 'password');
      print('Decrypted size: ${decrypted.length}');
      expect(decrypted, equals(compressed));

      // Step 4: Decompress
      final decompressed = compressionService.decompress(decrypted);
      print('Decompressed size: ${decompressed.length}');

      expect(decompressed, equals(originalData));
    });
  });
}
