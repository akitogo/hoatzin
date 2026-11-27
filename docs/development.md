# Developing Hoatzin

How to build, sign, notarize and release Hoatzin, what the build script does, and the switches
for testing. For what the app does, see the [README](../README.md).

## Build & run

```bash
scripts/build-app.sh             # → build/Hoatzin.app, signed with your certificate
scripts/build-app.sh --notarize  # also notarizes it, so it opens on other Macs
scripts/build-app.sh --install   # also copies it to ~/Applications
```

Needs Xcode installed. The macOS 27 SDK's SwiftUI macros ship with Xcode, not with the Command
Line Tools, and the script selects Xcode automatically. Tests:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

### Code layout

* `Sources/HoatzinCore` is the part an iOS app can share: the library and its file, iCloud sync,
  the Proxmox API with the data for the graphs, SSH targets and reconnecting, and the Keychain. It
  doesn't use AppKit and builds for macOS 14 and iOS 17. Where the platforms differ (the device
  name, the app becoming active) it uses `#if os(macOS)`. Questions to the user go through the app:
  `ProxmoxLoginHandler` for passwords, two-factor codes and certificates (the Mac app's
  `CredentialBroker` answers), and `LibrarySync.chooseFirstSync` for the first sync.
* `Sources/HoatzinUI` holds SwiftUI views both apps show the same way: the graphs of Proxmox
  nodes and guests (`MetricsPanel`). Platform differences in there are marked `#if os(macOS)`.
  The Mac app passes in whether its windows can be seen; settings both apps share use the keys in
  `MetricsSettings`.
* `Sources/Hoatzin` is the Mac app: windows, terminal tabs, prompts, Touch ID, AI access and
  Shortcuts.
* `Sources/hoatzin-askpass` and `Sources/hoatzin-mcp` are the helpers.

Texts in the core are looked up in the app's main bundle, so their German translations are in
`Resources/de.lproj` like the app's, and the translation check covers both. An iOS app needs them
in its own strings files.

The iOS SDK isn't needed to check that the core still builds without AppKit. Mac Catalyst uses the
iOS frameworks and the core's iOS code paths:

```bash
SDK=$(xcrun --sdk macosx --show-sdk-path); IOS=$SDK/System/iOSSupport
xcrun swiftc -typecheck -parse-as-library -module-name HoatzinCore -target arm64-apple-ios17.0-macabi \
  -sdk "$SDK" -Fsystem "$IOS/System/Library/Frameworks" -I "$IOS/usr/lib/swift" Sources/HoatzinCore/*/*.swift
```

### What the build script does besides compiling

* **Acknowledgements:** it writes `Contents/Resources/Acknowledgements.json`, the libraries shown
  in *About Hoatzin*. `scripts/acknowledgements.swift` builds it from the package's direct
  dependencies, the versions in `Package.resolved` and each checkout's license file. A new
  dependency only needs a one-line purpose there. Today the only bundled library is SwiftTerm (MIT).
* **App Intents:** it generates the metadata (`Contents/Resources/Metadata.appintents`) that
  Shortcuts, Siri and Spotlight read. Xcode does that for Xcode projects, SwiftPM doesn't, so the
  script runs Xcode's `appintentsmetadataprocessor` and `appintentsnltrainingprocessor` on the
  compiler's constant-value output. It then registers the app with Launch Services. macOS lists
  the actions once the new build has been launched.
* **Translations:** the compiler lists every translatable text, and
  `scripts/check-translations.swift` fails the build if one has no German translation or a
  translation lost a placeholder (see *Languages* in the README).
* **Icon:** the app icon is made from `Resources/AppIcon-source.png` by `scripts/make-icon.swift`,
  again whenever that image changes. The script finds the artwork's rounded square, cuts it out
  onto a transparent background with a fitted squircle mask, places it on Apple's icon grid with a
  soft shadow, and writes all sizes into `Resources/AppIcon.icns`.

## Signing and notarization

The script signs with the first *Developer ID Application* certificate in your keychain, otherwise
*Apple Development*, otherwise ad hoc (this Mac only). `HOATZIN_SIGN_IDENTITY` picks a certificate
explicitly. Everything runs with the Hardened Runtime. `Resources/Hoatzin.entitlements` allows the
Apple Events that open iTerm2 tabs.

Once per Mac:

1. **Certificates:** in Xcode open *Settings → Accounts*, add your Apple Account, select the team
   and choose *Manage Certificates…*. With *+* add **Developer ID Application**, plus **Apple
   Development** if you like.
   * If Xcode refuses with "only the Account Holder" although developer.apple.com shows you as
     Account Holder, Xcode is showing an outdated role. Create the certificate on the website
     instead: *Certificates → + → Developer ID Application*, with a certificate request from
     *Keychain Access → Certificate Assistant*. Then double-click the downloaded `.cer`.
   * If `security find-identity -v -p codesigning` then still lists no valid identity, Apple's
     intermediate certificate is missing. Install it from
     apple.com/certificateauthority (*Developer ID – G2*); Xcode normally adds it.
2. **Build:** run `scripts/build-app.sh`. It prints `Signed as: Developer ID Application: … (TEAM ID)`.
   The first time, allow codesign to use the key (*Always Allow*).
3. **Notarization (for other Macs):**
   * Create an app-specific password at account.apple.com (*Sign-In and Security*).
   * Store it in your keychain with
     `xcrun notarytool store-credentials hoatzin-notary --apple-id <your Apple Account> --team-id <TEAM ID>`.
     It asks for the password; nothing is written to the repo.
   * Then `scripts/build-app.sh --notarize` notarizes and staples the app.
