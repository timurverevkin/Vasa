# Nexus (Swift)

Native macOS app — SwiftUI.

Open and run:

```
open macos/Nexus/Nexus.xcodeproj
```

or:

```
xcodebuild -project macos/Nexus/Nexus.xcodeproj -scheme Nexus -configuration Debug
```

## Release DMG

```
./scripts/build-native-macos.sh
```

Скрипт собирает Release `.app` через `xcodebuild` и упаковывает `release/Nexus-<version>-<arch>-native.dmg` (плюс копия `release/Nexus-native.app`).
