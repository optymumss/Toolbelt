# Toolbelt — v0.6

Your all-in-one Mac utility. It lives in the menu bar (look for the wrench-and-screwdriver icon).

**Built so far:** the app shell (menu, settings, shortcuts, permissions), the clipboard manager, the launcher, window management and snippets.
More modules (launcher, window management, snippets, shelf, downloads…) arrive one at a time.

## What's new in 0.6: snippets

Save text you type often and give it a short keyword. Type the keyword anywhere and it turns into the full text.

1. Open **Settings → Snippets** (or choose **Snippets…** from the menu bar icon).
2. Click **Add Snippet**, type a keyword such as `;addr`, a name, and the text.
3. In any app, type `;addr`. It's replaced with your address.

Snippets can include placeholders: `{date}`, `{time}`, `{datetime}`, `{date:dd/MM/yyyy}`, `{clipboard}` (what you last copied) and `{cursor}` (where the cursor lands afterwards).

Snippets also show up in the launcher (⌥Space): search by name and press Return to type it in.

**Permissions:** the first time you add a snippet, Toolbelt asks for **Input Monitoring** (to notice the keyword as you type) and needs **Accessibility** (to type the text for you). Snippets never expand in password fields.

## What's new in 0.5: window management

Move the window you're working in with the keyboard (change any of these in Settings → Shortcuts):

| Keys | Moves the window to |
|---|---|
| ⌃⌥← ⌃⌥→ ⌃⌥↑ ⌃⌥↓ | Left, right, top or bottom half |
| ⌃⌥U ⌃⌥I ⌃⌥J ⌃⌥K | Top-left, top-right, bottom-left or bottom-right quarter |
| ⌃⌥D ⌃⌥F ⌃⌥G | First, centre or last third |
| ⌃⌥E ⌃⌥T | First or last two thirds |
| ⌃⌥↩ | Fill the screen |
| ⌃⌥C | Centre |
| ⌃⌥⌫ | Back where it was |
| ⌃⌥⌘→ ⌃⌥⌘← | Next or previous display |

Or **drag a window by its title bar** to the left or right edge of the screen (half), a corner (quarter) or the top edge (full screen). A blue outline shows where it will go before you let go. The same moves are in the menu bar icon under **Move Front Window**, and in the launcher (type "left half").

Moving windows needs the **Accessibility** permission. Toolbelt asks the first time.

## What's new in 0.4: the launcher

Press **⌥Space** (Option-Space) anywhere to open a search bar. Type and press Return:

| Type | What happens |
|---|---|
| `saf` | Opens Safari. Finds apps, files and folders. ⌘Return shows a file in Finder. |
| `12 * 7 + 1` | Works out the sum. Return copies the answer. Supports `( )`, `^`, `%`, `sqrt()` and more. |
| `5 km in miles` | Converts units: length, weight, temperature, volume, speed, area, time and data sizes. |
| `g cats` | Searches Google for "cats". Also `yt` YouTube, `w` Wikipedia, `maps`, `ddg`, `gh`. Add your own in Settings → Launcher. |
| `lock`, `sleep`, `restart`, `shut down`, `log out`, `empty bin`, `dark mode`, `eject` | System commands. |
| anything you copied | Finds it in your clipboard history; Return pastes it. |

The first time you use **Empty Bin** or **Toggle Dark Mode**, macOS asks whether Toolbelt may control Finder or System Events. Click **Allow**.

## What's new in 0.3

- **Large preview:** in the clipboard panel, press **Space** (or ⌘Y) to see the selected item big. Tap Space again to close, or hold Space and let go. Use ↑ ↓ while it's open to flip through items. Files open in macOS Quick Look, so PDFs, photos and documents show properly.
- **Copies from your iPhone or iPad** (Universal Clipboard) are recorded and labelled *iPhone or iPad*.
- **Images copied in a browser** ("Copy Image") are now kept as images. Before, only the image's web address was saved.
- **Links keep their page title**, and you can search by it.
- **Search finds every word you type**, in any order: "apple macos" finds a link titled "macOS – Apple".
- **Images paste in more apps**: they go on the clipboard as both PNG and TIFF.

