# How Toolbelt is tested

Every change runs on a real Mac at GitHub (macOS 26, Apple silicon) before it reaches `main`:

1. **Build** — `build.sh` (optimised, whole-module).
2. **Automated tests** — `test.sh` runs `Tests/Tests.swift`: logic tests against the real code, plus
   *end-to-end* tests that start the real app and use it with real key presses in TextEdit and Calculator.
3. **Disk image** — `package.sh` packs `Toolbelt.dmg`; `.github/scripts/dmg.sh` opens it, checks the app,
   the Applications shortcut, the Chrome helper and the signature are inside, and starts the app from it.
   On `main` the DMG is attached to the GitHub release for its version.
4. **Battery check** — `.github/scripts/energy.sh` leaves the app idle with every module on (and again
   after opening every Settings tab) and fails if it uses more than 1% of a CPU core or wakes the
   processor more than 15 times a second.
5. **Screenshots** — `.github/scripts/screenshots.sh` opens every screen, fails if the app crashes, and
   publishes the pictures to the `ci-screenshots` branch, where they're checked by eye.

Some things need a person: they depend on hardware or on permissions a test machine can't grant.
They're marked **Manual** below and are in the checklist that comes with each release.

## Feature → test

| Module | Feature | Covered by |
|---|---|---|
| App | Menu-bar icon and menu | Screenshot `menu` |
| App | Settings with a tab per module, on/off switches | Tests "Modules"; screenshots `settings-*` |
| App | Open at login | **Manual** (needs the app in /Applications) |
| App | Permissions page | Screenshot `settings-permissions` |
| App | Changeable shortcuts, warnings when taken | Tests "Shortcuts", "Launcher: quicklinks and commands" |
| App | Light and dark mode | Tests "Settings" |
| App | Pause Toolbelt | Tests "Modules" |
| App | Settings kept in Application Support, migrated from 0.1 | Tests "Settings" |
| App | Battery use while idle | Battery check |
| App | DMG install (opens, holds the app, app starts from it) | Disk image check; **Manual** for the first-open "Open Anyway" step |
| Clipboard | Records text, links, images, screenshots, Finder files | Tests "Clipboard recording", "Images, links and iPhone copies" |
| Clipboard | iPhone/iPad (Universal Clipboard) copies | Tests "Images, links and iPhone copies"; **Manual** with a real iPhone |
| Clipboard | No duplicates, source app and time | Tests "Clipboard history" |
| Clipboard | Skips private items and ignored apps; pause | Tests "Clipboard recording" |
| Clipboard | ⌘⇧V panel, search, filters, ⌘1–9, keyboard use | Tests "Clipboard panel"; end-to-end "⌘⇧V opens…" |
| Clipboard | Return pastes into the app you were using | End-to-end "pressing Return pastes…" |
| Clipboard | ⌥Return plain text, image paste formats | Tests "Pasting", "Pasting images" |
| Clipboard | Large preview (Space) | Tests "Large preview"; screenshot `clipboard-preview` |
| Clipboard | Pin, delete, clear, history limit | Tests "Clipboard history" |
| Launcher | ⌥Space search bar | End-to-end "⌥Space opens the launcher" |
| Launcher | Apps, files, folders | Tests "Launcher: matching and ranking"; end-to-end "opens Calculator" |
| Launcher | Calculator and unit converter | Tests "Launcher: calculator", "unit converter"; end-to-end "6*7" |
| Launcher | Quicklinks | Tests "Launcher: quicklinks and commands" |
| Launcher | System commands | Tests (found by name); **Manual** to actually lock/sleep/restart |
| Launcher | Searches every module | Tests for clipboard, windows, snippets, shelves, downloads providers |
| Windows | Halves, thirds, quarters, maximise, centre, restore | Tests "Windows: layouts"; "moving a real window"; end-to-end ⌃⌥← ⌃⌥↩ ⌃⌥⌫ |
| Windows | Drag to an edge or corner to snap | Tests "Windows: snapping"; screenshot `windows-snap-preview`; **Manual** for the drag itself |
| Windows | Move between displays | Tests "Windows: snapping and displays"; **Manual** with two screens |
| Snippets | Keyword expansion | Tests "Snippets: expanding in a real text field"; end-to-end ";ee" |
| Snippets | Placeholders | Tests "Snippets: placeholders" |
| Shelf | Open by shortcut, menu, shake | End-to-end ⌃⌥S; tests "Shelf: shaking to open"; **Manual** for a real shake |
| Shelf | Drop anything, drag out, several shelves, names, colours, Quick Look, link vs copy | Tests "Shelf: dropping and dragging out"; screenshot `shelf-demo`; **Manual** for real drag-and-drop |
| Downloads | Parts at once, HTTP/HTTPS, pause/resume, restart, retries | Tests "Downloads: real downloads from a test server" |
| Downloads | FTP | Tests (arguments); **Manual** against a real FTP server |
| Downloads | List with progress, speed, time left, size; drag out; sorting | Tests; screenshot `downloads` |
| App | Export and import settings | Tests "Settings backup" |
| App | Services / right-click menu | Tests "Services menu and right-click"; end-to-end “Add to Toolbelt Shelf” |
| App | Share menu | Not built: needs an app extension signed with a paid developer account |
| App | Apple Shortcuts | On hold (owner's decision) |
| Clipboard | Auto-delete by age | Tests "pinboards, named clipboards and auto-delete" |
| Clipboard | Layouts: list, grid, strip | Tests (frames); screenshots `clipboard-grid`, `clipboard-strip` |
| Clipboard | Paste stack | Tests; end-to-end "the paste stack pastes items in the order picked" |
| Clipboard | Edit before pasting | Tests; screenshot `clipboard-extras` |
| Clipboard | Drag items out of the panel | **Manual** (real drag-and-drop) |
| Clipboard | Pinboards | Tests; screenshot `clipboard-extras` |
| Clipboard | Named clipboards | Tests (incl. launcher) |
| Clipboard | Search text in images (OCR) | Tests "Clipboard: text in images" |
| Clipboard | Text transforms | Tests "transforms, editing and the paste stack" |
| Launcher | App and window switcher (quit, hide, close) | Tests "recently used, switcher and notes"; end-to-end ⌥⇥ ⌘H / Return; screenshot `launcher-switcher` |
| Launcher | Floating notes | Tests; end-to-end ⌃⌥N; screenshot `notes-demo` |
| Launcher | Recently used first | Tests "recently used, switcher and notes" |
| Snippets | Fill-in blanks | Tests "fill-in blanks, picker and folders"; end-to-end ";hi" → form → "Hello sam!"; screenshot `snippet-form` |
| Snippets | Searchable picker with a shortcut | Tests; end-to-end ⌃⌥; ; screenshot `snippet-picker` |
| Snippets | Folders | Tests |
| Windows | Saved layouts | Tests "saved layouts and snap areas" (save, move, apply, reopen app); end-to-end ⌃⌥⌘1 |
| Windows | Custom snap areas (draw, review, edit) | Tests (hit-testing, saving); screenshot `snap-areas-editor`; **Manual** for drawing and ⌥-dragging |
| Shelf | Drag to the notch or an edge | Tests (edge zones); **Manual** for a real drag |
| Shelf | New screenshots on a shelf | Tests (names, folder watching); end-to-end real screenshot |
| Shelf | Watch a folder | Tests "edges, watched folders, actions and drop targets" |
| Shelf | Zip, resize, convert, rename, copy paths | Tests (real files, sips, ditto, unzip) |
| Shelf | Drop-target grid: folders, apps, websites, actions | Tests (copy, move, paths, shelf); end-to-end ⌃⌥⌘G; screenshot `drop-grid`; **Manual** for drag-and-drop |
| Shelf | Shortcut per target (Finder selection) | **Manual** (needs Finder's permission) |
| Downloads | Queues with a limit on how many run at once | Tests "Downloads: queues, schedules, limits and the list" (3 real downloads, one at a time, in order) |
| Downloads | Start/stop queues by hand and at set times | Tests (stop/start with a real download; schedule maths incl. reopening Toolbelt mid-window); screenshot `downloads` |
| Downloads | Sleep or shut down when everything finishes | Tests (the choice is offered once, after the last download); **Manual** for the actual sleep/shut down |
| Downloads | Speed limit | Tests (6 MB at 1 MB/s takes over 4 s, file correct) |
| Downloads | Hourly data cap | Tests (fake clock: stops at the cap, carries on in the next hour, file correct) |
| Downloads | Notification when finished | Tests (the finish is announced); **Manual** for the banner itself (needs the installed app) |
| Downloads | Choose columns and buttons | Tests (list text per column, saved choices); screenshot `downloads` |
| Downloads | Chrome extension: hands downloads over | Tests "the Chrome extension and its bridge" (real bridge program, Chrome's message format, cookies, inbox → download list); CI step "Test the Chrome extension in Chrome": a download clicked in real Chrome finishes in Toolbelt, the popup says Connected |
| Downloads | Right-click "Download with Toolbelt" | **Manual** (Chrome's own menu can't be clicked by the test) |
| Downloads | Download button on web videos | CI step "Test the Chrome extension in Chrome": the button appears, downloads the video, and isn't shown on streamed (blob:) videos |
| Downloads | Other browsers (Safari, Firefox, Edge) | Not built (owner asked for Chrome only) |
| Screenshots | Capture the whole screen, an area | Tests (real captures with macOS's screencapture: whole screen, a given area) |
| Screenshots | Drag out an area / click a window | **Manual** (needs a person to drag or click; uses macOS's own crosshair) |
| Screenshots | Editor: arrows, boxes, text, highlight, blur, crop, undo/redo | Tests "Screenshots: capture, mark up and read text" (checks the actual pixels); screenshot `screenshot-editor` |
| Screenshots | Copy and save the marked-up picture | Tests (clipboard picture size, PNG file, never overwrites) |
| Screenshots | Copy text from a screenshot / from the screen (OCR) | Tests (reads "Invoice 42" back from a marked-up picture); **Manual** for ⌥⇧⌘2 |
| Screenshots | Shortcuts and launcher commands | Tests; screenshot `launcher-screenshot` |
| Gestures | Trackpad taps, swipes, pinches, clicks with 3+ fingers, corner clicks | Tests (recogniser fed made-up touches); **Manual** on a real trackpad (CI Macs have none) |
| Gestures | Magic Mouse gestures | Tests (recogniser); **Manual** with a Magic Mouse |
| Gestures | Extra mouse buttons | End-to-end: a real button-4 press runs its gesture in the app |
| Gestures | Mouse strokes (hold a button and draw) | Tests (stroke shapes); end-to-end: right-button stroke left runs its gesture |
| Gestures | Modifier taps (e.g. double-tap Shift) | Tests (taps, holds, combos ignored); end-to-end: double-tap right Shift |
| Gestures | Typed sequences | End-to-end: typing ;;z in TextEdit runs its gesture (types text in its place) |
| Gestures | Rules for certain apps only / except | Tests (only, except, app rule wins) |
| Gestures | Actions: Toolbelt commands, shell, AppleScript, open, keys, text, Mac controls | Tests (command, shell, AppleScript, addresses); end-to-end (shell, type text) |
| Gestures | Listens only while a rule needs it | Tests (tap starts and stops with the rules); battery check |
| Gestures | Trackpad reader status in Settings; nonsense touch data is ignored, not acted on | Tests "Gestures: trackpad, mouse and keys" |
| Automation | Trigger: keyboard shortcut | End-to-end: ⌃⌥⌘M runs a macro in the real app |
| Automation | Trigger: typed text, gesture | End-to-end: typing ;;m runs a macro (through the Gestures module) |
| Automation | Trigger: key on another keyboard or device | **Manual** (needs a second keyboard; CI Macs have none) |
| Automation | Trigger: app opened / closed / switched to | End-to-end: opening Calculator runs a macro; tests for switching |
| Automation | Trigger: file added to a folder | Tests (a real file in a real folder; its path reaches the macro) |
| Automation | Trigger: Wi-Fi changed, network changed, display connected, Space changed | Tests (logic); **Manual** for real changes (CI Macs have no Wi-Fi or second display) |
| Automation | Trigger: time of day, repeating | Tests (next run: weekdays, every day, every N minutes) |
| Automation | Trigger: menu bar, launcher, Terminal | Tests (menu, launcher); end-to-end: `ToolbeltBridge run "Name" hello` |
| Automation | Trigger: Apple Shortcuts | On hold (owner's decision) |
| Automation | Actions: open, type, press keys, click menu items by name | End-to-end: Edit › Select All then ⌫ in TextEdit |
| Automation | Actions: windows, volume, brightness, resolution, sound output | Window and media actions share the tested Toolbelt commands and keys; resolution/sound listing tested; **Manual** for switching |
| Automation | Clipboard actions, named clipboards, text filters | Tests (set clipboard, find/replace, patterns, case, counts, extract) |
| Automation | Scripts: shell, AppleScript, JavaScript | Tests (output kept in variables, variables passed in) |
| Automation | Notifications, ask for text, pick from a list | Tests (answers filled in, cancelling stops the macro) |
| Automation | If/otherwise, repeat, repeat while, pause, stop, variables | Tests (a whole macro using each; endless loops are stopped) |
| Automation | Groups only in certain apps; search | Tests |
