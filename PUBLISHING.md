# Publishing Counterfoil

One-time setup for distributing Counterfoil outside of ad-hoc builds.

## Prerequisites

1. **Apple Developer Program** — $99/year at [developer.apple.com](https://developer.apple.com)
2. **Developer ID Application certificate** — Create in Xcode → Settings → Accounts, or at [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)

## Direct Distribution (Notarized .app)

### 1. Build with Developer ID signing

```bash
# Find your Developer ID identity
security find-identity -v -p basic | grep "Developer ID Application"

# Edit build.sh: replace the ad-hoc sign line with:
# codesign --force --sign "Developer ID Application: Your Name (TEAMID)" \
#   --options runtime "${BUNDLE_DIR}"

./build.sh
```

### 2. Package as .dmg or .zip

```bash
# Zip (simplest)
ditto -c -k --keepParent /Applications/Counterfoil.app Counterfoil.zip

# Or DMG
hdiutil create -volname Counterfoil -srcfolder /Applications/Counterfoil.app -ov Counterfoil.dmg
```

### 3. Notarize

```bash
# Upload for notarization
xcrun notarytool submit Counterfoil.zip \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "@keychain:AC_PASSWORD" \
  --wait

# Staple the notarization ticket
xcrun stapler staple /Applications/Counterfoil.app

# Verify
spctl -a -v /Applications/Counterfoil.app
```

### 4. Distribute

The stapled .zip or .dmg is ready to share. Gatekeeper will pass on user machines.

## App Store Distribution

1. Create an App ID at developer.apple.com (bundle: `com.willchai.counterfoil`)
2. In Xcode: Product → Archive → Distribute App → App Store Connect
3. The app uses Hardened Runtime by default (ScreenCaptureKit requirement)
4. Entitlements may need `com.apple.security.cs.disable-library-validation` if using bundled frameworks — Counterfoil currently bundles nothing, so this is not needed

## Codesign Check

```bash
codesign -dvvv /Applications/Counterfoil.app
```

Expect: `Authority=Developer ID Application: ...`, `Timestamp=...`, `Runtime Version=...`
