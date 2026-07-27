/**
 * AES-256-GCM with PBKDF2-HMAC-SHA256 key derivation via Web Crypto.
 * Blob layout matches lib/core/services/encryption_service.dart:
 *   salt(16) | iv(12) | ciphertext | tag(16)
 * (SubtleCrypto appends the GCM tag to the ciphertext, which is exactly
 * this layout — no rearranging needed.)
 */

const SALT_SIZE = 16;
const IV_SIZE = 12;
const TAG_SIZE = 16;
const PBKDF2_ITERATIONS = 100000;

export const ENCRYPTION_OVERHEAD = SALT_SIZE + IV_SIZE + TAG_SIZE;

export class DecryptionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DecryptionError';
  }
}

async function deriveKey(password: string, salt: Uint8Array): Promise<CryptoKey> {
  // The Dart implementation trims the password before UTF-8 encoding.
  // Note: JS `trim()` and Dart `trim()` differ on U+0085 (NEL), which Dart
  // trims and JS does not — irrelevant for real passwords, documented here
  // for byte-compat completeness.
  const material = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(password.trim()),
    'PBKDF2',
    false,
    ['deriveKey'],
  );
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt: salt as BufferSource, iterations: PBKDF2_ITERATIONS, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

export async function encrypt(data: Uint8Array, password: string): Promise<Uint8Array> {
  const salt = crypto.getRandomValues(new Uint8Array(SALT_SIZE));
  const iv = crypto.getRandomValues(new Uint8Array(IV_SIZE));
  const key = await deriveKey(password, salt);
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv as BufferSource, tagLength: TAG_SIZE * 8 }, key, data as BufferSource),
  );
  const out = new Uint8Array(SALT_SIZE + IV_SIZE + ciphertext.length);
  out.set(salt, 0);
  out.set(iv, SALT_SIZE);
  out.set(ciphertext, SALT_SIZE + IV_SIZE);
  return out;
}

export async function decrypt(blob: Uint8Array, password: string): Promise<Uint8Array> {
  if (blob.length < ENCRYPTION_OVERHEAD) {
    throw new DecryptionError(
      `Data too short to be encrypted: ${blob.length} bytes (minimum: ${ENCRYPTION_OVERHEAD})`,
    );
  }
  const salt = blob.subarray(0, SALT_SIZE);
  const iv = blob.subarray(SALT_SIZE, SALT_SIZE + IV_SIZE);
  const ciphertext = blob.subarray(SALT_SIZE + IV_SIZE);
  const key = await deriveKey(password, salt);
  try {
    return new Uint8Array(
      await crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv as BufferSource, tagLength: TAG_SIZE * 8 }, key, ciphertext as BufferSource),
    );
  } catch {
    throw new DecryptionError('Decryption failed: wrong password or corrupted data');
  }
}
