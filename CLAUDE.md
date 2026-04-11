# NorthMac - NorthStar Advantage Emulator

## Build & Deploy

After every build, always:

1. Build: `xcodebuild -project NorthMac.xcodeproj -scheme NorthMac -configuration Debug build`
2. Delete any stale copies: `rm -rf /Applications/NorthMac.app`
3. Copy fresh build: `cp -R "$(xcodebuild -project NorthMac.xcodeproj -scheme NorthMac -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $3}')/NorthMac.app" /Applications/`

This ensures /Applications/NorthMac.app is always the latest build.
