<div align="center">

<img src="assets/app-icon/windowshade-app-icon.png" alt="WindowShade" width="112">

# WindowShade

**Roll it up. Keep its place.**<br>
Double-click a title bar and the window rolls up into a thin bar, right where it was.<br>
Double-click again and it’s back. Rest the pointer on the bar to glance at it without unrolling.<br>
A free, open-source window utility for Mac.

[![Release](https://img.shields.io/github/v/release/surfine/WindowShade?style=flat-square&color=303b49)](https://github.com/surfine/WindowShade/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-14%2B-303b49?style=flat-square)](#download)
[![Apple Silicon](https://img.shields.io/badge/download-Apple%20Silicon-303b49?style=flat-square)](#download)
[![License](https://img.shields.io/badge/license-MIT-303b49?style=flat-square)](LICENSE)

[**Download for Mac**](https://github.com/surfine/WindowShade/releases/latest) · [**Website**](https://windowshade.aaronlau.me/en/) · [**Intro video**](https://www.bilibili.com/video/BV1K7ag6WEdH/) (Bilibili, in Chinese) · [**Window stories**](https://windowshade.aaronlau.me/en/history/) · [简体中文](README_CN.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/readme-desk-en-dark.png">
  <img src="assets/readme-desk-en.png" alt="The Reference window rolled up into a thin bar where it was, uncovering the draft behind it" width="720">
</picture>

<sub>The interactive illustration from the website: Reference rolls up, and the draft behind it shows through. <a href="https://windowshade.aaronlau.me/en/">Try it yourself →</a></sub>

</div>

## Three ways to move a window aside. Only one never makes you look for it.

When a window covers something, you probably close it or minimize it. Both work. Getting it back just takes a little effort.

| | Where the window goes | Getting it back |
| --- | --- | --- |
| **Close** | It’s gone | Open it again, then find your place again |
| **Minimize** | Into the Dock | Spot it in the Dock first |
| **Roll up** | A thin bar, right where it was | Double-click the bar |

Unlike minimizing, the window never leaves the desktop. Drag the bar somewhere else and the window opens there.

## This double-click is older than your Mac

In the ’90s, most Mac users knew this trick. Then the system changed course, sent windows to the Dock, and the trick was slowly forgotten. We wrote its story as a long read you can operate, **[Window stories](https://windowshade.aaronlau.me/en/history/)**: seven chapters, four hands-on experiments, 14 primary sources.

1. [Don’t close it yet](https://windowshade.aaronlau.me/en/history/#space): one desktop, three arrangements, side by side
2. [A small utility](https://windowshade.aaronlau.me/en/history/#origin): a 1994 user-group newsletter
3. [Two clicks or three](https://windowshade.aaronlau.me/en/history/#preference): change the old control panel yourself
4. [A button for it](https://windowshade.aaronlau.me/en/history/#button): drag a rolled-up window somewhere new
5. [Off to the Dock](https://windowshade.aaronlau.me/en/history/#departure): the Dock, Exposé and Mission Control
6. [Still in use](https://windowshade.aaronlau.me/en/history/#survival): Stickies still keeps the trick
7. [Back to today](https://windowshade.aaronlau.me/en/history/#return): an old gesture on today’s desk

Then [boot an old Mac](https://windowshade.aaronlau.me/en/history/#lab) — System 7.5, Mac OS 8 or Mac OS X 10.1, run by [Infinite Mac](https://infinitemac.org/) — and find the setting through the original menus yourself.

Today’s WindowShade is an independent Swift / AppKit app: the old name and the old idea, with code written from scratch. It is not an Apple product, and it uses no code from Rob Johnston, Apple, or Unsanity’s WindowShade X.

## How it works

Roll up, and a window stays where it was. Glance, and you see it without unrolling. The window you need stays where you know it is, with no round trip to get it.

**Roll up.** Double-click a title bar or press `⌃⌘C` and the window rolls up into a thin bar; double-click the bar to unroll it. The bar can keep the window’s own look, or use one consistent title bar. While a bar is in front, `⌘W`, `⌘M`, `⌘H`, `⌘Q` and `⌘N` go to the window and app behind it; `⌘Q` puts the window back down first, so any “save changes?” question is where you can see it.

**Glance.** Rest the pointer on the bar and a card drops down beneath it, showing the window's content at its own size; move away and it rolls back up. Click the card to unroll the window for real. The bar stays put and the card hangs just below it, so it reads as a preview, not the window itself. A glance never switches the app you’re in and never moves a window. A window that was minimized when it rolled up can’t be shown live, so you see how it looked then, and the corner says so. Details are in the [glance notes](docs/glance.md).

## Shortcuts

New setups in 1.0.16 preset none of these ⌃⌘ combinations; record your own in Settings → Shortcuts. Setups upgraded from 1.0.15 or earlier keep the combinations below.

| Shortcut (upgraded setups) | What it does |
| --- | --- |
| `⌃⌘C` | Roll up or unroll the current window |
| `⌃⌘1…9` | Unroll a rolled-up window, in menu order |
| `⌃⌘0` | Line up the bars, or switch to a focus layout |

Double-click a title bar to roll up; double-click the bar to unroll. Every shortcut can be changed or turned off in Settings, and if another app already uses a combination, WindowShade tells you once.

## Download

Get the latest ZIP from [Releases](https://github.com/surfine/WindowShade/releases/latest), unzip it, drag `WindowShade.app` into Applications and open it, then follow the permission prompts. It lives in the menu bar and stays out of your Dock.

- **1.0.15 download:** 4.06 MB ZIP; the extracted app contains 7.98 MB of files (decimal MB; filesystem allocation may differ).
- **Needs macOS 14 or later and Apple Silicon.** There’s no Intel build.
- **Not notarized yet.** If macOS blocks the first launch, go to System Settings → Privacy & Security and choose Open Anyway. You don’t need to turn off any system security.
- Every release comes with a SHA-256 checksum. For what changed in each version, see the [release notes](https://github.com/surfine/WindowShade/releases).

## Your windows stay on your Mac

WindowShade asks for two permissions. **Accessibility**: finding, moving and restoring windows. **Screen Recording**: taking the window pictures used for previews. “Screen Recording” is just the name the system gives that permission — everything is processed on your Mac and nothing is uploaded. If the app ever quits unexpectedly, your windows go back to how they were.

Regular windows all roll up. Stickies rolls up in its own system way; apps like Adobe’s that draw their own title bars are handled separately. Full screen, Split View, Stage Manager and multiple displays still have a few gaps — try it once with the apps you use. If something goes wrong, please [report it](https://github.com/surfine/WindowShade/issues) with your macOS version, the app, and the steps.

## Build and contribute

Requires macOS 14+, Xcode command line tools, and an Apple Development signing certificate.

```sh
git clone https://github.com/surfine/WindowShade.git
cd WindowShade/prototype
./build.sh --check   # compile check, no signing
./build.sh           # build and sign with your configured identity
open WindowShade.app
```

Set `WINDOWSHADE_CODESIGN_IDENTITY` or use an untracked `prototype/local-codesign.env`. See [DEVELOPMENT.md](DEVELOPMENT.md) for signing, isolated builds, and release instructions; interface and website copy follows the [copy guide](docs/copy-guide.md).

| In the repository | Purpose |
| --- | --- |
| [`prototype/`](prototype/) | Native app: window policies, capture, bars, and recovery |
| [`tests/`](tests/) | State, recovery, shortcut, and paper-component checks |
| [`site/`](site/) | Bilingual website and window stories, hosted on Cloudflare Pages |
| [`docs/performance.md`](docs/performance.md) | Measurements and approaches that did or did not work |
| [`docs/releases/`](docs/releases/) | Preserved release notes |
| [`WindowShade.md`](WindowShade.md) | Original design rationale and research notes |

For changes to window behavior, include the affected app and window type, what happened before and after, and the checks you ran.

## Credits and license

[MIT](LICENSE) for this project's code. Historical names and software belong to their respective authors. The window stories credit [Infinite Mac](https://infinitemac.org/), Marcin Wichary's [Frame of preference](https://aresluna.org/frame-of-preference/), and [AI System 6](https://github.com/surfine/AI-System-6) for its era-rendering reference. Bundled font and reference-asset licenses are retained in [`site/public/fonts/`](site/public/fonts/).
