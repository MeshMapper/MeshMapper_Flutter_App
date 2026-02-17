# French Encryption Declaration for MeshMapper

## ANSSI Declaration Information

This document provides the technical details required for the French encryption declaration (Déclaration de fourniture de moyens de cryptologie) to ANSSI.

---

## Application Information

- **Application Name**: MeshMapper
- **Version**: 1.0.0
- **Publisher**: [Your Company/Name]
- **Platform**: iOS (also Android, Web)
- **Distribution**: Apple App Store (France included)

---

## Encryption Summary

### Encryption Category: **Exempt (Category 1)**

This application qualifies for exemption under French cryptography regulations because:

1. **Standard, publicly available algorithms** - Uses only SHA-256 and AES-128, which are standard cryptographic primitives widely available in open-source libraries.

2. **Ancillary cryptographic functionality** - Encryption is not the primary purpose of the application. The app's primary function is GPS-based mesh network coverage mapping.

3. **No user-to-user encrypted communication** - The app does not provide end-to-end encrypted messaging between users. Encryption is used solely for protocol compatibility with mesh network hardware.

4. **Authentication and data integrity** - Cryptography is used primarily for channel identification and message verification, not for confidentiality of user communications.

---

## Cryptographic Functions Used

### 1. SHA-256 (Secure Hash Algorithm)

| Property | Value |
|----------|-------|
| **Algorithm** | SHA-256 |
| **Key Length** | N/A (hash function) |
| **Output Length** | 256 bits |
| **Library** | `crypto` package (Dart) v3.0.7 |
| **Purpose** | Channel key derivation and channel identification |

**Usage Details**:
- Derives a 16-byte channel key from channel names (e.g., "#wardriving")
- Computes a 1-byte channel hash for packet identification
- Standard implementation with no modifications

**Code Location**: `lib/services/meshcore/crypto_service.dart`

```dart
// Channel key derivation
final bytes = utf8.encode(channelName);
final digest = sha256.convert(bytes);
final channelKey = digest.bytes.sublist(0, 16);

// Channel hash computation
final hash = sha256.convert(channelSecret).bytes[0];
```

### 2. AES-128-ECB (Advanced Encryption Standard)

| Property | Value |
|----------|-------|
| **Algorithm** | AES |
| **Mode** | ECB (Electronic Codebook) |
| **Key Length** | 128 bits (16 bytes) |
| **Block Size** | 128 bits |
| **Library** | `pointycastle` package v4.0.0 |
| **Purpose** | Mesh network protocol message decryption |

**Usage Details**:
- Decrypts incoming mesh network packets for channel verification
- Encrypts outgoing messages for mesh network protocol compatibility
- Required for interoperability with MeshCore mesh network devices
- Uses standard PKCS7 padding

**Code Location**: `lib/services/meshcore/crypto_service.dart`

```dart
// AES-ECB decryption
final cipher = ECBBlockCipher(AESEngine());
final params = KeyParameter(channelKey);
cipher.init(false, params); // false = decrypt mode
```

---

## Cryptographic Libraries

| Library | Version | Source | License |
|---------|---------|--------|---------|
| `crypto` | 3.0.7 | pub.dev (Dart official) | BSD-3-Clause |
| `pointycastle` | 4.0.0 | pub.dev (open source) | MIT |

Both libraries are:
- Open source with publicly available source code
- Widely used in the Dart/Flutter ecosystem
- Implement standard, unmodified cryptographic algorithms
- Available for download without restriction

---

## Purpose of Encryption

### Primary Application Function
MeshMapper is a **wardriving application** for mapping mesh network coverage. Users connect to MeshCore mesh network devices via Bluetooth Low Energy (BLE) and record GPS coordinates where mesh network signals are detected.

### Why Encryption is Required
The MeshCore mesh network protocol uses channel-based encryption for:

1. **Channel Identification**: Each mesh network channel has a unique cryptographic hash derived from the channel name. This allows the app to identify which channel a received packet belongs to.

2. **Message Verification**: Decrypting messages verifies that they came from devices on the same channel and were not corrupted in transit.

3. **Protocol Compatibility**: The encryption is part of the MeshCore companion protocol specification. Without it, the app cannot communicate with MeshCore devices.

