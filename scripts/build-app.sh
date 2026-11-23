#!/bin/zsh
# Builds build/Hoatzin.app (release).
#   scripts/build-app.sh             build and sign
#   scripts/build-app.sh --notarize  also notarize and staple it, so it opens on other Macs
#   scripts/build-app.sh --install   also copy it to ~/Applications
#
# Signing: HOATZIN_SIGN_IDENTITY if set, otherwise the first "Developer ID Application"
# certificate in your keychain, otherwise "Apple Development", otherwise ad hoc (this Mac only).
# iCloud sync needs the app's Developer ID provisioning profile as well (not in the repository):
# HOATZIN_PROVISIONING_PROFILE, or Resources/Hoatzin.provisionprofile. Without it the app is
# built without iCloud, and its Settings say so. HOATZIN_CLOUDKIT_ENV=Development (default
# Production) uses CloudKit's development environment, for testing.
# Notarizing uses the notarytool keychain profile HOATZIN_NOTARY_PROFILE (default
# "hoatzin-notary"), created once with `xcrun notarytool store-credentials` (see docs/development.md).
set -euo pipefail
cd "${0:A:h}/.."

NOTARIZE=false INSTALL=false
for argument in "$@"; do
  case $argument in
    --notarize) NOTARIZE=true ;;
    --install) INSTALL=true ;;
    *) echo "unknown option: $argument" >&2; exit 2 ;;
  esac
done

IDENTITY=${HOATZIN_SIGN_IDENTITY:-}
for kind in "Developer ID Application" "Apple Development"; do
  [[ -n $IDENTITY ]] && break
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' -v kind="$kind" 'index($2, kind) == 1 { print $2; exit }')
done
IDENTITY=${IDENTITY:--}
if $NOTARIZE && [[ $IDENTITY != "Developer ID Application"* ]]; then
  echo "--notarize needs a Developer ID Application certificate (found: ${IDENTITY/#-/none})" >&2; exit 1
fi

