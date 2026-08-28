<h1 align="center">Plaud SDK</h1>

<p align="center">
  <strong>Connect, record, sync, and transcribe with Plaud devices.</strong>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#template-app">Template App</a> •
  <a href="#sdk-integration-guide">SDK Guide</a> •
  <a href="#transcription-api">Transcription API</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS%2014%2B-blue" alt="iOS 14+">
  <img src="https://img.shields.io/badge/platform-Android%205.0%2B-brightgreen" alt="Android 5.0+">
  <img src="https://img.shields.io/badge/swift-5.0-orange" alt="Swift 5.0">
  <img src="https://img.shields.io/badge/kotlin-1.8-purple" alt="Kotlin 1.8">
  <img src="https://img.shields.io/badge/license-Apache%202.0-green" alt="License">
</p>

---

Plaud SDK enables B2B partners to integrate Plaud recording devices into their own apps. This repository includes:

- **`sdk/`** — Precompiled SDK binaries (iOS `.framework` + Android `.aar`)
- **`plaud-template-app/`** — A complete iOS reference app demonstrating every SDK feature
- **`android/`** — The Android reference app with full feature parity to iOS

> **Coming soon:** demo video walkthrough.

## Project Structure

```
plaud-sdk-public/
├── sdk/
│   ├── ios/                              # iOS SDK frameworks
│   │   ├── PlaudBleSDK.framework         # BLE communication
│   │   ├── PlaudDeviceBasicSDK.framework # Core device management
│   │   ├── PlaudDeviceBasicSDK.bundle    # SDK resources
│   │   └── PlaudWiFiSDK.framework        # WiFi fast transfer
│   └── android/                          # Android SDK
│       └── plaud-sdk.aar                 # Android AAR package
├── plaud-template-app/
│   └── ios/                              # iOS Template App
│       ├── project.yml                   # Xcodegen config
│       ├── PartnerConfig.xcconfig        # SDK credentials (edit this!)
│       └── PlaudTemplateApp/             # Source code
├── android/                              # Android Template App
│   ├── app/                              # App module
│   │   └── libs/plaud-sdk.aar            # Bundled Android SDK
│   └── local.properties                  # SDK credentials (create this, gitignored)
├── LICENSE
└── README.md
```

## Quick Start

### iOS

#### Prerequisites

