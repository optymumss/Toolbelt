# How Toolbelt is tested

Every change runs on a real Mac at GitHub (macOS 26, Apple silicon) before it reaches `main`:

1. **Build** — `build.sh` (optimised, whole-module).
2. **Automated tests** — `test.sh` runs `Tests/Tests.swift`: logic tests against the real code, plus
   *end-to-end* tests that start the real app and use it with real key presses in TextEdit and Calculator.
3. **Battery check** — `.github/scripts/energy.sh` leaves the app idle with every module on (and again
   after opening every Settings tab) and fails if it uses more than 1% of a CPU core or wakes the
   processor more than 15 times a second.
4. **Screenshots** — `.github/scripts/screenshots.sh` opens every screen, fails if the app crashes, and
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