# The macOS SDK's SwiftUI macros ship with Xcode, not with the Command Line Tools.
if [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
fi

# The compiler also lists every localizable text (build/strings), for the translation check below.
STRINGS=build/strings
mkdir -p "$STRINGS"
swift build -c release --product Hoatzin \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$STRINGS"
swift build -c release --product hoatzin-askpass
swift build -c release --product hoatzin-mcp
BIN=$(swift build -c release --show-bin-path)

# The icon is made from Resources/AppIcon-source.png (redone when that image changes).
[[ Resources/AppIcon.icns -nt Resources/AppIcon-source.png ]] || swift scripts/make-icon.swift Resources/AppIcon-source.png Resources/AppIcon.icns

APP=build/Hoatzin.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Libraries shown in the About panel, with versions and license texts from the actual checkouts.
swift package dump-package > build/manifest.json
swift scripts/acknowledgements.swift build/manifest.json "$APP/Contents/Resources/Acknowledgements.json"
rm -f build/manifest.json
cp "$BIN/Hoatzin" "$BIN/hoatzin-askpass" "$BIN/hoatzin-mcp" "$APP/Contents/MacOS/"
# SwiftPM resource bundles of dependencies, if any.
for bundle in "$BIN"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done

# App Intents (Shortcuts, Siri, Spotlight). Xcode extracts their metadata when it builds an app;
# SwiftPM doesn't, so it's done here from the constant values the compiler wrote.
ARCH=$(uname -m)
OBJ="${BIN:h:h}/Intermediates.noindex/Hoatzin.build/Release/Hoatzin-p.build/Objects-normal/$ARCH"
INTENTS=build/appintents
rm -rf "$INTENTS"
mkdir -p "$INTENTS"
print -l "$OBJ"/*.swiftconstvalues > "$INTENTS/constvalues.txt"
if ! xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
    --toolchain-dir "${$(xcrun --find swiftc):h:h:h}" --module-name Hoatzin \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" --platform-family macOS \
    --deployment-target 14.0 --target-triple "$ARCH-apple-macosx14.0" \
    --source-file-list "$OBJ/Hoatzin.SwiftFileList" --swift-const-vals-list "$INTENTS/constvalues.txt" \
    > "$INTENTS/metadata.log" 2>&1 \
  || ! grep -q RunCommandIntent "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"; then
  cat "$INTENTS/metadata.log"; echo "App Intents metadata could not be generated" >&2; exit 1
fi
# Siri / Spotlight phrase data for the App Shortcuts, in every language with an
# <lang>.lproj/AppShortcuts.strings (English is the source, German is translated).
for lproj in Resources/*.lproj(N); do cp -R "$lproj" "$APP/Contents/Resources/"; done
xcrun appintentsnltrainingprocessor --infoplist-path "$APP/Contents/Info.plist" --temp-dir-path "$INTENTS/nl" \
  --bundle-id "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" \
  --product-path "$APP/Contents/Resources" --extracted-metadata-path "$APP/Contents/Resources/Metadata.appintents" \
  --archive-ssu-assets > "$INTENTS/nltraining.log" 2>&1 || { cat "$INTENTS/nltraining.log"; exit 1; }
for lproj in Resources/*.lproj(N); do
  lang=${${lproj:t}:r}
  grep -q "locale: $lang\$" "$APP/Contents/Resources/Metadata.appintents/root.ssu.yaml" \
    || { echo "Siri phrases for '$lang' are missing from the App Intents data" >&2; exit 1; }
done

# Every text needs its German translation (Resources/de.lproj); fails the build otherwise.
swift scripts/check-translations.swift "$STRINGS" "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" Resources

# iCloud (CloudKit) entitlements, allowed by the embedded provisioning profile. A profile only
# works with a certificate it lists, so it is used with the Developer ID certificate only.
ENTITLEMENTS=Resources/Hoatzin.entitlements
PROFILE=${HOATZIN_PROVISIONING_PROFILE:-Resources/Hoatzin.provisionprofile}
CLOUDKIT_ENV=${HOATZIN_CLOUDKIT_ENV:-Production}
ICLOUD="off (no provisioning profile; see the top of this script)"
if [[ -f $PROFILE && $IDENTITY == "Developer ID Application"* ]]; then
  security cms -D -i "$PROFILE" > build/profile.plist
  profile() { /usr/libexec/PlistBuddy -c "Print :$1" build/profile.plist; }
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
  TEAM=$(profile TeamIdentifier:0)
  CONTAINER=iCloud.$BUNDLE_ID
  [[ $(profile Entitlements:com.apple.application-identifier) == "$TEAM.$BUNDLE_ID" ]] \
    || { echo "$PROFILE is not for $BUNDLE_ID" >&2; exit 1; }
  [[ $IDENTITY == *"($TEAM)" ]] || { echo "$PROFILE belongs to team $TEAM, not to $IDENTITY" >&2; exit 1; }
  [[ $(plutil -extract ExpirationDate raw build/profile.plist) > $(date -u +%Y-%m-%dT%H:%M:%SZ) ]] \
    || { echo "$PROFILE has expired; download a new one (see docs/development.md)" >&2; exit 1; }
  profile Entitlements:com.apple.developer.icloud-container-identifiers | grep -qx " *$CONTAINER" \
    || { echo "$PROFILE does not include the iCloud container $CONTAINER" >&2; exit 1; }
  profile Entitlements:com.apple.developer.icloud-container-environment | grep -qw "$CLOUDKIT_ENV" \
    || { echo "$PROFILE does not allow CloudKit's $CLOUDKIT_ENV environment" >&2; exit 1; }
  ENTITLEMENTS=build/Hoatzin.entitlements
  cp Resources/Hoatzin.entitlements "$ENTITLEMENTS"
  for command in "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" \
                 "Add :com.apple.developer.team-identifier string $TEAM" \
                 "Add :com.apple.developer.icloud-container-identifiers array" \
                 "Add :com.apple.developer.icloud-container-identifiers:0 string $CONTAINER" \
                 "Add :com.apple.developer.icloud-services array" \
                 "Add :com.apple.developer.icloud-services:0 string CloudKit" \
                 "Add :com.apple.developer.icloud-container-environment string $CLOUDKIT_ENV"; do
    /usr/libexec/PlistBuddy -c "$command" "$ENTITLEMENTS"
  done
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  rm -f build/profile.plist
  ICLOUD="on ($CONTAINER, $CLOUDKIT_ENV)"
fi

# Helpers first, then the app around them. Hardened Runtime everywhere (required for
# notarization); a secure timestamp for Developer ID signatures.
SIGN=(codesign --force --options runtime --sign "$IDENTITY")
[[ $IDENTITY == "Developer ID Application"* ]] && SIGN+=(--timestamp)
"${SIGN[@]}" "$APP/Contents/MacOS/hoatzin-askpass"
"${SIGN[@]}" "$APP/Contents/MacOS/hoatzin-mcp"
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --deep "$APP"
if [[ $IDENTITY == - ]]; then
  echo "Signed ad hoc (no Developer ID / Apple Development certificate found): runs on this Mac only."
else
  echo "Signed as: $IDENTITY"
fi
echo "iCloud sync: $ICLOUD"

if $NOTARIZE; then
  ditto -c -k --keepParent "$APP" build/Hoatzin-notarize.zip
  xcrun notarytool submit build/Hoatzin-notarize.zip --keychain-profile "${HOATZIN_NOTARY_PROFILE:-hoatzin-notary}" --wait
  rm -f build/Hoatzin-notarize.zip
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
fi
# Tell Launch Services about the new build, so Shortcuts and Spotlight see its actions.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"

if $INSTALL; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Hoatzin.app
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/Hoatzin.app"
fi
