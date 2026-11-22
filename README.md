# Hoatzin

The [hoatzin](https://en.wikipedia.org/wiki/Hoatzin) is a funny bird from the swamps of the Amazon:
a punk crest, a blue face and red eyes. Its chicks climb through branches with claws on their wings,
and it digests leaves in its crop much like a cow, which earned it the nickname "stinkbird". This
app shares its name, not its smell.

Hoatzin is a native macOS connection manager: a sidebar tree of folders and SSH connections, plus
Proxmox VE servers whose VMs and containers are listed live. Each connection opens via SSH (in
iTerm2, Terminal or a built-in tab) or through the Proxmox console (xterm.js / noVNC).

## Why Hoatzin

* **Every credential stays in the macOS Keychain.** Hoatzin stores hosts, users and ports, never a
  password. Passwords come from your login keychain after Touch ID, or from the Passwords app via
  AutoFill. They reach ssh through a private socket, never through files, environment variables or
  command lines.
* **It works like a Mac app.** Native SwiftUI and AppKit instead of a web page in a window. Touch ID,
  the Keychain, Shortcuts, Siri and Spotlight are built in, the keyboard shortcuts are the familiar
  ones, and it speaks English and German.
* **AI apps can help with your servers, and you stay in charge.** Through its MCP server, Claude and
  other AI apps can find connections, read terminal tabs, open sessions and run commands. Hoatzin
  shows you every action before it happens, logs it, and never hands a password to the AI.

## Build & run

```bash
scripts/build-app.sh             # → build/Hoatzin.app, signed with your certificate
scripts/build-app.sh --notarize  # also notarizes it, so it opens on other Macs
scripts/build-app.sh --install   # also copies it to ~/Applications
```

### Signing and notarization

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
     *Schlüsselbundverwaltung → Zertifikatsassistent*. Then double-click the downloaded `.cer`.
   * If `security find-identity -v -p codesigning` then still lists no valid identity, Apple's
     intermediate certificate is missing. Install it from
     apple.com/certificateauthority (*Developer ID – G2*); Xcode normally adds it.
2. **Build:** run `scripts/build-app.sh`. It prints `Signed as: Developer ID Application: … (TEAM ID)`.
   The first time, allow codesign to use the key (*Immer erlauben*).
3. **Notarization (for other Macs):**
   * Create an app-specific password at account.apple.com (*Sign-In and Security*).
   * Store it in your keychain with
     `xcrun notarytool store-credentials hoatzin-notary --apple-id <your Apple Account> --team-id <TEAM ID>`.
     It asks for the password; nothing is written to the repo.
   * Then `scripts/build-app.sh --notarize` notarizes and staples the app.

The script also writes `Contents/Resources/Acknowledgements.json`, the libraries shown in
*About Hoatzin*. `scripts/acknowledgements.swift` builds it from the package's direct dependencies,
the versions in `Package.resolved` and each checkout's license file. A new dependency only needs a
one-line purpose there. Today the only bundled library is SwiftTerm (MIT).

It also generates the App Intents metadata (`Contents/Resources/Metadata.appintents`) that
Shortcuts, Siri and Spotlight read. Xcode does that for Xcode projects, SwiftPM doesn't, so the
script runs Xcode's `appintentsmetadataprocessor` and `appintentsnltrainingprocessor` on the
compiler's constant-value output. It then registers the app with Launch Services. macOS lists the
actions once the new build has been launched.

The app icon is made from `Resources/AppIcon-source.png` by `scripts/make-icon.swift`, again
whenever that image changes. The script finds the artwork's rounded square, cuts it out onto a
transparent background with a fitted squircle mask, places it on Apple's icon grid with a soft
shadow, and writes all sizes into `Resources/AppIcon.icns`.

Needs Xcode installed. The macOS 27 SDK's SwiftUI macros ship with Xcode, not with the Command
Line Tools, and the script selects Xcode automatically. Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

### Releasing

Releases go to GitHub with the notarized app attached as a zip. Once, create the repository and
connect it:

```bash
gh repo create <owner>/hoatzin --public --source . --remote origin
```

Then each release is one command:

```bash
scripts/release.sh 1.0.1               # or --prerelease, or --notes-file notes.md
scripts/release.sh 1.0.1 --dry-run     # build and package only, nothing published
```

`scripts/release.sh` does the following:

1. **Checks:** everything is committed, you're on `main`, the tag is new and the version is not
   older than the current one.
2. **Version:** it sets the version in `Resources/Info.plist` and raises the build number.
3. **Build:** it runs the tests, builds, signs and notarizes the app. It then checks that the
   notarization is stapled and that Gatekeeper accepts the app.
4. **Package:** it zips the app with `ditto`, which keeps signature and notarization intact.
5. **Publish:** it commits the version, tags `v<version>`, pushes, and creates the GitHub release.
   The release notes come from the commits, or from `--notes-file`, and include the zip's SHA-256.

## Credentials: what lives where

| Data | Stored in |
|---|---|
| Folders, names, hosts, ports, users, key-file paths, pinned Proxmox certificate fingerprint | `~/Library/Application Support/Hoatzin/library.json` |
| Passwords / key passphrases | macOS **login keychain** as internet-password items (server + account + protocol), visible in Keychain Access |
| Proxmox auth ticket | memory only |

**The Passwords app can't be read directly.** Its entries live in the iCloud/data-protection
keychain, which Apple restricts to Safari, the Passwords app and AutoFill. No third-party app can
query it, however it is signed. Hoatzin uses the supported path instead:

1. On connect, it looks for a Keychain item for `user @ host` (e.g. `root @ 10.20.30.192`, protocol ssh;
   Proxmox logins use protocol https).
2. If there is none, a sheet opens with AutoFill-enabled fields. Pick the entry from Passwords
   (key icon / Touch ID), or use *Copy host* + *Open Passwords* and paste.
3. With *Remember in the macOS Keychain* checked, the password is saved to the Keychain after ssh
   or Proxmox accepts it. Later connects need no prompt.

The *Keychain entry* field on a connection lets several connections share one stored password.

**Touch ID:** before Hoatzin uses a saved password it asks for Touch ID (or your Mac password),
then stays unlocked for a grace period (default 5 minutes; Settings → Passwords). It locks again
when the Mac sleeps or the screen locks, or via *Connection → Lock Saved Passwords* (⌥⌘L). This
check is enforced by the app. Keychain-enforced biometry would need an Apple-issued signing identity.

**Keychain prompts after rebuilds:** an ad-hoc signed build has a new code hash every time, so
macOS asks again after each rebuild (use *Always Allow*). Signed with your team's certificate, the
app keeps one identity across builds. After the first *Always Allow* for a signed build, rebuilds
no longer ask.

### How ssh gets the password

`ssh` runs with `SSH_ASKPASS=…/hoatzin-askpass` and `SSH_ASKPASS_REQUIRE=force`. The helper
forwards ssh's prompts (password, host-key confirmation, key passphrase, OTP) to the app over a
Unix socket in the per-user temp dir (mode 600). Passwords never appear in environment variables,
files or command lines, so this works the same in iTerm2 and Terminal.app.

Each session gets a random token, and the token is bound to one process. A built-in tab binds it
to the ssh it starts. The iTerm2 / Terminal launcher binds it to its own shell right before
`exec ssh`, which keeps the same process. The app only answers a request when:

* the caller runs as the same user;
* the caller is the bundled helper binary;
* the helper was started by `/usr/bin/ssh`;
* that ssh is the bound process or a child of it (ProxyJump);
* the token hasn't expired and its process is still running.

So another program that reads the token from ssh's environment can't use it, neither directly
nor by starting its own ssh. If something else binds a token first, the second bind revokes it
and the launch stops with a message in the terminal. Refusals are logged as
`Hoatzin: askpass request refused: …` (Console.app).

## Proxmox

* Add a server with host (port 8006), user and realm. The certificate is pinned on first use (TOFU)
  after you compare the SHA-256 fingerprint.
* Two-factor (TOTP) logins are supported (PVE 7+).
* Guest IPs come from the QEMU guest agent, LXC interfaces, or static `net*/ipconfig*` config.
  Override host, user or port per guest via *SSH Settings…*.
* The console is the Proxmox web console (xterm.js for containers and node shells, noVNC or serial
  for VMs) embedded in a tab, with the ticket held in a non-persistent web data store.
* Each guest shows its VMID as a grey pill at the right edge, with the IP to the left of it.

## Tabs

* **⌘W** closes the selected tab. With no tab open it does nothing, because closing the main
  window quits Hoatzin.
* **⇧⌘W** closes the window on purpose.
* **Other windows:** in Settings and AI Activity, ⌘W closes that window.

## Sidebar filter

The field above the sidebar (⌘F) narrows the tree in place:

* **What it matches:** names, VMIDs, IPs, hosts and SSH users, ignoring case and accents.
* **Several words:** every word has to match, either in an entry or in the folder or server it's
  in. So `office web` finds `web01` on the server Office.
* **Folders and servers:** a folder or server whose name matches keeps all its entries.
* **Keyboard:**
  * ↓ moves into the list.
  * Return connects to the selected match, or to the only match. With several matches it selects
    the first one.
  * Esc clears the filter. In the list, Esc also clears it and keeps the selection.
* **While filtering:** every branch is expanded, folders you collapsed stay collapsed afterwards,
  and drag & drop is off.

Long addresses in the sidebar are shortened at the start by default (…30.20), which keeps the part
that tells hosts apart. *Settings → Sidebar* switches to shortening at the end (10.20.3…).

## Languages

Hoatzin is in English and German and follows the Mac's language. The menus, windows, dialogs,
error messages and Shortcuts actions are translated, as are the Siri phrases and the AppleScript
permission text. To use another language for Hoatzin only, pick it in *System Settings →
General → Language & Region → Applications*.

* **Files:** the translations are in `Resources/de.lproj`:
  * `Localizable.strings`: the texts, keyed by the English text in the code.
  * `Localizable.stringsdict`: texts that depend on a count ("1 Eintrag", "3 Einträge"). English
    has one too.
  * `InfoPlist.strings`: the permission text from Info.plist.
  * `AppShortcuts.strings`: the Siri phrases.
* **Build check:** `scripts/build-app.sh` lets the compiler list every translatable text and runs
  `scripts/check-translations.swift`. The build fails if a text has no German translation or a
  translation lost a placeholder.
* **Stays English on purpose:** what AI apps receive (tool replies, MCP descriptions) and the
  entries in the AI activity log, which are stored data.

## AI access (MCP)

AI apps such as Claude can use Hoatzin through its MCP helper,
`Hoatzin.app/Contents/MacOS/hoatzin-mcp`. It's off until you choose a level in
*Settings → AI Access*:

| Level | The AI may |
|---|---|
| Off (default) | nothing; every call is refused with a hint where to turn it on |
| Read only | list connections and open tabs, read built-in SSH tabs (if *Include terminal output* is on) |
| Read and open tabs | also open an entry as an SSH tab or Proxmox console, after you confirm in Hoatzin |
| Read, open tabs and run commands | also run a command over SSH and type into built-in SSH tabs, each after you confirm |

**Tools:**
* `list_connections(filter)`: same filter as the sidebar.
* `get_connection(id)`
* `list_sessions`
* `read_session(session_id, lines)`
* `open_session(id, method)`: `ssh` or `console`.
* `run_command(id, command, timeout_seconds)`: runs one command without a terminal and returns
  the exit code, stdout and stderr. Default timeout 60 s, at most 300 s. Output over 64 KB keeps
  its first 16 KB and last 48 KB.
* `send_input(session_id, text, key, wait_seconds)`: types into a built-in SSH tab, then presses
  `key` (Return by default; also Tab, Esc, Control-C/D/Z, arrows or none). It returns the tab's
  last lines once the output has been quiet for a moment.

**Setup:** *Settings → AI Access* copies the right command for Claude Code
(`claude mcp add --scope user hoatzin <path>`) or the `mcpServers` entry for Claude Desktop's
`claude_desktop_config.json`. Hoatzin has to be running; otherwise the tools say so.

**Safety:**
* **No passwords:** the AI never sees passwords. Tabs it opens and commands it runs get them from
  the Keychain via Touch ID, like anything else.
* **You confirm every action:** a sheet names the AI app, the host and the exact command or text.
  * Characters that are invisible or reorder text (e.g. U+202E) are shown as `<U+202E>`, and
    control characters as `^C`, `⎋`, `⇥`, so what you approve is what runs.
  * Return doesn't approve, and the approve button works only after a second: the sheet can
    appear while you're typing in another app. Esc denies.
  * *Allow … for 15 minutes* skips the question for that entry (opening, commands) or that tab
    (typing). Changing the access level forgets these.
  * A question nobody answers closes after 5 minutes and counts as denied.
* **Host keys:** commands from AI apps never accept a new or changed host key. Connect once
  yourself first. ssh runs with `StrictHostKeyChecking=yes`, and also without agent or X11
  forwarding, port forwards, `LocalCommand` or a background `ControlMaster`. These options come
  first on the command line, so neither `~/.ssh/config` nor an entry's extra arguments can undo
  them. Host-key questions from a ProxyJump hop are answered "no".
* **Who can connect:** the helper reaches the app over a socket in the per-user temp dir
  (mode 600). Only the bundled helper binary, running as you, may connect.
* **Output is marked untrusted:** the AI is told to treat it as data, since a remote host could
  print text meant to steer an AI.
* **Activity log:** *Window → AI Activity* (or *Settings → AI Access → Show AI Activity…*)
  lists every call: time, app, tool, target, result, and the command or typed text.
  * It's stored in `~/Library/Logs/Hoatzin/ai-activity.jsonl` (mode 600). At 2 MB the file
    moves to `ai-activity.1.jsonl`.
  * Terminal output and passwords are never written there.
  * Each call also goes to Console.app as `Hoatzin AI: <app> called <tool>`.

## Shortcuts, Siri & Spotlight

Hoatzin's actions are in the Shortcuts app (search for "Hoatzin"):

| Action | What it does |
|---|---|
| Open Connection | Opens a connection like a double-click in the sidebar, or explicitly via SSH or the Proxmox console |
| Find Connections | Returns connections matching words, like the sidebar filter |
| Run Command over SSH | Runs a command and returns its output |

* **Results:** each connection Find Connections returns has Name, Kind, Address, SSH Login, VMID,
  Status and Location. The output of Run Command can go into the next action.
* **Run Command errors:** a non-zero exit code is an error in Shortcuts, and the message includes
  stderr. Add `|| true` to a command when that's expected.
* **Siri and Spotlight:** they offer the actions without any setup, in English and German. For
  example "Open web01 in Hoatzin" / "Öffne web01 in Hoatzin", "Run a command on web01 with
  Hoatzin" / "Führe einen Befehl auf web01 mit Hoatzin aus", or "Find connections in
  Hoatzin" / "Suche Verbindungen in Hoatzin".
  * The phrases live in `Resources/<lang>.lproj/AppShortcuts.strings`, keyed by the English phrase
    in `Intents.swift`. A test checks that the files match the code and keep every placeholder.
  * Shortcuts shows the actions in German too (see *Languages*).
* **Spotlight results (macOS 15+):** connections are searchable by name, address, login and VMID,
  and picking one opens it. The index holds names, addresses and logins, never passwords. Turn it
  off in *Settings → Shortcuts, Siri & Spotlight*.
* **Proxmox data:** VMs and containers are loaded when an action needs them, which can ask for
  Touch ID.

**Run Command safety:**
* **Setting:** *Settings → Shortcuts, Siri & Spotlight → Run Command action* is *Off*, *Ask each
  time* (default) or *Run without asking*. Asking shows the host, the login and the exact
  command, with hidden characters made visible. Choose *Run without asking* only for shortcuts
  that must run unattended: any shortcut, Siri or Apple Intelligence can then run commands.
* **Same ssh rules as AI commands:** no new or changed host keys, no forwarding, and passwords
  from the Keychain via Touch ID.
* **Logging:** every run, including denied ones, goes to *Window → AI Activity* as
  "Shortcuts & Siri".

## Settings

*Hoatzin → Settings…* chooses where SSH sessions open (iTerm2 by default, Terminal, or the
built-in tab). New iTerm2 sessions open as tabs in the front window via AppleScript (macOS asks
once for Automation permission); otherwise iTerm2 opens a new window.

## Debug aids

* `HOATZIN_LIBRARY=/path/library.json`: use another library file.
* `HOATZIN_CONTROL_SOCKET=/path.sock` (app and helper): use another AI control socket, e.g. for a
  second test instance. `-aiAccess commands` on the app's command line sets the level for that run only.
* `HOATZIN_AI_LOG=/path.jsonl`: use another AI activity log. With `HOATZIN_LIBRARY` set, the
  log goes next to that library file instead of `~/Library/Logs`.
* `HOATZIN_SNAPSHOT=/path/prefix`: render the app's own windows to PNGs after 3 s.
* `HOATZIN_AUTOCONNECT=<entry name>`: connect to that SSH entry on launch.
* `HOATZIN_OPEN_ABOUT=1` / `HOATZIN_OPEN_SETTINGS=1`: open the About panel or Settings on launch.
* `-AppleLanguages "(en)"` (or `"(de)"`) on the app's command line: run in that language once.
* `HOATZIN_SSHD_PORT=22222 swift test --filter SSHIntegrationTests`: checks against a local sshd
  that real ssh routes its prompts through the helper, both the built-in way and the launcher way.
* `HOATZIN_SSHD_PORT=22222 HOATZIN_SSHD_KEY=<key> HOATZIN_SSHD_KNOWN_HOSTS=<file> swift test
  --filter RemoteCommandIntegrationTests`: runs AI commands against a local sshd that accepts that
  key. It covers output, exit codes, timeouts, long output, refused host keys and password prompts.

## License

Copyright © 2026 Akitogo Internet and Media Applications GmbH.

Hoatzin is free software: you may use, change and pass it on, also commercially, under the terms
of the GNU General Public License, version 3 (see `LICENSE`). Whoever distributes a changed version
has to publish its source code under the same license.

The name "Hoatzin" and the app icon (`Resources/AppIcon-source.png`, `Resources/AppIcon.icns`) are
not covered by the GPL. Forks need their own name and icon.

Bundled third-party code: SwiftTerm (MIT License), listed with its license text in *About Hoatzin*.
