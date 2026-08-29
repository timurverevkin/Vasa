# Vasa (Swift)

Native macOS app — SwiftUI.

Open and run:

```
open macos/Vasa/Vasa.xcodeproj
```

or:

```
xcodebuild -project macos/Vasa/Vasa.xcodeproj -scheme Vasa -configuration Debug
```

## Release DMG

```
./scripts/build-native-macos.sh
```

Скрипт собирает Release `.app` через `xcodebuild` и упаковывает `release/Vasa-<version>-<arch>-native.dmg` (плюс копия `release/Vasa-native.app`).
