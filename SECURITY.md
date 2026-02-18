# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| Latest  | Yes       |

Only the latest release on the `main` branch receives security updates.

## Reporting a Vulnerability

If you discover a security vulnerability in MeshMapper Flutter App, please report it responsibly. **Do not open a public GitHub issue for security vulnerabilities.**

### How to Report

1. Open a **private security advisory** at:
   https://github.com/MeshMapper/MeshMapper_Project/security/advisories/new

2. Include the following information:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

### What to Expect

- **Acknowledgment**: We will acknowledge receipt of your report within 72 hours.
- **Assessment**: We will assess the severity and impact of the vulnerability.
- **Fix timeline**: Critical issues will be addressed as quickly as possible. We aim to release a fix within 30 days of confirmation.
- **Disclosure**: We will coordinate with you on public disclosure timing after a fix is available.

## Security Considerations

### API Key Handling

- API keys are injected at build time via `--dart-define=API_KEY=...` and are **never** hardcoded in source code.

### Bluetooth Security

- The app communicates with MeshCore devices over Bluetooth Low Energy (BLE) using the MeshCore companion protocol.
- Channel messages are encrypted using AES-ECB with SHA-256 derived channel keys (encryption mode is dictated by the MeshCore protocol).

### Data Privacy

- GPS location data is sent to the MeshMapper API for community mesh coverage mapping.
- Users must be within a valid geographic zone (server-side validation) to submit data.
- No personal information beyond device name/public key and location data is transmitted.

## Scope

The following are **in scope** for security reports:

- Vulnerabilities in the Flutter application code
- API key or secret exposure
- Authentication or session management issues
- Data leakage or privacy concerns

The following are **out of scope**:

- Vulnerabilities in third-party dependencies (report to the upstream project)
- Issues with the MeshCore firmware or radio protocol (report to the MeshCore project)