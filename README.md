# Toolbelt — v0.25

Your all-in-one Mac utility. It lives in the menu bar (look for the wrench-and-screwdriver icon).

**Built so far:** the app shell (menu, settings, shortcuts, permissions), the clipboard manager, the launcher, window management, snippets, the drop shelf and the download manager.
More modules (launcher, window management, snippets, shelf, downloads…) arrive one at a time.

## What's new in 0.25: tested like a person uses it
Nothing changes on your Mac: this version adds tests. Before each release, GitHub's Mac now starts the
real Toolbelt and uses it with pretend key presses, mouse clicks and trackpad touches: shortcuts held,
tapped and repeated, snippets, macros, the clipboard, the launcher, window moves, screenshots and the web
server. It then uses it nonstop for 20 minutes to check it never crashes, misses a trigger or keeps using
more memory. A release is only made when all of that passes.

## What's new in 0.24: key up, long hold, repeat, left/right keys, more trackpad gestures
In the Triggers window:
- **Actions for other moments.** Under a trigger's actions, **Add Action For Another Moment**:
  - keyboard shortcuts: on key release, on a long hold, on a quick release, on release after a long hold, after all modifier keys are let go (e.g. middle-click down on press and up on release);
  - trackpad and Magic Mouse gestures: when the fingers lift.
