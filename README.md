# Toolbelt — v0.1 (clipboard manager)

The first module of your all-in-one Mac utility. It runs in the menu bar and keeps everything you copy.

## Install (about 5 minutes the first time)

1. Unzip `Toolbelt.zip` (double-click it). You get a `Toolbelt` folder.
2. Open **Terminal** (press ⌘Space, type *Terminal*, press Return).
3. Type `bash ` (the word bash, then a space). Don't press Return yet.
4. Drag `install.sh` from the Toolbelt folder into the Terminal window, then press Return.
5. **First time only:** if a window asks to install "command line developer tools", click **Install**, wait for it to finish, then repeat steps 3–4.

The script builds the app, puts it in Applications and starts it. A clipboard icon shows up in your menu bar.

## Allow auto-paste (once)

macOS asks for **Accessibility** permission the first time. This lets Toolbelt press ⌘V for you.
System Settings → Privacy & Security → Accessibility → turn **Toolbelt** on.

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

The menu bar icon has **Pause Recording**, **Clear History** and **Settings** (open at login, history size, apps to never record from).

## What it records

Text (with formatting), links, images and screenshots, and files copied in Finder. Duplicates move to the top instead of piling up. It skips items that password managers mark as private, and anything copied in apps on the "never record" list (1Password, Bitwarden, Passwords and Keychain Access by default).

History is stored only on your Mac at `~/Library/Application Support/Toolbelt/`.

## Uninstall

Quit from the menu bar icon, drag Toolbelt from Applications to the Bin, and delete the folder above.