4. **iCloud sync (optional):** CloudKit needs a provisioning profile in the app. In
   *Certificates, Identifiers & Profiles*, register an iCloud container (`iCloud.<bundle ID>`)
   and an App ID for the bundle ID with iCloud (CloudKit) and that container. Then create a
   *Developer ID* profile for it with your Developer ID certificate. Save it as
   `Resources/Hoatzin.provisionprofile` (git ignores it) or point `HOATZIN_PROVISIONING_PROFILE`
   at it. The script checks it, embeds it and adds the iCloud entitlements; it prints
   `iCloud sync: on (…)`. Without a profile the app builds as before, minus iCloud. Before the
   first release with sync, the CloudKit Console (icloud.developer.apple.com) needs the record
   type `Library` with the fields `library` (Encrypted Bytes) and `device` (Encrypted String) in
   Development, deployed to Production.

**Keychain prompts after rebuilds:** an ad-hoc signed build has a new code hash every time, so
macOS asks again for saved passwords after each rebuild (use *Always Allow*). Signed with your
team's certificate, the app keeps one identity across builds. After the first *Always Allow* for a
signed build, rebuilds no longer ask.

## Releasing

Releases go to GitHub with the notarized app attached as a zip. The repository needs an `origin`
remote on GitHub, and `gh` has to be signed in (`gh auth login`). Each release is then one
command:

```bash
scripts/release.sh 1.0.1               # or --prerelease, or --notes-file notes.md
scripts/release.sh 1.0.1 --dry-run     # build and package only, nothing published
```

`scripts/release.sh` does the following:

1. **Checks:** everything is committed, you're on `main`, the tag is new, the version is not
   older than the current one, and the provisioning profile for iCloud sync is there.
2. **Version:** it sets the version in `Resources/Info.plist` and raises the build number.
3. **Build:** it runs the tests, builds, signs and notarizes the app. It then checks that the
   notarization is stapled and that Gatekeeper accepts the app.
4. **Package:** it zips the app with `ditto`, which keeps signature and notarization intact.
5. **Publish:** it commits the version, tags `v<version>`, pushes, and creates the GitHub release.
   The release notes come from the commits, or from `--notes-file`, and include the zip's SHA-256.

The README's download link points at the latest release, so it needs no change per release. A
pre-release doesn't count as "latest"; while there is only a pre-release, the link shows the list
of releases.

## Debug aids

* `HOATZIN_LIBRARY=/path/library.json`: use another library file.
* `HOATZIN_CONTROL_SOCKET=/path.sock` (app and helper): use another AI control socket, e.g. for a
  second test instance. `-aiAccess commands` on the app's command line sets the level for that run only.
* `HOATZIN_AI_LOG=/path.jsonl`: use another AI activity log. With `HOATZIN_LIBRARY` set, the
  log goes next to that library file instead of `~/Library/Logs`.
* `HOATZIN_SNAPSHOT=/path/prefix`: render the app's own windows to PNGs after 3 s, an open sheet
  also drawn onto its window. `HOATZIN_SNAPSHOT_SIZE=1240x720` sets the main window's size first,
  `HOATZIN_APPEARANCE=light` or `dark` the appearance.
* `HOATZIN_DEMO_PROXMOX=/path/proxmox.json`: fill Proxmox servers from a file instead of their API
  (see `docs/demo`). Usage, graphs and storage of those servers are made up (`DemoMetrics.swift`).
  `-metricsTimeframe live -proxmoxRefreshInterval 2` on the app's command line opens the graphs
  in *Live*, updated every 2 seconds. `HOATZIN_DEMO_LOGGED_OUT=1` makes the demo servers act as
  if the login had expired, to see what the graphs and the guest list show then.
* `HOATZIN_SELECT=<entry name>`: select that entry on launch, or else the Proxmox node or guest
  of that name. `HOATZIN_AUTOCONNECT=<entry name>`
  connects to that SSH entry.
* `scripts/screenshots.sh`: retakes the README screenshots from the demo data in `docs/demo`, in
  light and dark. Your own library and settings are neither shown nor changed.
* `HOATZIN_OPEN_ABOUT=1` / `HOATZIN_OPEN_SETTINGS=1`: open the About panel or Settings on launch.
  `-settingsPane ai` on the app's command line picks the section Settings shows (`ssh`,
  `defaultLogin`, `passwords`, `proxmox`, `sidebar`, `library`, `ai`, `shortcuts`).
* `-AppleLanguages "(en)"` (or `"(de)"`) on the app's command line: run in that language once.
* `HOATZIN_SYNC_ZONE=Test-1` with `HOATZIN_LIBRARY` and `-iCloudSync YES`: sync that library with
  its own iCloud zone, e.g. two instances with two libraries to try merging. A library other than
  your real one syncs only with such a zone, never with your real library.
  `HOATZIN_SYNC_CHOICE=merge` (or `useICloud`, `useThisMac`) answers the first-sync question;
  `HOATZIN_SYNC_DELETE_ZONE=1` deletes the test zone instead of syncing (never the real one).
* `HOATZIN_SSHD_PORT=22222 swift test --filter SSHIntegrationTests`: checks against a local sshd
  that real ssh routes its prompts through the helper, both the built-in way and the launcher way.
* `HOATZIN_SSHD_PORT=22222 HOATZIN_SSHD_KEY=<key> HOATZIN_SSHD_KNOWN_HOSTS=<file> swift test
  --filter RemoteCommandIntegrationTests`: runs AI commands against a local sshd that accepts that
  key. It covers output, exit codes, timeouts, long output, refused host keys and password prompts.
