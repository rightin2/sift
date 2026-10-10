<p align="center">
  <img src="docs/icon.png" width="128" alt="Sift app icon">
</p>

<h1 align="center">Sift</h1>

<p align="center">
  Clear out a messy folder one file at a time.<br>
  See a real preview of everything, press <b>S</b> to save or <b>D</b> to ditch, and nothing leaves until you say so.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26-3E8E8A" alt="macOS 26">
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-4a6741" alt="SwiftUI with Liquid Glass">
  <img src="https://img.shields.io/badge/licence-MIT-5B6C8F" alt="MIT licence">
</p>

<p align="center">
  <img src="docs/sift.gif" width="900" alt="Sifting a Downloads folder: files are saved or ditched with one key and fly into their piles">
</p>

Photo apps have had swipe-to-clean for years. Sift brings it to the rest of your Mac: point it at Downloads, your Desktop or any folder, and work through it the way you would a stack of paper. Each file shows a live Quick Look preview between a Saved pile and a Ditched pile. When you finish, you check the list once, and ditched files go to the Bin, where you can still put them back.

It is a native macOS 26 app, written in SwiftUI with Liquid Glass.

## Install

Sift is built from source for now, so there is no download yet. You need macOS 26, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/rightin2/sift.git
cd sift
scripts/install.sh
```

The script builds a Release copy and installs it in `/Applications`. To update, run `git pull` and `scripts/install.sh` again.

To remove Sift, turn off **Open Sift at login** in its settings if you turned it on, move Sift from Applications to the Bin, and delete `~/Library/Application Support/Sift`, where it remembers past sifts.

<details>
<summary><b>Working on Sift</b></summary>

Run `xcodegen generate` and open `Sift.xcodeproj`. The engine (scanning, decisions, undo, memory and the Bin) is a separate Swift package with its own tests:

```bash
cd SiftCore && swift test
```

</details>

## Quick start

1. Open Sift and pick Downloads or Desktop, press **Choose a folder** for any other, or drop a folder on the window.
2. Press **S** to save or **D** to ditch each file. **E** or Space looks closer, and ⌘Z undoes.
3. Press ⌘↩ when you are done. Check the list once, and ditched files go to the Bin, where you can still put them back.

## What it does

- **Real previews of everything.** Images, PDFs, documents, spreadsheets, audio and video preview live in the card. Folders show what's inside, archives and apps show their contents without unpacking, and anything Quick Look can't draw gets a card with the site it was downloaded from.
- **The facts that make a decision quick.** Size, when it arrived, where it came from, whether you ever opened it, and its dimensions, page count or length. Chips appear only when they matter: an identical copy in the folder, an archive already unzipped beside it, a download still in progress, locked, in iCloud or tagged.
- **Finder-style folders.** A column view shows where you are. Press → to sift inside a folder and ← to come back; each folder keeps its own decisions.
- **Remembers between sifts.** Open the same folder next week and you start at what's new. Files that arrive while you sift join the end of the queue.
- **Safe by design.** Nothing moves until you confirm. Every file is checked against what you saw before it moves, a ditched folder holding files you saved is flagged, and everything goes to the Bin, never a hard delete. The Done screen can put it all back.
- **Optional reminders.** Sift can watch Downloads from the menu bar and nudge you when ten or more files arrive in a day.

<p align="center">
  <img src="docs/folders.gif" width="900" alt="Stepping into a folder of photos with the right arrow and sifting the photos inside it">
</p>

## Screenshots

| | |
|---|---|
| <img src="docs/sifting.png" alt="Sifting an invoice PDF, with the Saved and Ditched piles either side"> | <img src="docs/folder.png" alt="A folder card showing the photos inside, with the next column peeking in"> |
| <img src="docs/archive.png" alt="Looking inside a zip archive without unpacking it"> | <img src="docs/info.png" alt="A disk image's info card showing the site it came from, found with find by name"> |
| <img src="docs/confirm.png" alt="The confirm sheet, listing everything that will go to the Bin by folder"> | <img src="docs/done.png" alt="The Done screen, showing how much space was freed"> |

All screenshots are dark mode with the window's transparency turned up; Sift follows your Mac's light or dark setting.

## Keys

Left hand decides, right hand moves. Every key is also in the Sifting menu.

| Key | Does |
|---|---|
| S, or swipe left | Save |
| D, or swipe right | Ditch |
| ⌥S / ⌥D | Save or ditch everything left in this folder (ditch asks first) |
| E or Space | Look closer: Quick Look, or the contents of an archive or app |
| ↑ ↓ | Move without deciding |
| → / ← | Sift inside a folder / go back up |
| N / ⇧N | Next or previous undecided file |
| ⌘F, ⌘G | Find by name, find next |
| ⌘Z | Undo, in whichever folder it happened |
| ⌘↩ | Finish and review what goes to the Bin |

## Privacy

Sift never connects to the internet and has no analytics. It reads only the folders you open, plus the one you choose to watch for reminders. Decisions are remembered in a small file in `~/Library/Application Support/Sift`.

## Thanks

Inspired by swipe-to-clean photo apps, and by DClutter and FileSwipe, two small open-source takes on the same idea.

## Licence

MIT. See [LICENSE](LICENSE).
