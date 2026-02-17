# MeshMapper Encryption Documentation - Apple App Store Exemption

This document provides the information required for Apple's App Store Connect export compliance questionnaire using the **exemption route**.

---

## App Store Connect Form Responses

### Question 1: Does your app use encryption?

**Select:** "Yes"

---

### Question 2: Does your app qualify for any of the exemptions provided in Category 5, Part 2 of the U.S. Export Administration Regulations?

**Select:** "Yes"

**Exemption Basis:** The app qualifies for exemption under **EAR § 740.17(b)(1)** (mass market encryption) because:

1. **Standard algorithms only** - Uses AES-256 and SHA-256, both NIST/FIPS standards
2. **Ancillary encryption** - Encryption is not the primary function; the app is a mesh network coverage mapper
3. **Decryption only** - The app only decrypts incoming mesh packets for protocol interoperability; it does not provide general-purpose encryption to users
4. **No user-accessible cryptographic functions** - Users cannot encrypt/decrypt arbitrary data

---

### Question 3: Does your app implement any of the following types of encryption algorithms?

If prompted, select: **"Standard encryption algorithms"**

The app uses:
- AES-256 (FIPS 197) - for decrypting mesh network packets
- SHA-256 (FIPS 180-4) - for deriving channel keys

Both are internationally recognized standard algorithms.

---

## Exemption Justification

### Why MeshMapper Qualifies for Exemption

| Criteria | MeshMapper Status |
|----------|-------------------|
| Uses standard algorithms | Yes - AES, SHA-256 (NIST standards) |
| Encryption is ancillary | Yes - Primary function is GPS coverage mapping |
| User cannot modify crypto | Yes - No user-accessible crypto functions |
| Generally available | Yes - Open source library (PointyCastle) |
| Primary function is NOT encryption | Yes - Mesh network coverage mapping |

### What the Encryption Does

- **SHA-256**: Hashes channel names to derive shared keys (required by MeshCore protocol)
- **AES-ECB**: Decrypts incoming mesh packets to read coverage data

### What the Encryption Does NOT Do

- Does NOT encrypt user data
- Does NOT provide end-to-end encrypted messaging
- Does NOT offer encryption capabilities to users
- Does NOT protect data at rest
- Does NOT perform authentication

---

## If Apple Requests Additional Information

If Apple requests more details, provide this statement:

```
MeshMapper is a companion app for MeshCore mesh network radio devices used for coverage mapping. The app contains encryption solely for protocol interoperability with the MeshCore mesh protocol:

1. SHA-256 hashing of channel names to derive shared channel keys (required by MeshCore protocol specification)
2. AES-ECB decryption of incoming mesh network packets received via Bluetooth

The encryption uses only standard algorithms (AES, SHA-256) implemented via PointyCastle, an open-source Dart library. The app does not provide any user-accessible encryption capabilities. Users cannot encrypt or decrypt arbitrary data. The cryptographic functionality is ancillary to the app's primary purpose of mesh network coverage mapping.

This qualifies for exemption under EAR § 740.17(b)(1) as mass market encryption software using standard algorithms where encryption is ancillary to the primary function.
```

---

## Info.plist Setting

The following key is set in `ios/Runner/Info.plist`:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

Setting this to `false` indicates the app's encryption qualifies for an exemption and does not require annual self-classification reports to the U.S. Bureau of Industry and Security (BIS).

---

## Document History

| Date | Version | Notes |
|------|---------|-------|
| 2026-01-19 | 1.0 | Initial documentation - exemption route |
