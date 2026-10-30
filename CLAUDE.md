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
5 Snippets ✅ (v0.6) · 6 Drop shelf ✅ (v0.7) · 7 Download manager · 8 Screenshots · 9 Gestures · 10 Automation/macros.
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
- All data lives in `~/Library/Application Support/Toolbelt/` (settings in `settings.plist`, not UserDefaults).

## Building

- No Xcode project: `build.sh` compiles every file under `Sources/` with `swiftc`; `install.sh` builds,
  copies to /Applications and launches. Keep `install.sh` a single command.
- Development happens on Linux without a Swift/macOS SDK, so the GitHub Actions workflow
  (`.github/workflows/build.yml`, macOS runner) is the test environment. Keep it green. It:
  1. builds the app (`build.sh`);
  2. runs `test.sh` — `Tests/Tests.swift` compiled with every source except `Sources/App/App.swift`,
     using a scratch data folder (`TOOLBELT_DATA_DIR`). Add checks there for each new feature;
  3. runs `.github/scripts/screenshots.sh` — launches the app once per screen (`TOOLBELT_SHOW`),
     fails if it crashes, and publishes screenshots to the `ci-screenshots` branch. Fetch them
     (`git fetch origin ci-screenshots`, then `git show FETCH_HEAD:<name>.png`) and look at them.
     Add a `TOOLBELT_SHOW` case and a screenshot for each new window or panel.