### What Encryption is NOT Used For
- ❌ End-to-end encrypted messaging between users
- ❌ Protecting user personal data at rest
- ❌ Secure communication with remote servers (HTTPS is separate)
- ❌ Digital signatures or non-repudiation
- ❌ Any purpose other than mesh network protocol compatibility

---

## Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    MeshMapper App                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Channel Setup                                           │
│     ┌──────────────┐     SHA-256      ┌──────────────┐     │
│     │ Channel Name │ ───────────────► │ Channel Key  │     │
│     │ "#wardriving"│                  │ (16 bytes)   │     │
│     └──────────────┘                  └──────────────┘     │
│                                                             │
│  2. Receive Mesh Packet                                     │
│     ┌──────────────┐     AES-ECB      ┌──────────────┐     │
│     │  Encrypted   │ ───────────────► │  Decrypted   │     │
│     │   Packet     │   (decrypt)      │   Message    │     │
│     └──────────────┘                  └──────────────┘     │
│                                              │              │
│                                              ▼              │
│                                       ┌──────────────┐     │
│                                       │   Verify     │     │
│                                       │   Channel    │     │
│                                       └──────────────┘     │
│                                                             │
│  3. Send Ping Message                                       │
│     ┌──────────────┐     AES-ECB      ┌──────────────┐     │
│     │  Plaintext   │ ───────────────► │  Encrypted   │     │
│     │   Message    │   (encrypt)      │   Packet     │     │
│     └──────────────┘                  └──────────────┘     │
│                                              │              │
│                                              ▼              │
│                                       ┌──────────────┐     │
│                                       │  BLE Send    │     │
│                                       │  to Device   │     │
│                                       └──────────────┘     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Exemption Justification

Under French regulations (Decree No. 2007-663), this application qualifies for **Category 1 exemption** because:

### Criteria Met:

| Criterion | Status | Explanation |
|-----------|--------|-------------|
| Uses standard algorithms | ✅ | SHA-256 and AES-128 only |
| Algorithms publicly available | ✅ | Open source libraries |
| No proprietary encryption | ✅ | No custom cryptographic code |
| Ancillary to main function | ✅ | Main function is GPS mapping |
| Key length ≤ 128 bits | ✅ | AES-128 (128-bit keys) |
| No user encryption keys | ✅ | Keys derived from public channel names |

### Category 1 Declaration Requirements:

For exempt products, a simple declaration is required rather than full authorization. The declaration should include:
- Product name and version
- Cryptographic functions used
- Purpose of encryption
- Confirmation that encryption is ancillary

---

## ANSSI Submission Checklist

- [ ] Complete "Formulaire de déclaration" (Declaration Form)
- [ ] Attach this technical document
- [ ] Include screenshots of the app
- [ ] Provide company/developer identification
- [ ] Submit via ANSSI online portal or mail

**ANSSI Contact**:
- Website: https://www.ssi.gouv.fr/
- Portal: https://www.ssi.gouv.fr/entreprise/reglementation/controle-reglementaire-sur-la-cryptographie/
- Email: crypto@ssi.gouv.fr

---

## Declaration Statement

I declare that the application "MeshMapper" uses cryptographic functions solely for the purpose of mesh network protocol compatibility. The encryption is ancillary to the application's primary function of GPS-based coverage mapping and uses only standard, publicly available cryptographic algorithms (SHA-256 and AES-128-ECB) with key lengths not exceeding 128 bits.

The cryptographic functionality does not enable encrypted communication between users and is required only for interoperability with MeshCore mesh network hardware devices.

**Date**: ____________________

**Signature**: ____________________

**Name**: ____________________

**Title**: ____________________

---

## Appendix: Source Code References

| File | Lines | Function |
|------|-------|----------|
| `lib/services/meshcore/crypto_service.dart` | 26-56 | `deriveChannelKey()` - SHA-256 key derivation |
| `lib/services/meshcore/crypto_service.dart` | 77-80 | `computeChannelHash()` - SHA-256 hash |
| `lib/services/meshcore/crypto_service.dart` | 89-123 | `decryptChannelMessage()` - AES-ECB decrypt |
| `lib/services/meshcore/crypto_service.dart` | 130-164 | `encryptChannelMessage()` - AES-ECB encrypt |
| `lib/services/meshcore/channel_service.dart` | 19-39 | Channel initialization with pre-computed keys |
