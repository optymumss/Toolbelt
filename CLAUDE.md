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
5 Snippets ✅ (v0.6) · 6 Drop shelf ✅ (v0.7) · 7 Download manager ✅ (v0.8) · 8 Screenshots ✅ (v0.16) · 9 Gestures ✅ (v0.17) · 10 Automation/macros ✅ (v0.18). DMG install ✅ (v0.19). Video sizes + trackpad scroll/double tap ✅ (v0.20). BetterTouchTool parity + web server ✅ (v0.21). IDM-style unlimited parallel downloads ✅ (v0.22). Triggers window + conditions ✅ (v0.23). Key phases, repeat, sides, layout, more gestures ✅ (v0.24). Real-use + stability tests ✅ (v0.25). Rotate/edge/TipSwipe, wheel, screen corners, Hyper key, key remap, Mac-event triggers ✅ (v0.26). Mouse/web-search/Shortcuts actions + Bluetooth, Wi-Fi, Dock, Trash, eject, screen saver, emoji ✅ (v0.27). Floating menus, menu-bar items, presets ✅ (v0.28). Macro editor: record, step menu, undo, export, used shortcuts, timeouts/failures ✅ (v0.29). Macro triggers (clipboard, start/login, window/title) + Pause until + Mac conditions ✅ (v0.30). KM actions: apps, windows, files, browser, download, speech, prompts ✅ (v0.31). Calculations, picture filters, sub-macros, palettes, Macros window lists/back/helper, non-blocking prompts ✅ (v0.32). Self-update from GitHub releases ✅ (v0.33). Download all links, site grabber, copied links, category folders ✅ (v0.34).
[Core] items of every module first, then [Next], then [Later].

## Code layout

- `Sources/App/` — app shell: `Modules.swift` (`ModuleID`, `ToolbeltModule`, `ModuleManager`),
  `Shortcuts.swift` (`ShortcutAction`, `ShortcutCenter`, Carbon `HotKey`), `Permissions.swift`,
  `SettingsStore.swift` (`Prefs`), `StatusMenu.swift`. `Updater.swift` (0.33): `ReleaseFeed` (GitHub
  releases/latest, or TOOLBELT_UPDATE_URL in tests), `AppVersion` (numeric compare; TOOLBELT_PRETEND_VERSION),
  `Updater.unpack` (mount DMG, check bundle ID + version, ditto to a staging copy beside the app), `UpdateSwap.script`
  (waits for the pid, swaps with rollback, relaunches). The release step puts the README's "What's new in <version>"
  into the release notes, so bump the version and write that section for every release.
- `Sources/Settings/` — Settings window: General, Shortcuts, Permissions, and one tab per module.
- `Sources/<Module>/` — one folder per module. A module conforms to `ToolbeltModule`, adds a
  `ModuleID` case, its `ShortcutAction` cases, and is registered in `AppDelegate`.
- A module can make its items searchable from the launcher by returning a `LauncherProvider`
  from `launcherProvider` (see `ClipboardLauncherProvider`).
