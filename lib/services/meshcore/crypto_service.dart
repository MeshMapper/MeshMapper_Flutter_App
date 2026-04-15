import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import '../../utils/debug_logger_io.dart';

/// Cryptographic operations for MeshCore channel management
/// Ported from wardrive.js channel crypto functions
class CryptoService {
  /// Fixed key for "Public" channel (non-hashtag channels)
  /// From MeshCore default: 8b3387e9c5cdea6ac9e5edbaa115cd72
  static final Uint8List publicChannelFixedKey = Uint8List.fromList([
    0x8b,
    0x33,
    0x87,
    0xe9,
    0xc5,
    0xcd,
    0xea,
    0x6a,
    0xc9,
    0xe5,
    0xed,
    0xba,
    0xa1,
    0x15,
    0xcd,
    0x72,
  ]);

  /// Derive a 16-byte channel key from a channel name using SHA-256
  ///
  /// Matches JS implementation: `sha256(channelName).subarray(0, 16)`
  ///
  /// @param channelName - Channel name (must start with # for hashtag channels)
  /// @returns 16-byte channel key
  /// @throws FormatException if channel name is invalid
  static Uint8List deriveChannelKey(String channelName) {
    debugLog('[CRYPTO] Deriving channel key for: $channelName');

    // Validate channel name format: must start with # and contain only letters, numbers, and dashes
    if (!channelName.startsWith('#')) {
      throw FormatException(
          'Channel name must start with # (got: "$channelName")');
    }

    // Normalize channel name to lowercase (MeshCore convention)
    final normalizedName = channelName.toLowerCase();

    // Check that the part after # contains only letters, numbers, and dashes
    final nameWithoutHash = normalizedName.substring(1);
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(nameWithoutHash)) {
      throw FormatException(
        'Channel name "$channelName" contains invalid characters. '
        'Only letters, numbers, and dashes are allowed.',
      );
    }

    // Hash using SHA-256
    final bytes = utf8.encode(normalizedName);
    final digest = sha256.convert(bytes);

    // Take the first 16 bytes of the hash as the channel key
    final channelKey = Uint8List.fromList(digest.bytes.sublist(0, 16));

    debugLog(
        '[CRYPTO] Channel key derived successfully (${channelKey.length} bytes)');

