# Toolbelt — v0.2

Your all-in-one Mac utility. It lives in the menu bar (look for the wrench-and-screwdriver icon).

**Built so far:** the app shell (menu, settings, shortcuts, permissions) and the clipboard manager.
More modules (launcher, window management, snippets, shelf, downloads…) arrive one at a time.

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
| ⌘⇧V | Open history, from any app |
| Type | Search |
| ↑ ↓ | Move selection |
| ↩ | Paste the selected item |
| ⌥↩ | Paste as plain text (no formatting) |
| ⌘1 – ⌘9 | Paste one of the first nine items |
| ⌘P | Pin / unpin (pinned items are never deleted automatically) |
| ⌘⌫ | Delete item |
| ⇥ | Switch filter: All, Pinned, Text, Links, Images, Files |
| esc | Clear search, then close |

Double-click an item to paste it; right-click for more options.

The menu bar icon has **Clipboard History**, **Pause Recording**, **Clear History**, **Pause Toolbelt** and **Settings**. Settings → General has open at login and appearance; Settings → Clipboard has history size and apps to never record from.

## What it records

Text (with formatting), links, images and screenshots, and files copied in Finder. Duplicates move to the top instead of piling up. It skips items that password managers mark as private, and anything copied in apps on the "never record" list (1Password, Bitwarden, Passwords and Keychain Access by default).

History and settings are stored only on your Mac at `~/Library/Application Support/Toolbelt/`.

## Uninstall

Quit from the menu bar icon, drag Toolbelt from Applications to the Bin, and delete the folder above.
