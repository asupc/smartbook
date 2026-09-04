# flutter_cloud_sync_icloud

iCloud provider for flutter_cloud_sync - iOS/iPadOS only.

## Features

- Zero configuration - uses system Apple ID
- Private storage - data stored in user's iCloud space
- Multi-device sync - automatic sync across iOS/iPadOS devices
- Native integration - deep iOS ecosystem integration

## Requirements

- iOS 13.0+
- iCloud account signed in
- iCloud Drive enabled

## Setup

### 1. Add dependency

```yaml
dependencies:
  flutter_cloud_sync_icloud:
    path: ../flutter_cloud_sync_icloud
```

### 2. Configure Xcode

1. Open `ios/Runner.xcworkspace`
2. Select Runner target → Signing & Capabilities
3. Click `+ Capability` → Select `iCloud`
4. Check `iCloud Documents`
5. Add container: `iCloud.com.smartbook.zhi`

### 3. Configure Info.plist

```xml
<key>NSUbiquitousContainers</key>
<dict>
    <key>iCloud.com.smartbook.zhi</key>
    <dict>
        <key>NSUbiquitousContainerIsDocumentScopePublic</key>
        <true/>
        <key>NSUbiquitousContainerName</key>
        <string>SmartBook</string>
        <key>NSUbiquitousContainerSupportedFolderLevels</key>
        <string>Any</string>
    </dict>
</dict>
```

## Usage

```dart
import 'package:flutter_cloud_sync_icloud/flutter_cloud_sync_icloud.dart';

// Create provider
final provider = ICloudProvider();

// Initialize (no config needed)
await provider.initialize({});

// Upload
await provider.storage.upload(
  path: 'ledgers/ledger_1.json',
  data: jsonEncode(ledgerData),
);

// Download
final data = await provider.storage.download(
  path: 'ledgers/ledger_1.json',
);
```

## Limitations

- iOS/iPadOS only (Android not supported)
- Uses user's iCloud storage quota
- No real-time sync (manual or polling)
- Single user only (no sharing)