    return channelKey;
  }

  /// Derive a 16-byte TransportKey from a scope/region name
  /// Same algorithm as channel key derivation: SHA-256(name)[0:16]
  /// API returns names without '#' prefix (e.g., "ottawa") — we prepend it
  /// to match MeshCore's implicit hashtag region convention
  static Uint8List deriveScopeKey(String scopeName) {
    final name = scopeName.startsWith('#') ? scopeName : '#$scopeName';
    final normalizedName = name.toLowerCase();
    final bytes = utf8.encode(normalizedName);
    final digest = sha256.convert(bytes);
    final scopeKey = Uint8List.fromList(digest.bytes.sublist(0, 16));
    debugLog(
        '[CRYPTO] Scope key derived for "$normalizedName" (${scopeKey.length} bytes)');
    return scopeKey;
  }

  /// Get channel key for any channel (handles both Public and hashtag channels)
  ///
  /// @param channelName - Channel name (e.g., "Public", "#wardriving", "#testing")
  /// @returns 16-byte channel key
  static Uint8List getChannelKey(String channelName) {
    if (channelName == 'Public') {
      debugLog('[CRYPTO] Using fixed key for Public channel');
      return publicChannelFixedKey;
    } else {
      return deriveChannelKey(channelName);
    }
  }

  /// Compute channel hash from channel secret (first byte of SHA-256)
  ///
  /// Used for identifying echo packets that match our channel
  ///
  /// @param channelSecret - The 16-byte channel secret
  /// @returns Channel hash (first byte of SHA-256)
  static int computeChannelHash(Uint8List channelSecret) {
    final digest = sha256.convert(channelSecret);
    return digest.bytes[0];
  }

  /// Decrypt channel message using AES-ECB mode
  ///
  /// MeshCore uses AES-128-ECB for channel message encryption
  ///
  /// @param encryptedPayload - The encrypted message bytes
  /// @param channelKey - The 16-byte channel key
  /// @returns Decrypted message bytes
  static Uint8List decryptChannelMessage(
    Uint8List encryptedPayload,
    Uint8List channelKey,
  ) {
    debugLog('[CRYPTO] Decrypting message (${encryptedPayload.length} bytes)');

    if (channelKey.length != 16) {
      throw ArgumentError(
          'Channel key must be 16 bytes (got ${channelKey.length})');
    }

    try {
      // Create AES cipher in ECB mode
      final cipher = ECBBlockCipher(AESEngine());
      final params = KeyParameter(channelKey);
      cipher.init(false, params); // false = decrypt mode

      // Decrypt the payload
      final decrypted = Uint8List(encryptedPayload.length);
      var offset = 0;

      while (offset < encryptedPayload.length) {
        cipher.processBlock(encryptedPayload, offset, decrypted, offset);
        offset += cipher.blockSize;
      }

      // Note: MeshCore doesn't use PKCS7 padding, so we return the raw decrypted data.
      // The caller is responsible for parsing the message structure:
      // [4 bytes timestamp][1 byte flags][message text]
      debugLog('[CRYPTO] Decrypted successfully (${decrypted.length} bytes)');
      return decrypted;
    } catch (e) {
      debugError('[CRYPTO] Decryption failed: $e');
      rethrow;
    }
  }

  /// Encrypt channel message using AES-ECB mode
  ///
  /// @param plaintext - The message bytes to encrypt
  /// @param channelKey - The 16-byte channel key
  /// @returns Encrypted message bytes
  static Uint8List encryptChannelMessage(
    Uint8List plaintext,
    Uint8List channelKey,
  ) {
    debugLog('[CRYPTO] Encrypting message (${plaintext.length} bytes)');

    if (channelKey.length != 16) {
      throw ArgumentError(
          'Channel key must be 16 bytes (got ${channelKey.length})');
    }

    try {
      // Add PKCS7 padding
      final padded = _addPkcs7Padding(plaintext, 16);

      // Create AES cipher in ECB mode
      final cipher = ECBBlockCipher(AESEngine());
      final params = KeyParameter(channelKey);
      cipher.init(true, params); // true = encrypt mode

      // Encrypt the payload
      final encrypted = Uint8List(padded.length);
      var offset = 0;

      while (offset < padded.length) {
        cipher.processBlock(padded, offset, encrypted, offset);
        offset += cipher.blockSize;
      }

      debugLog('[CRYPTO] Encrypted successfully (${encrypted.length} bytes)');
      return encrypted;
    } catch (e) {
      debugError('[CRYPTO] Encryption failed: $e');
      rethrow;
    }
  }

  /// Add PKCS7 padding to data
  static Uint8List _addPkcs7Padding(Uint8List data, int blockSize) {
    final paddingLength = blockSize - (data.length % blockSize);
    final padded = Uint8List(data.length + paddingLength);
    padded.setRange(0, data.length, data);
    for (var i = data.length; i < padded.length; i++) {
      padded[i] = paddingLength;
    }
    return padded;
  }

  /// Parse channel message to extract text content
  ///
  /// Decrypts and decodes the message, returning the text if printable
  ///
  /// @param encryptedPayload - The encrypted message bytes
  /// @param channelKey - The 16-byte channel key
  /// @returns Decoded text or null if not printable
  static String? parseChannelMessage(
    Uint8List encryptedPayload,
    Uint8List channelKey,
  ) {
    try {
      final decrypted = decryptChannelMessage(encryptedPayload, channelKey);
      final text = utf8.decode(decrypted, allowMalformed: true);

      // Check if text is printable (contains mostly ASCII printable characters)
      final printableCount =
          text.codeUnits.where((c) => c >= 32 && c <= 126).length;
      final printableRatio = printableCount / text.length;

      if (printableRatio > 0.8) {
        return text;
      } else {
        debugWarn(
            '[CRYPTO] Message not printable (${(printableRatio * 100).toStringAsFixed(1)}% printable)');
        return null;
      }
    } catch (e) {
      debugError('[CRYPTO] Failed to parse message: $e');
      return null;
    }
  }
}