## What's new in 0.2

- **New menu-bar icon and menu:** open each module, pause the whole app, open Settings, quit.
- **Settings window with tabs:** General, Shortcuts, Permissions, and one tab per module. Each module has its own on/off switch.
- **Change any shortcut:** Settings → Shortcuts. Click the shortcut, press new keys. Toolbelt warns you if macOS, another app or another Toolbelt shortcut already uses them.
- **Permissions page:** shows whether Accessibility, Input Monitoring and Screen Recording are allowed, what each is for, and a button to open the right page in System Settings.
- **Asks for permissions only when needed:** Accessibility is now requested the first time Toolbelt pastes for you, not at startup.
- **Light, dark, or match the system:** Settings → General → Appearance.
- **Settings now live with your data** in `~/Library/Application Support/Toolbelt/settings.plist`. Your 0.1 settings are carried over automatically.

## Install (about 5 minutes the first time)

1. Unzip `Toolbelt.zip` (double-click it). You get a `Toolbelt` folder.
2. Open **Terminal** (press ⌘Space, type *Terminal*, press Return).
3. Type `bash ` (the word bash, then a space). Don't press Return yet.
4. Drag `install.sh` from the Toolbelt folder into the Terminal window, then press Return.
5. **First time only:** if a window asks to install "command line developer tools", click **Install**, wait for it to finish, then repeat steps 3–4.

The script builds the app, puts it in Applications and starts it. A wrench-and-screwdriver icon shows up in your menu bar.

**To update later:** download the new version and run `install.sh` the same way. It's always one command.

## Allow auto-paste (once)

The first time you pick a clipboard item, Toolbelt explains that it needs the **Accessibility** permission to press ⌘V for you, and offers to open System Settings.
There: Privacy & Security → Accessibility → turn **Toolbelt** on.

Without it everything still works, but choosing an item only copies it and you press ⌘V yourself.

> **After each update** (running install.sh again), macOS treats the rebuilt app as new. In the Accessibility list, select Toolbelt, click **–** to remove it, then turn it back on when asked.

## Using it

| Keys | Action |
|---|---|
| ⌥Space | Open the launcher, from any app |
| ⌘⇧V | Open history, from any app |
| Type | Search |
| ↑ ↓ | Move selection |
| ↩ | Paste the selected item |
| ⌥↩ | Paste as plain text (no formatting) |
| ⌘1 – ⌘9 | Paste one of the first nine items |
| Space or ⌘Y | Large preview (when the search box is empty) |
| ⌘P | Pin / unpin (pinned items are never deleted automatically) |
| ⌘⌫ | Delete item |
| ⇥ | Switch filter: All, Pinned, Text, Links, Images, Files |
| esc | Clear search, then close |

Double-click an item to paste it; right-click for more options.

The menu bar icon has **Clipboard History**, **Pause Recording**, **Clear History**, **Pause Toolbelt** and **Settings**. Settings → General has open at login and appearance; Settings → Clipboard has history size and apps to never record from.

## What it records

Text (with formatting), links (with their page title), images and screenshots (including images copied from web pages and screenshots taken with ⌃ held down, which go straight to the clipboard), files copied in Finder, and anything you copy on your iPhone or iPad when Universal Clipboard is on. Duplicates move to the top instead of piling up. It skips items that password managers mark as private, and anything copied in apps on the "never record" list (1Password, Bitwarden, Passwords and Keychain Access by default).

History and settings are stored only on your Mac at `~/Library/Application Support/Toolbelt/`.

## Uninstall

Quit from the menu bar icon, drag Toolbelt from Applications to the Bin, and delete the folder above.