- Xcode 16.0+ (SDK built with Swift 6.0.3, compatible with Xcode 16+)
- iOS 14.0+ deployment target
- [Xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A Plaud partner account with User Access Token

#### 1. Configure Credentials

Edit `plaud-template-app/ios/PartnerConfig.xcconfig`:

```xcconfig
# Required for SDK initialization
USER_ACCESS_TOKEN = your-jwt-token

# Required for Transcription API (optional, not needed for device features)
PLAUD_CLIENT_ID = your-client-id
PLAUD_API_KEY = your-api-key
```

> **Tip:** Create `plaud-template-app/ios/PartnerConfig.local.xcconfig` with your real credentials — it's gitignored and will override the placeholder values.
>
> **Where to get these:**
> - `USER_ACCESS_TOKEN`: Your backend calls `POST /open/partner/users/access-token` to obtain this per-user JWT.
> - `PLAUD_CLIENT_ID` + `PLAUD_API_KEY`: Create in the [Plaud Developer Portal](https://platform.plaud.ai/developer/portal). See the QUICKSTART guide for details.

#### 2. Update Project Settings

Edit `plaud-template-app/ios/project.yml`:
- Change `bundleIdPrefix: com.plaud` to your own Bundle ID prefix (e.g., `com.yourcompany`)
- Xcode will auto-assign your Development Team on first build

#### 3. Generate Xcode Project

```bash
cd plaud-template-app/ios
xcodegen generate
```

#### 4. Build & Run

Open `plaud-template-app/ios/PlaudTemplateApp.xcodeproj` in Xcode, select your physical device, and run.

> **Note:** SDK frameworks are compiled for `arm64` (physical devices only). Simulator is not supported.

### Android

#### Prerequisites

- Android Studio (JDK 17)
- minSdk 21 (Android 5.0+), compileSdk 34
- A Plaud partner account with User Access Token

#### 1. Configure Credentials

Create `android/local.properties` (gitignored) and add:

```properties
sdk.dir=/path/to/your/Android/sdk

# Required for SDK initialization
PLAUD_USER_ACCESS_TOKEN=your-jwt-token

# Required for Transcription API (optional, not needed for device features)
PLAUD_CLIENT_ID=your-client-id
PLAUD_API_KEY=your-api-key
```

The values are injected into `BuildConfig` at build time. Credentials come from the same sources as iOS (see above).

#### 2. Build & Run

```bash
cd android
./gradlew assembleDebug
```

Or open `android/` in Android Studio and run on a physical device.

> **Note:** The SDK ships native libraries for `arm64-v8a` / `armeabi-v7a` — use a physical device, not an emulator.

---

## Template App

The Template App is a fully functional app demonstrating every SDK capability — available on both platforms with identical features and UI. Use it as a reference for your own integration.

### Features

| Feature | Description |
|---------|-------------|
| 🔗 **Device Connection** | BLE scanning, pairing, and auto-reconnect |
| 📱 **Multi-Device** | Pair multiple devices, switch between them |
| 🎙️ **Recording** | Real-time recording with live PCM waveform |
| 📥 **File Sync** | BLE sync with auto-download on connect |
| ⚡ **WiFi Fast Transfer** | ~10x faster than BLE |
| 🔄 **Firmware Update** | OTA upgrade with progress UI |
| 📝 **Transcription** | Speech-to-text via S3 upload + API |
| 🔊 **Audio Playback** | MP3 playback with floating player |

### Architecture

| Layer | iOS | Android |
|-------|-----|---------|
| Language | Swift | Kotlin |
| UI | UIKit (programmatic, no Storyboard) | Views + ViewBinding (no Compose) |
| Pattern | MVVM + Combine | MVVM + StateFlow / Coroutines |
| Build | Xcodegen (`project.yml` → `.xcodeproj`) | Gradle |
| Min Target | iOS 14.0 | Android 5.0 (API 21) |

### App Structure

```
PlaudTemplateApp/
├── App/                   # SceneDelegate (launch routing)
├── Common/                # PlaudTheme, PlaudToggle, Extensions
├── Managers/
│   ├── DeviceManager      # SDK wrapper: scan/connect/OTA/multi-device
│   ├── RecordingManager   # Recording state + PCM waveform
│   ├── SyncManager        # File sync (BLE + WiFi fast transfer)
│   ├── TranscriptionManager # S3 upload + transcription polling
│   ├── PlaudAPIService    # HTTP API client (upload, transcription)
│   └── Mock/              # Mock implementations for UI development
├── Models/                # PlaudDevice, RecordingFile, SyncState, etc.
├── Storage/               # RecordingStore (local persistence)
└── UI/
    ├── Onboarding/        # Welcome → Scanning → Connect → Success
    ├── Main/              # MainTabBarController (floating capsule tab bar)
    ├── Home/              # DeviceCard + RecordingTrigger + RecentFiles
    ├── Recording/         # Full-screen recording with waveform
    ├── Files/             # File list grouped by date
    ├── FileDetail/        # Transcript + audio player
    └── Settings/          # Firmware update + Sign out
```

The Android app mirrors this structure 1:1 under `android/app/src/main/java/com/plaud/template/`:

```
com.plaud.template/
├── common/                # PlaudTheme, PlaudToggle, JwtUtils, AppLog
├── managers/              # DeviceManager / RecordingManager / SyncManager /
│                          # TranscriptionManager (+ mock/ implementations)
├── models/                # PlaudDevice, RecordingFile, SyncState, etc.
├── storage/               # RecordingStore (local persistence)
└── ui/                    # onboarding / main / home / recording /
                           # files / filedetail / settings
```

### Key Implementation Details

<details>
<summary><strong>Launch Routing</strong></summary>

- Has paired devices + userId → `MainTabBarController` (auto-reconnect in background)
- No paired devices → `WelcomeViewController`
</details>

<details>
<summary><strong>Auto-Reconnect</strong></summary>

- `sceneDidBecomeActive` triggers scan after 2-second delay (BLE power-on time)
- `bleScanResult` matches `activeDeviceSN` → auto-connect
- `startAutoReconnect`: 30-second interval timer, max 10 attempts
</details>

<details>
<summary><strong>Multi-Device</strong></summary>

- `RecordingStore.pairedDeviceSNs`: array of paired device SNs
- `RecordingStore.activeDeviceSN`: currently active device
- BLE only supports one connection at a time; switching disconnects current, scans for target
- SDK handles per-device sn-sign caching internally
</details>

<details>
<summary><strong>Recording & Waveform</strong></summary>

- `syncFile(sessionId:start:end:)` enables PCM decode stream
- `blePcmData` delivers decoded PCM (640 bytes, 16kHz mono)
- `JXRecordVolumer.shared.averageVolume(pcmData)` → dB volume
- 100ms timer for smooth waveform rendering (decoupled from BLE jitter)
</details>

<details>
<summary><strong>File Sync</strong></summary>

- On connect: `getFileList()` → `exportAudio(format: .mp3)` → `deleteFile()`
- MP3 format: playable by AVAudioPlayer + accepted by transcription API upload
- Files belong to the phone after sync; device files are always unsynced
</details>

<details>
<summary><strong>Firmware Update</strong></summary>

- `checkFirmwareUpdate()` on device connect
- `FirmwareUpdateSheetViewController`: bottom sheet with segmented progress bar
- `isOTAInProgress` flag prevents auto-reconnect interference during OTA
- Sheet waits for device restart + reconnect before dismissing
</details>

<details>
<summary><strong>Transcription</strong></summary>

- `TranscriptionManager`: upload → submit → poll workflow
- S3 multipart upload: `generatePresignedURLs` → PUT parts → `completeUpload`
- Submit: `POST /open/partner/ai/transcriptions/`
- Poll every 5 seconds (up to 20 min) until `status == "SUCCESS"`
</details>

### Supported Devices

| SN Prefix | Type | Device |
|-----------|------|--------|
| 881 | notepro | Plaud NotePro |
| 882 | notepins | Plaud NotePin S |

> The device type string is derived from the SN prefix and is the cloud registry key together with the SN — keep it consistent across every API call for the same device.

### Credential Configuration

**iOS** (`PartnerConfig.xcconfig` → Info.plist):

| xcconfig Key | Info.plist Key | Usage |
|-------------|---------------|-------|
| `USER_ACCESS_TOKEN` | `UserAccessToken` | SDK initialization (required) |
| `PLAUD_CLIENT_ID` | `PlaudClientId` | Transcription API (`X-Client-Id` header) |
| `PLAUD_API_KEY` | `PlaudApiKey` | Transcription API (`X-Client-Api-Key` header) |

**Android** (`local.properties` → `BuildConfig`):

| Property | BuildConfig Field | Usage |
|----------|-------------------|-------|
| `PLAUD_USER_ACCESS_TOKEN` | `USER_ACCESS_TOKEN` | SDK initialization (required) |
| `PLAUD_CLIENT_ID` | `PLAUD_CLIENT_ID` | Transcription API (`X-Client-Id` header) |
| `PLAUD_API_KEY` | `PLAUD_API_KEY` | Transcription API (`X-Client-Api-Key` header) |

At runtime the Settings screen also lets you replace the user access token and the API key without rebuilding; the `X-Client-Id` is automatically derived from the active token's JWT `client_id` claim.

---

## SDK Integration Guide

If you're building your own app from scratch (not using the Template App), follow this guide.

### iOS

#### Framework Setup

| Framework | Action |
|-----------|--------|
| `PlaudBleSDK.framework` | Embed & Sign |
| `PlaudWiFiSDK.framework` | Embed & Sign |
| `PlaudDeviceBasicSDK.framework` | Embed & Sign |
| `PlaudDeviceBasicSDK.bundle` | Copy Bundle Resources |

#### Initialization

```swift
import PlaudDeviceBasicSDK

PlaudDeviceAgent.shared.initSDK(
    userAccessToken: "your-jwt-token",
    customDomain: "platform-us.plaud.ai"  // domain only, no https://
)
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `userAccessToken` | Yes | JWT token for device authentication. Handshake token is auto-parsed from the `sub` field. |
| `customDomain` | Yes | Server domain without `https://` prefix. |

#### Dynamic Token Refresh

```swift
PlaudDeviceAgent.shared.setUserAccessToken(newToken)
```

#### Device Connection

```swift
PlaudDeviceAgent.shared.delegate = self
PlaudDeviceAgent.shared.startScan()
PlaudDeviceAgent.shared.connectBleDevice(bleDevice: device)
```

##### Key Callbacks (`PlaudDeviceAgentProtocol`)

| Callback | Description |
|----------|-------------|
| `bleScanResult(bleDevices:)` | Scan results updated |
| `bleConnectState(state:)` | 1=connected, 0=disconnected |
| `bleBind(sn:status:...)` | Device bound successfully |
| `blePenState(state:...)` | Handshake complete |

#### Device Recovery

Recover a device still locked to a previous account — unbound in the cloud, but the firmware retains the old identity, so the current account is rejected at the encrypted handshake.

```swift
// 1. Query cloud binding; proceed only if is_bind == false, then try each historical account:
//    GET /open/partner/sdk/binding  ->  { is_bind, bind_history: [...] }
PlaudDeviceAgent.shared.recoveryConnectBleDevice(bleDevice: device, historicalUserId: historicalId)

// 2. On bleBind(status: 0) — the historical id matched the firmware lock — wipe the stale bond:
PlaudDeviceAgent.shared.depair(clear: false)

// 3. depair changes the MAC — rescan, then connect normally as the current user to rebind.
PlaudDeviceAgent.shared.connectBleDevice(bleDevice: rescannedDevice)
```

> `historicalUserId` accepts the raw `client_user_...` id from `bind_history`. See the Template App's `DeviceManager` for the full loop.

#### File Synchronization

```swift
PlaudDeviceAgent.shared.getFileList(startSessionId: 0)

PlaudDeviceAgent.shared.exportAudio(
    sessionId: sessionId,
    outputDir: outputDir,
    format: .mp3,    // MP3: playable + uploadable for transcription
    channels: 1,
    callback: self
)

PlaudDeviceAgent.shared.deleteFile(sessionId: sessionId)
```

#### WiFi Fast Transfer

~10x faster than BLE. Requires `Hotspot Configuration` entitlement.

```swift
PlaudDeviceAgent.shared.setDeviceWiFi(open: true)
// In bleWiFiOpen callback:
PlaudWiFiAgent.shared.bleDevice = BleAgent.shared.bleDevice
PlaudWiFiAgent.shared.connectWifi(ssid, password, 60)
// After wifiHandshake(status: 0):
PlaudWiFiAgent.shared.exportAudioViaWiFi(...)
```

#### Firmware Update (OTA)

SDK handles the full flow: version check → download → verify → push → restart → reconnect.

```swift
// Check for update
PlaudDeviceAgent.shared.checkFirmwareUpdate { result in
    guard result.hasUpdate else { return }
}

// One-call update
PlaudDeviceAgent.shared.startFirmwareUpdate(
    progress: { phase, percentage in
        // .downloading / .installing / .restarting / .complete
    },
    completion: { result in
        print(result.success ? "Updated to \(result.version)" : "Failed: \(result.errorMessage ?? "")")
    }
)
```

### Android

#### Library Setup

Copy `sdk/android/plaud-sdk.aar` into your app module's `libs/` directory:

```groovy
dependencies {
    implementation files('libs/plaud-sdk.aar')
}
```

#### Initialization

```kotlin
import sdk.PlaudDeviceAgent

PlaudDeviceAgent.initSDK(
    context = applicationContext,
    userAccessToken = "your-jwt-token",
    customDomain = "platform-us.plaud.ai"  // domain only, no https://
)
```

#### Device Connection

```kotlin
PlaudDeviceAgent.listener = object : PlaudDeviceAgentListener {
    override fun bleScanResult(devices: List<BleDevice>) { /* scan results */ }
    override fun bleConnectState(state: Int) { /* 1=connected, 0=disconnected */ }
    override fun bleBind(sn: String?, status: Int, protVersion: Int, timezone: Int) { /* bound */ }
    override fun blePenState(state: Int, privacy: Int, keyState: Int, uDisk: Int) { /* handshake complete */ }
    // ... recording / file-list / battery / storage callbacks
}

PlaudDeviceAgent.startScan()
PlaudDeviceAgent.connectBleDevice(bleDevice)
```

#### Device Recovery

Recover a device still locked to a previous account — unbound in the cloud, but the firmware retains the old identity, so the current account is rejected at the encrypted handshake.

```kotlin
// 1. Query cloud binding; proceed only if is_bind == false, then try each historical account:
//    GET /open/partner/sdk/binding  ->  { is_bind, bind_history: [...] }
PlaudDeviceAgent.recoveryConnectBleDevice(device, historicalId)

// 2. On bleBind(status = 0) — the historical id matched the firmware lock — wipe the stale bond:
PlaudDeviceAgent.depair(false)

// 3. depair changes the MAC — rescan, then connect normally as the current user to rebind.
PlaudDeviceAgent.connectBleDevice(rescannedDevice)
```

> `historicalUserId` accepts the raw `client_user_...` id from `bind_history`. See the Template App's `DeviceManager` for the full loop.

#### File Synchronization

```kotlin
PlaudDeviceAgent.getFileList()

PlaudDeviceAgent.exportAudio(
    sessionId = sessionId,
    outputDir = outputDir,
    format = AudioExportFormat.MP3,   // MP3: playable + uploadable for transcription
    channels = 1,
    callback = object : AudioExporter.ExportCallback { /* progress / complete */ }
)

PlaudDeviceAgent.deleteFile(sessionId)
```

#### WiFi Fast Transfer

```kotlin
PlaudDeviceAgent.startWifiTransfer(userId, object : IWifiTransferAgent.WifiTransferCallback {
    // onConnectionStateChanged / onFileListReceived / onBatchDownloadStarted /
    // onBatchDownloadProgress / onBatchDownloadCompleted / onFileDeleteCompleted / onError
})
```

#### Firmware Update (OTA)

```kotlin
PlaudDeviceAgent.checkFirmwareUpdate(callback)          // version check
PlaudDeviceAgent.downloadFirmware(updateInfo, callback)  // download + MD5 verify
PlaudDeviceAgent.installFirmware(file, updateInfo, callback) // BLE push + restart
```

> See `android/app/src/main/java/com/plaud/template/managers/` for complete working examples of every flow above.

---

## Transcription API

These APIs are called directly by the application, not through the SDK.

### Authentication

Uses `X-Client-Id` + `X-Client-Api-Key` headers. Configure `PLAUD_CLIENT_ID` and `PLAUD_API_KEY` in `PartnerConfig.xcconfig` (iOS) or `local.properties` (Android). These are separate from the `USER_ACCESS_TOKEN` used for SDK initialization.

API keys can be created in the [Plaud Developer Portal](https://platform.plaud.ai/developer/portal) under your application's API Keys panel.

### Workflow

```
1. Upload audio  →  generate-presigned-urls  →  PUT parts  →  complete-upload
2. Submit         →  POST /open/partner/ai/transcriptions/
3. Poll           →  GET  /open/partner/ai/transcriptions/{id}
```

### API Reference

Base URL: `https://platform-us.plaud.ai/developer/api`

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/open/partner/files/upload/generate-presigned-urls` | POST | Bearer user token | Get S3 upload URLs |
| `/open/partner/files/upload/complete-upload` | POST | Bearer user token | Complete multipart upload |
| `/open/partner/ai/transcriptions/` | POST | X-Client-Id + X-Client-Api-Key | Submit transcription |
| `/open/partner/ai/transcriptions/{id}` | GET | X-Client-Id + X-Client-Api-Key | Get transcription result |

---

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.

The Plaud SDK binaries in the `sdk/` directory (iOS frameworks and Android AAR) are proprietary and distributed under a separate license.
