# Toolbelt — notes for Claude

Personal macOS 26 menu-bar app in Swift + SwiftUI that replaces Keyboard Maestro, BetterTouchTool,
Raycast, Dropover, Dropzone, Paste and IDM. Not sandboxed, not on the App Store.

## Working with the owner

- The owner is not a developer. Explain in plain words; give exact build/install/test steps.
- Before building each module, describe in plain words what it will do and wait for confirmation.
- After each module: exact steps to build, install and test, plus a short checklist of things to try.
- Tell the owner before building anything that can't work on macOS or needs a paid Apple developer account.
- Permissions (Accessibility, Input Monitoring, Screen Recording) are requested only when a feature needs
  them — use `PermissionGate.ensure`. Ad-hoc signing means macOS forgets them after every rebuild; say so.

## Build order

1 App shell ✅ (v0.2) · 2 Clipboard ✅ (v0.3) · 3 Launcher ✅ (v0.4) · 4 Window management ✅ (v0.5) ·
5 Snippets ✅ (v0.6) · 6 Drop shelf ✅ (v0.7) · 7 Download manager ✅ (v0.8) · 8 Screenshots ✅ (v0.16) · 9 Gestures ✅ (v0.17) · 10 Automation/macros ✅ (v0.18). DMG install ✅ (v0.19). Video sizes + trackpad scroll/double tap ✅ (v0.20).
[Core] items of every module first, then [Next], then [Later].

## Code layout

- `Sources/App/` — app shell: `Modules.swift` (`ModuleID`, `ToolbeltModule`, `ModuleManager`),
  `Shortcuts.swift` (`ShortcutAction`, `ShortcutCenter`, Carbon `HotKey`), `Permissions.swift`,
  `SettingsStore.swift` (`Prefs`), `StatusMenu.swift`.
- `Sources/Settings/` — Settings window: General, Shortcuts, Permissions, and one tab per module.
- `Sources/<Module>/` — one folder per module. A module conforms to `ToolbeltModule`, adds a
  `ModuleID` case, its `ShortcutAction` cases, and is registered in `AppDelegate`.
- A module can make its items searchable from the launcher by returning a `LauncherProvider`
  from `launcherProvider` (see `ClipboardLauncherProvider`).
- `Sources/Actions/` — `MacroAction` and `ActionRunner`: everything a gesture or macro can do. Gestures and
  Automation share it, so every trigger can run every action.
- `Sources/Automation/` — macros: `MacroModel` (macros, groups, triggers, steps), `MacroEngine` (`MacroRun`:
  variables, conditions, loops), `SystemHelpers` (menu items by name, resolution, sound output, other
  keyboards, Wi-Fi), `AutomationModule` (watches only the triggers macros use), `MacroEditor` (the Macros window).
  Typed-text and gesture triggers are handed to the Gestures module as extra rules.
- `Chrome/` — the Chrome extension (Manifest V3, loaded unpacked; its fixed ID comes from the `key`).
  `Bridge/main.swift` — `ToolbeltBridge`, the native-messaging helper Chrome starts; it writes requests into
  `<data>/inbox/`, which `BrowserInbox` watches. `build.sh` builds both into the app bundle.
- Streamed video (HLS): `HLSPlaylist` (reads .m3u8), `TSDemuxer` (MPEG-TS → frames, pure logic), `VideoRemuxer`
  (AVAssetWriter passthrough into .mp4; fragmented MP4 is concatenated), `HLSDownloadJob` (pieces, AES-128, resume).
  Test streams in `Tests/Fixtures/hls` (made with ffmpeg: 4 s, 360p/720p/1080p, fMP4, AES-128, separate sound).
  The Chrome extension finds playlists with `webRequest` (filtered to `*.m3u8*`) and lists their sizes.
- All data lives in `~/Library/Application Support/Toolbelt/` (settings in `settings.plist`, not UserDefaults).

## Building

- No Xcode project: `build.sh` compiles every file under `Sources/` with `swiftc`; `install.sh` builds,
  copies to /Applications and launches. Keep `install.sh` a single command. `package.sh` packs
  `build/Toolbelt.dmg` (app + Applications shortcut); CI opens it and starts the app from it
  (`.github/scripts/dmg.sh`), and on main attaches it to the release `v<CFBundleShortVersionString>` —
  bump the version in `Info.plist` for each new release.
- Development happens on Linux without a Swift/macOS SDK, so the GitHub Actions workflow
  (`.github/workflows/build.yml`, macOS runner) is the test environment. Keep it green.
  macOS minutes count 10× against the account's allowance, so: pull requests only build and test;
  the battery check, Chrome test and screenshots run on main and when started by hand
  (Actions → Build → Run workflow). Docs-only changes don't run; a newer push cancels the older run.
  Don't start extra runs on branches that aren't PRs. The steps are:
  1. builds the app (`build.sh`);
  2. runs `test.sh` — `Tests/Tests.swift` compiled with every source except `Sources/App/App.swift`,
     using a scratch data folder (`TOOLBELT_DATA_DIR`). Add checks there for each new feature;
  3. runs `.github/scripts/screenshots.sh` — launches the app once per screen (`TOOLBELT_SHOW`),
     fails if it crashes, and publishes screenshots to the `ci-screenshots` branch. Fetch them
     (`git fetch origin ci-screenshots`, then `git show FETCH_HEAD:<name>.png`) and look at them.
     Add a `TOOLBELT_SHOW` case and a screenshot for each new window or panel.