- **Repeat while held** (Basic tab): keep running the actions while the keys are held, or while the fingers stay down, with sliders for how many times a second and how long before the first repeat.
- **Tell left and right modifier keys apart:** e.g. right ⌘ + Space can do something different from left ⌘ + Space. Record the shortcut with the side you want.
- **Follow the keyboard layout:** the shortcut stays on the same letter if you switch layouts.
- These shortcut options need Toolbelt to watch the keyboard: macOS asks for **Input Monitoring** and **Accessibility** the first time.
- **More trackpad gestures:** touch start (the moment that many fingers touch), long touch (hold them still), two-to-five-finger taps near the top or bottom, and **Force Click** (experimental: tell me if it doesn't react on your MacBook).
- **Live View:** a trackpad gesture's settings show your fingers on the trackpad as dots, live.
- The Triggers window now fits smaller screens.

## What's new in 0.23: the Triggers window and conditions (like BetterTouchTool)
- **One window for every trigger:** menu bar icon → **Triggers…** (or Settings → Gestures → Open the Triggers Window). Four columns, left to right:
  1. **Where it applies:** For All Apps, your activation groups, and apps you've added (+ → Choose App, Running Apps, or New Activation Group).
  2. **The triggers:** pick a kind from the row of icons (trackpad, Magic Mouse, mouse buttons, drawings, keyboard shortcuts, modifier taps, typed sequences); + adds one, 🗑 deletes it.
  3. **Its actions,** run in order; **Add Action** adds more; **Try It** runs them now.
  4. **Its settings:** the gesture or keys, on/off, **notes** (and "show notes instead of the description"), and two tabs: **Basic** (show an on-screen message when it runs, run alongside other matching triggers, prevent recursive triggers) and **Advanced** (conditions, activation group, which apps).
- **Keyboard shortcuts** are now triggers too, with any number of actions.
- **Conditional activation groups:** a named set of rules, e.g. "Browsers" = app name contains Safari, Chrome or Firefox, and the window title contains neither Private nor Incognito. Rules can say *all*, *any* or *none* of the following are true, and groups can sit inside groups. Triggers in a group only work while it's true. The editor shows the rules written out and whether they're **currently true**, updated every second.
- **Advanced conditions on one trigger:** e.g. a three-finger tap that does one thing when the pointer is over the window's top-left quarter and another elsewhere. You can check the app, window title, the app under the pointer, where the pointer is in the window or on the screen (%), the hour, the weekday, dark mode and the number of displays.
- **The most specific trigger wins:** one with its own conditions beats one in an activation group, which beats one for a single app, which beats one for every app; or tick "run alongside" to run them together.
- **On-screen message** (like the volume pop-up): per trigger, or as an action ("Show an on-screen message").
- Window titles need the **Accessibility** permission (Toolbelt already asks for it for other features).

## What's new in 0.22: download as many videos at once as you like (like IDM)
- **No more waiting list.** Every video you click starts downloading straight away. Open 100 tabs, click a resolution in each, and all 100 download at the same time.
- **Your choice:** Settings → Downloads → **Downloads at once**: tick **No limit** (the new default), or untick it and pick any number from 1 to 50 on the slider; then the rest wait their turn. Each queue in the Downloads window has the same control.
- **Stays smooth with 100 at once:** Toolbelt shares connections out so every download keeps moving without the site blocking you, joins at most two videos into their final file at a time (the heavy part for the processor and SSD), keeps pieces on the SSD rather than in memory, and lets itself keep thousands of connections open (macOS normally allows an app about 256).
- **Nearly full disk:** with under 2 GB free, downloads pause (keeping what they have) and Toolbelt tells you; they carry on by themselves once there's room.
- **Retry from the page:** if a video's link stops working, its row in the Downloads list has a 🧭 button that opens its page in Chrome so you can click Download again.
- Tested: 100 streamed videos started at the same moment on the test Mac all finish, every file plays, and memory stays low.

## What's new in 0.21: everything BetterTouchTool does with the trackpad and Magic Mouse
- **Pick gestures from a list grouped by fingers** (one finger, two fingers… five), like BetterTouchTool. Gestures another rule already uses are marked **in use**.
- **New trackpad gestures:** one-finger taps at the top-left, top middle, top-right, middle of the left and right sides, bottom-left, bottom middle and bottom-right; **TipTap** left/right (rest one, two or three fingers and tap another beside them); four- and five-finger taps and swipes.
- **New Magic Mouse gestures:** one-finger taps on the left, right or middle of the mouse; clicking with a finger in the middle; clicking with two or more fingers; TipTap.
- **Several actions on one gesture:** under a gesture's first action, click **Add Another Action**; they run in order.
- **More Mac actions:** mute/unmute the microphone, Spotlight, Launchpad (the Apps view on macOS 26), Siri, keyboard light up/down.
- **Sensitivity** (Settings → Gestures): from *easier* to *harder to trigger*, and **ignore the trackpad for a moment after typing**, so a resting palm doesn't set off gestures.
- **Web server** (Settings → Automation → Web server), like BetterTouchTool's: run any macro or Mac control from a web address, e.g. `http://127.0.0.1:12345/trigger_named/?trigger_name=My macro&shared_secret=…` or `/action?do=volumeUp&shared_secret=…`; `/list` lists everything. Off until you switch it on; every request needs the shared secret shown there; only this Mac can use it unless you switch on **Let other devices on my network use it**. Opening the address in a browser shows a page of buttons for your macros and Mac controls; on your iPhone, Share → **Add to Home Screen** makes it an app icon.
  - The first time another device connects, macOS may ask whether Toolbelt may **find devices on your local network** and, if the firewall is on, **accept incoming connections**: allow both.

## What's new in 0.20: video sizes, brightness and volume gestures
- **Download a video at the size you want.** On a video site, point at the video and click **⬇ Download**. Toolbelt lists every size the site streams it at (for example 1080p, 720p, 360p) with roughly how big each file will be. Click one and it downloads in the background: the list of downloads stays out of the way, and the menu bar icon shows how far it's got (e.g. **42%**). Menu bar icon → **Show Downloads** opens the list.
  - It works on most video sites: those that stream without copy protection, and pages with several video files.
  - Not on YouTube (its terms forbid downloading), nor on copy-protected (DRM) video like Netflix: the button says so.
  - The video is saved as one ordinary `.mp4` that QuickTime plays, named after the page and the size, e.g. `My video (720p).mp4`.
  - **After updating:** restart Chrome once (or click **Reload** on Toolbelt Downloads in `chrome://extensions`) so it picks up the new extension.
- **Brightness, volume and sleep on the trackpad:** Settings → Gestures → **Add Brightness, Volume and Sleep Gestures**:
  - four-finger double tap: brightness up; four-finger scroll down: brightness down;
  - three-finger scroll left / right: volume down / up; four-finger swipe up: sleep.
  - Then in **System Settings → Trackpad → More Gestures**, turn **Mission Control** and **App Exposé** off (or set them to three fingers if you don't use three-finger scrolls), so macOS doesn't react to the same swipes.
- **New trackpad gestures** for any action: **double tap**, and **scroll** left/right/up/down, which repeats while your fingers keep sliding (like dragging a slider). The one-step-per-swipe **swipe** gestures are still there: pick whichever you like for each gesture.

## What's new in 0.19: install from a DMG
- **Toolbelt.dmg:** download it, open it, drag Toolbelt onto Applications. No Terminal needed (see *Install* below).
- **Gestures:** Settings → Gestures now says whether the trackpad reader is working. If a macOS update ever changes the touch data Toolbelt reads, trackpad and Magic Mouse gestures pause (and Settings says so) rather than firing at random.

## What's new in 0.14: more shelf

- **Drag to the notch:** while dragging something, push the pointer to the top centre of the screen (the notch) and a shelf opens there. You can choose the left or right edge instead, or turn it off, in Settings → Shelf.
- **Screenshots go onto a shelf automatically**, ready to drag into an email or chat. Add your own **watched folders** in Settings → Shelf: new files in them land on a shelf too.
- **Actions** menu on every shelf: Zip, Resize Images (half size or 1024 pixels), Convert Images (JPEG, PNG, HEIC), Rename in Bulk, Copy File Paths.
- **Drop targets** (⌃⌥⌘G, or **Drop Targets…** in the menu bar): a grid of tiles. Drop files on a folder tile to copy or move them there, on an app to open them with it, or on an action (Zip, Copy Paths, Shelf). Click an app or website tile to open it. Give a tile a shortcut in Settings → Shortcuts ("Drop target 1–9") to use it on the files selected in Finder. Finder asks once whether Toolbelt may read its selection.

## What's new in 0.13: more window management

- **Saved layouts:** arrange your apps how you like them, then choose **Move Front Window → Save Current Layout…** from the menu bar icon (or Settings → Windows). Press **⌃⌥⌘1** (to ⌃⌥⌘9 for later layouts) to put everything back. Apps that aren't running are opened first.
- **Custom snap areas:** choose **Edit Snap Areas…** and drag on each display to draw your own areas (click one and press ⌫ to delete it; esc when done). Then, while dragging a window, **hold ⌥** over an area to snap the window into it.

## What's new in 0.12: more snippets

- **Fill-in snippets:** put `{input:Name}` where a blank goes (or `{input:Name|Sam}` to suggest an answer). When the snippet expands, a small form asks for the blanks, then types the finished text.
- **Snippet picker:** press **⌃⌥;** to search your snippets by name, keyword, folder or text, and press Return to type one.
- **Folders:** give snippets a folder (Settings → Snippets) to keep them organised and to search by folder.

## What's new in 0.11: more launcher

- **App and window switcher:** press **⌥⇥** (Option-Tab). Running apps and their windows are listed, most recently used first. Type to narrow it down, ↩ to switch, **⌘Q** to quit, **⌘H** to hide, **⌘W** to close a window.
- **Floating notes:** press **⌃⌥N** (or type "new note" in the launcher) for a sticky note that stays on top of other windows. Have as many as you like. Drag to move, drag the edges to resize, use the palette for a colour, and click the close button to delete one. Notes are kept between restarts and can be found from the launcher.
- **Recently used first:** what you pick often in the launcher moves up the list.

## What's new in 0.10: more clipboard

In the clipboard panel (⌘⇧V):

| Keys | What it does |
|---|---|
| ⌘E | Edit the text before pasting (⌘↩ pastes it, ⌘S saves it, esc cancels) |
| ⌘K | Add to the **paste stack** (a number shows each item's place) |
| ⌘↩ | Paste the first item of the stack; then **⌃⌥V** pastes the next one each time |
| ⌥⌘↩ | Paste the whole stack at once, one item per line |

Right-click any item for more:
- **Paste as** UPPERCASE, lowercase, Title Case, Trim Spaces, Remove Line Breaks or Remove Formatting.
- **Pinboards**: named collections such as "Email replies" or "Addresses". They show as filters at the top of the panel, and their items are never deleted automatically.
- **Save as Named Clipboard…**: a fixed slot you paste by name. Type its name in the launcher (⌥Space) and press Return.

You can also **drag items out** of the panel into other apps. Images are **searchable by the text in them**: copy a screenshot of an invoice and search for its number.

In Settings → Clipboard:
- **Delete items older than** 1 day to 1 year (pinned and pinboard items stay).
- **Panel layout**: list with preview, grid, or a strip of large cards along the bottom of the screen.

## What's new in 0.9

- **Back up or move your settings:** Settings → General → **Export Settings…** saves your settings, shortcuts, snippets, quicklinks and shelves in one `.toolbelt` file. **Import…** loads one (on a new Mac, for example) and restarts Toolbelt.
- **Right-click and Services menu:** select text or files in almost any app (or right-click in Finder → Quick Actions / Services) and choose:
  - **Add to Toolbelt Shelf**
  - **Download with Toolbelt** (for a selected link)
  - **Save as Toolbelt Snippet**
  - **Pin in Toolbelt Clipboard**

  If they don't show up straight away, log out and back in once, or turn them on in System Settings → Keyboard → Keyboard Shortcuts → Services.
- **Uses less battery:** no background timers while Settings is closed, fewer wake-ups, and an optimised build for Apple silicon.

## What's new in 0.18: automation (macros)

A new **Automation** module. Open **Macros…** from the menu bar icon (or Settings → Automation).

**A macro starts when…** you press a shortcut, type some text (like `;;sig`), use a gesture, press a key on a second keyboard or macro pad, an app opens, quits or comes to the front, a file is added to a folder, the Wi-Fi network or connection changes, a display is connected or disconnected, you switch Spaces, at a time of day (on chosen weekdays) or every few minutes, or when you pick it from the menu bar, the launcher, or Terminal:

```bash
/Applications/Toolbelt.app/Contents/MacOS/ToolbeltBridge run "Macro name"
```

**…and runs its steps:** any Gestures action (open apps, files and websites, type text, press keys, Toolbelt commands, window positions, volume, brightness, media keys), plus choosing a menu item by name (like `File > Export as PDF`), changing the screen resolution, switching the sound output, setting the clipboard or pasting a named clipboard, changing text (find and replace, patterns, case, counting, keeping part of it), running shell scripts, AppleScript or JavaScript and keeping their output, asking you for text or a choice, showing notifications, pausing, and **if / otherwise**, **repeat** and **repeat while** with **variables** (`%Name%`; `%Clipboard%` is the clipboard, `%Trigger%` is what started the macro, such as the new file).

**Groups** switch several macros on or off together, or limit them to certain apps. The Macros window has a **search** box. Apple Shortcuts is on hold, as you asked.

Notes: typed-text and gesture triggers use the Gestures module, so keep it on. A Wi-Fi *name* trigger needs Location Services (macOS only tells apps the network's name with that); “any Wi-Fi change” works without it. A key on a second keyboard still types as well, unless macOS lets Toolbelt take that keyboard over (it allows that for some devices only).

## What's new in 0.17: gestures

A new **Gestures** module (Settings → Gestures → *Add Gesture*). Each gesture does one thing you choose: a Toolbelt command (open the launcher, the clipboard, a window position…), open an app, file or website, press keys, type text, a Mac control (Mission Control, show desktop, volume, play/pause, brightness, lock screen…), or run a shell script or AppleScript.

- **Trackpad:** taps, swipes and pinches with up to five fingers, clicks with three or more fingers, and clicks in a corner.
- **Magic Mouse:** swipes and taps.
- **Extra mouse buttons** (for example the back/forward buttons on a Logitech mouse).
- **Mouse strokes:** hold the right (or middle) button and draw, for example left (←) or down-then-right (↓→). A right-click without drawing still works as normal.
- **Key taps:** tap a modifier on its own, once or twice (for example tap Right ⌘ twice). **Typed sequences:** type something like `;;` to run an action.
- Each gesture can work **everywhere, only in some apps, or everywhere except some apps**.
- Toolbelt only listens to the trackpad, mouse or keyboard while a gesture needs it, so it doesn't cost battery otherwise.

Trackpad and Magic Mouse gestures use the same private part of macOS that BetterTouchTool uses; if Apple ever changes it, those gestures stop working until Toolbelt is updated, and nothing else is affected. If a gesture also does something in macOS (for example four-finger swipes switch Spaces), switch that off in System Settings → Trackpad.

## What's new in 0.16: screenshots

A new **Screenshots** module (Settings → Screenshots):

- **⌥⇧⌘4** — drag out an area (press Space to pick a window instead), **⌥⇧⌘5** — click a window, **⌥⇧⌘3** — the whole screen. Also in the menu bar and the launcher (type “screenshot”).
- The screenshot opens in an **editor**: arrows, boxes, text, highlighter, blur (for hiding passwords or names) and crop, in seven colours, with ⌘Z / ⇧⌘Z. Then **Copy** (⌘C), **Save** (⌘S, to your screenshots folder) or **Copy Text**.
- **⌥⇧⌘2** — drag out an area and its **text is copied** straight away (for text you can't select, like in pictures or videos).
- Prefer no editor? Settings → Screenshots → *After taking a screenshot*: copy it or save it straight away.
- The first time, macOS asks you to allow **Screen Recording** for Toolbelt (System Settings → Privacy & Security → Screen Recording). After each update, macOS may ask again.

## What's new in 0.15: downloads [Next]

- **Queues.** Settings → Downloads → Queues: make queues (for example “Overnight”), choose how many files each downloads at once, and give it start and stop times. Right-click a download to move it to another queue. The Downloads window has a tab per queue with a Start/Stop button.
- **When done.** At the bottom of the Downloads window (or in the menu bar under *When Downloads Finish*), choose *Sleep the Mac* or *Shut Down the Mac*. When the last download finishes you get a one-minute countdown with a Cancel button. It only happens once; then it goes back to *Do Nothing*.
- **Speed limit and hourly cap** (Settings → Downloads → Limits), shared by all downloads.
- **Notification** when a download finishes; click it to see the file in Finder. macOS asks once whether Toolbelt may show notifications.
- **Choose what the list shows**: the list icon at the bottom of the Downloads window turns size, speed, time left, connections, queue and date on or off, and the Open / Show in Finder / Remove / Pause buttons.
- **Chrome extension.** Settings → Downloads → **Set Up Chrome…**. Toolbelt opens Chrome's Extensions page and shows the extension's folder; in Chrome turn on *Developer mode*, click *Load unpacked* and choose that folder. After that:
  - downloads you start in Chrome go to Toolbelt instead (switch this off, or skip small files, from the Toolbelt button in Chrome's toolbar);
  - right-click a link, picture or video → **Download with Toolbelt**;
  - videos played straight from a file get a **⬇ Download** button. It doesn't appear on streamed or copy-protected videos (YouTube, Netflix and the like), or where the site asks browsers not to offer downloading.

  Loading it with *Load unpacked* is free. Putting it on the Chrome Web Store would need a Google developer account ($5) and isn't necessary for your own Mac.

## What's new in 0.8: the download manager

Open **Downloads…** from the menu bar icon, then paste or drop a link and click **Download**. You can also choose **Download Link from Clipboard** from the menu, or paste a link into the launcher (⌥Space).

- **Faster:** big files download in up to 8 parts at once. When one part finishes, its connection helps with the biggest part that's left.
- **Pause and resume** any download. Downloads also carry on by themselves after a lost connection, sleep, a restart or a power cut.
- **Automatic retries** when a connection drops.
- The list shows **progress, speed, time left and size**. Drag finished files straight out of the list.
- Finished downloads are **sorted into folders by type** in your Downloads folder: Video, Music, Documents, Programs, Archives, Images, Other. Change the folder, sorting, connections and retries in **Settings → Downloads**.
- Works with **http, https and FTP** links. FTP uses one connection, through macOS's built-in `curl`, because macOS no longer supports FTP in its own networking.

## What's new in 0.7: the drop shelf

A shelf is a small floating tray you can park things on while you work.

- **Open one** with **⌃⌥S**, from the menu bar icon (**New Shelf**), or by **shaking the pointer** while you're dragging something.
- **Drop anything on it:** files, folders, images, text or links, from any app.
- **Drag them out later:** drag a single item, or use **Drag all out** at the bottom to move everything at once.
- **Have several shelves at once.** Click a shelf's name to rename it, and the coloured dot to colour-tag it.
- **Quick Look:** click the eye next to an item to preview it.
- **Settings → Shelf:** choose whether dropped files stay where they are (the shelf just remembers them, the default) or are copied onto the shelf.

Shelves stay open between restarts. Closing a shelf (×) never deletes your original files.

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

## Install from the DMG (easiest)

1. Download **Toolbelt.dmg** from the latest release: https://github.com/optymumss/Toolbelt/releases/latest
2. Double-click it. In the window that opens, drag **Toolbelt** onto **Applications**. Then eject the disk (the ⏏ next to "Toolbelt" in Finder's sidebar).
3. Open Toolbelt from Applications. **The first time only**, macOS says "Apple could not verify Toolbelt is free of malware" (it isn't signed with a paid Apple developer account). Click **Done**, then go to **System Settings → Privacy & Security**, scroll down to the message about Toolbelt and click **Open Anyway**, then **Open Anyway** again and enter your password.

A wrench-and-screwdriver icon shows up in your menu bar.

**To update later:** quit Toolbelt (menu bar icon → Quit), download the new DMG and drag it onto Applications again, choosing **Replace**. You may need to do the Open Anyway step again, and macOS forgets the Accessibility, Input Monitoring and Screen Recording permissions: turn Toolbelt off and on again in those lists when asked.

> Getting rid of the Open Anyway step needs Apple's notarization, which needs a paid Apple Developer account ($99 a year). It isn't needed for Toolbelt to work.

## Install by building it yourself (about 5 minutes the first time)

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
