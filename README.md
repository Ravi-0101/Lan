# LAN File Server (Flutter starter)

This repository is a runnable **HTTP LAN file-sharing starter** for Android and iOS.

## Included
- One Flutter app with Server Mode and Client Mode.
- HTTP server using Shelf.
- Password authentication and bearer-token sessions.
- File listing, upload, download, folder creation and deletion endpoints.
- Files are stored in the app's private Documents directory.
- Client can connect to another device on the same LAN.

## Important scope and platform limitations
This starter is not the fully specified production release:
- SMB server hosting is **not implemented**. Android SMB server support needs a separately integrated and audited SMB2/SMB3 native implementation. iOS does not expose a general public API for hosting an SMB server.
- Device approval and per-device admin permission profiles are not implemented yet. In this starter, a correct shared password immediately authorizes a client. Do not expose this to untrusted networks.
- HTTP is unencrypted. Use only on a trusted isolated hotspot for development. Production needs HTTPS/TLS, device approval, role-based authorization, audit logs, rate limits and secure credential storage.
- iOS cannot programmatically enable Personal Hotspot. Enable it manually in Settings.
- iOS/Android may suspend background servers. Keep the app foregrounded during transfers.
- The sample shares only the app-private Documents directory. It does not expose the entire phone storage.
- No claim is made that this project has been compiled or device-tested in this environment.

## Build
Install Flutter (3.24+ recommended), Android Studio and Android SDK.
For iOS builds, use macOS with Xcode.

```bash
flutter pub get
flutter run
```

Android release APK:
```bash
flutter build apk --release
```

iOS:
```bash
flutter build ios --release
```

## How to test
1. Install/run the app on two phones.
2. Connect both phones to the same Wi-Fi network or hotspot.
3. On the server phone, enter a password of at least 8 characters and press Start HTTP server.
4. Find the server phone's LAN IP address. The app binds to all interfaces on the chosen port.
5. On the client phone, enter `http://SERVER_IP:8080`, enter the same password and tap Connect.
6. Upload and download files.

If the hotspot phone is iPhone, enable Personal Hotspot manually first. Android hotspot IP addresses vary by device and OEM; do not assume a fixed address.

## API
- `GET /api/info`
- `POST /api/auth` JSON `{ "password": "..." }`
- `GET /api/files` (Bearer token)
- `GET /api/download?name=filename` (Bearer token)
- `POST /api/upload?name=filename` (Bearer token, raw body)
- `POST /api/folder` JSON `{ "name": "folder" }` (Bearer token)
- `DELETE /api/files?name=filename` (Bearer token)

## Before production
Implement device pairing/approval, per-device permission checks on every route, TLS, secure token persistence/expiry/revocation, streaming uploads with size limits, safe nested-path handling, conflict handling, SMB3 Android service integration, iOS local-network usage descriptions, and automated tests.