- `Sources/Actions/` — `MacroAction` and `ActionRunner`: everything a gesture or macro can do. Gestures and
  Automation share it, so every trigger can run every action.
  `MoreActions.swift`: `MouseCommand` (saved as text in `value`: "rightClick 300,200", top-left screen points; no
  place = the pointer) and `MouseDriver` (events marked `ownEventMarker`), `WebSearch` (⌘C, restore clipboard,
  %s template), `BluetoothPower` (IOBluetooth's private power call via dlsym), `WiFiPower` (CoreWLAN), `Trash`
  (Finder AppleScript), `Disks` (ejectable volumes). `MouseCommand.origin` (.screen / .window "click window 30,40" /
  .image "click image /path"), resolved by `MouseDriver.resolved` (async).
  `KMActions.swift` (0.31): `MacroAction.option` (an AppCommand/WindowCommand/FileCommand/BrowserCommand) and
  `value2` (destination, browser, voice); `MoreMacroActions.perform` (async, returns success; `MacroRun` awaits it
  and treats false as a failure), `BrowserScript` (AppleScript + JS, pure), `FileActions`, `WindowFrame`,
  `KeyboardLayouts` (TIS), `SystemSounds`, `LargeText`, `AppHistory` (previous app), `Downloader`, `BrowserPart`.
  Steps `.readFile`, `.browserGet`, `.alert`, `.askFolder`/`.askFile`, `.askSeveral` (closures on `MacroRun` for tests).
  `Automation/MacroExtras.swift` (0.32): `MacroCalculator` (own parser, never NSExpression), `MacroInputs`, `PictureFilter`
  (CG transforms, `contentBox` trim, OCR via `ImageText`), `ClipboardFilterHooks` (clipboard history's "Run Macro on
  It"), `PromptPanel` (non-modal NSPanel + continuation; all question closures on `MacroRun` are async).
  Steps `.calculate`, `.pictureFilter` (`MacroStep.picture`), `.runMacro` (`MacroRun.runMacro` closure + `depth`,
  limit 10; `AutomationModule.runSubMacro` returns %Result%). `Macro.modified` stamped by `MacroStore.stamped`;
  `MacroListFilter`, `SelectionHistory`, `NewMacroHelper`. `FloatingMenu.apps` = palette (`PanelController.updatePalettes`).
- `Sources/Automation/` — macros: `MacroModel` (macros, groups, triggers, steps), `MacroEngine` (`MacroRun`:
  variables, conditions, loops), `SystemHelpers` (menu items by name, resolution, sound output, other
  keyboards, Wi-Fi), `AutomationModule` (watches only the triggers macros use), `MacroEditor` (the Macros window).
  Typed-text and gesture triggers are handed to the Gestures module as extra rules.
  `MacroTools`: `StepClipboard` (copy/paste steps), `MacroTransfer` (.toolbeltmacros export/import with new ids),
  `UsedShortcuts`, `UndoHistory`, `RecordingBuilder` (pure) + `MacroRecorder` (listen-only tap, stop ⌃⌥⌘.).
  `MacroStep` has `disabled`, `note`, `color`, `timeout`, `onFailure`; `MacroRun.runProcess` enforces timeouts.
  `MacroConditions.swift`: `ConditionWorld` (what conditions ask about the Mac; `.live`, or made-up answers in tests;
  `MacroRun.isTrue` is async), `ModifierNames`, `RGBColor`, `GrayImage` + `ImageFinder` (pure picture search),
  `ScreenReader` (screencapture), `WindowChangeTracker` (pure) + `FrontWindowWatcher` (AXObserver, no polling),
  `ClipboardWatcher` (0.5 s, only while a macro uses it), `LoginTime` (utmpx console login). `.pauseUntil` uses
  `timeout` (default 60 s) and `onFailure`. Clipboard-triggered macros don't re-trigger from their own copies.
  Test mode: `RealUseHooks.commands` ("record-start:Name", "record-stop") via a distributed notification.
  `WebServer` (BetterTouchTool-style HTTP API + button page; `WebAPI` is the testable part), off by default,
  shared secret required, 127.0.0.1 only unless "other devices" is on.
- Triggers (Gestures folder): `TriggersWindow` (4 columns: scope sidebar · trigger list with category bar · actions ·
  settings), `Conditions` (`ConditionGroup` all/any/none, nested `ConditionNode`s, `ActivationGroup`,
  `ConditionContext.current()` built only when a matching rule needs it). `GestureRule.matches` picks the most
  specific rule (condition > group > app > everywhere) plus `parallel` ones. `HUD` (Sources/App) shows messages.
  Shortcuts with phase actions/repeat/sides/layout (`needsKeyWatching`) go through an active key tap
  (`GestureEventTap.watchTap` → `GesturesModule.keyEvent`), others through Carbon hot keys. `TriggerPhase` actions;
  touch "fingers lift" via `MultitouchReader.onLift`; Force Click via pressure events (type 34) in the mouse tap.
  Edge swipes and TipSwipes come with the plain swipe after them; when the specific one ran a rule, the plain
  one is skipped (`isMoreSpecificSwipe`, in `MultitouchReader`'s dispatch). `.wheel` (tilt, or button + scroll;
  `WheelDetector`, scrollWheel in the mouse tap) and `.screenSpot` (`ScreenSpot.at`, `ScreenSpotWatcher` via
  mouse-moved monitors). `KeyRemapper`: hidutil UserKeyMapping (Caps Lock → F18 for the Hyper key, plus
  `KeyRemap`s), an active tap adding ⌃⌥⇧⌘ while F18 is held; cleared on quit (`keys.applied` tracks it).
- Presets: `TriggerPreset` (Conditions.swift), `GestureRule.presetID`, `GestureStore.presets`/`activePreset`
  (presets.json, `triggers.preset`); `GesturesModule.allRules` filters by preset, so hot keys follow the switch.
- Floating menus and menu-bar items (`Automation/FloatingMenus.swift`): `PanelStore` (panels.json), `PanelController`
  (non-activating floating `NSPanel`s with `FirstClickHostingView`; `NSStatusItem`s whose title comes from a shell
  script on a timer, min 5 s). Actions `.floatingMenu` and `.switchPreset` go through `ActionRunner` hooks.
  In test mode `RealUseHooks.extraStatus` reports showing menus, menu-bar titles/frames and the active preset.
- Mac-event macro triggers (`SystemEvents.swift`): sleep/wake and disks from NSWorkspace, lock/unlock from
  distributed notifications, `PowerWatcher` (IOPS), `USBWatcher` (IOKit), `BluetoothWatcher` (IOBluetooth,
  needs NSBluetoothAlwaysUsageDescription), idle via `InputIdle` polled every 30 s (2 s while idle).
- Download all links (0.34, `Downloads/LinkGrabber.swift`, pure): `CategoryRule`/`DownloadCategories` (Prefs.downloadCategories;
  a category's own folder wins, else downloads folder [+ category name when sorting]; `DownloadItem.folder` overrides),
  `LinkExtractor` (regex over tags; <base>, srcset, css url()), `FoundLink`/`LinkSelection` (kinds = categories + "Web
  pages"; files ticked, pages not), `ClipboardLinks.offer`, `GrabTemplate`/`GrabSettings`/`SiteGrabber` (BFS with an
  injected fetch; `explore` lists files, `mirror` saves an offline copy) and `OfflinePaths` (paths + link rewriting).
  `LinkPickerView.swift`: `LinkPickerModel`/`LinkPickerWindows`, `GrabberModel`/`GrabberWindow` (URLSession fetch/save),
  `LinkOfferPanel` (copied link → "Download?", 15 s). Chrome: video.js answers "collect-links" (top frame), background
  `sendPageLinks` → native "links" message (cookiesByHost) → Bridge `handOverLinks` → inbox → `DownloadRequest.links`.
  Test hooks: grab:<template> <depth> <url>, picker-kind/search/download/close, link-offer-accept, catch-clipboard:on|off;
  status keys grabber, linkPicker, linkOffer. chrome.sh runs Toolbelt with TOOLBELT_E2E=1 to read linkPicker.
- `Chrome/` — the Chrome extension (Manifest V3, loaded unpacked; its fixed ID comes from the `key`).
  `Bridge/main.swift` — `ToolbeltBridge`, the native-messaging helper Chrome starts; it writes requests into
  `<data>/inbox/`, which `BrowserInbox` watches. `build.sh` builds both into the app bundle.
- Streamed video (HLS): `HLSPlaylist` (reads .m3u8), `TSDemuxer` (MPEG-TS → frames, pure logic), `VideoRemuxer`
  (AVAssetWriter passthrough into .mp4; fragmented MP4 is concatenated), `HLSDownloadJob` (pieces, AES-128, resume).
  Test streams in `Tests/Fixtures/hls` (made with ffmpeg: 4 s, 360p/720p/1080p, fMP4, AES-128, separate sound).
  The Chrome extension finds playlists with `webRequest` (filtered to `*.m3u8*`) and lists their sizes.
  Parallel downloads: queues default to no limit (`maxAtOnce` 0); `ConnectionBudget` (160) is shared by all
  streams (each always gets one), `HLSDownloadJob.joinGate` allows two joins at once, `DownloadManager`
  raises RLIMIT_NOFILE and pauses everything under 2 GB free (`checkSpace`).
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
  4. runs `.github/scripts/real-use.sh` — builds `E2E/RealUse.swift` (with all sources except App.swift)
     into `ToolbeltE2E.app`, writes TCC grants for both apps (SIP is off on GitHub's Macs), opens it with
     `open` (so each app is its own "responsible process"), and it starts Toolbelt with `TOOLBELT_E2E=1`
     and drives it with CGEvents and pretend touches (`RealUseHooks`, a distributed notification into
     `MultitouchReader.injectForTesting`). Actions are checked through shell actions writing to
     `markers.txt`, the test window's text and frame, and Toolbelt's windows. Every PR; `stability 20`
     on full runs. Add a real-use check for each new trigger or action. Test shortcuts use ⌃⌥⇧
     (⌃⌥⌘ + digits are saved layouts).
