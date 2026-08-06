# jumpcall

[![CI](https://github.com/joncode/jumpcall/actions/workflows/ci.yml/badge.svg)](https://github.com/joncode/jumpcall/actions/workflows/ci.yml)

A tiny macOS menu-bar app that knows when you're in a video call and takes you to it.

The icon sits in your menu bar. When a live call is detected it turns green —
**click it and you're in the call**, no matter what window, app, or Space you
were buried in. The Zoom meeting window comes to the front; a Google Meet
jumps to the *exact browser tab*, in the right window, in the right browser.
No live call? The click just shows a small menu.

There's also a **global hotkey — ⌃⌥⌘M by default** — with a pass-through
contract: while a call is live, the chord jumps you to it from anywhere;
when no call is live, the chord is not consumed at all and behaves exactly
as if jumpcall didn't exist. The hotkey needs macOS's Accessibility
permission (one grant, prompted on first launch); decline it and everything
else keeps working. And because crowded menu bars silently hide status
icons (mid-call is the worst moment: the mic indicator and the call app's
own icon land right as ours turns green), jumpcall seeds itself a
favorable right-side position, notices if it gets overflow-hidden, and
re-creates itself once at a better spot — `jumpcall status` always tells
you plainly whether the icon is currently visible.

## Detects

| Platform | How | Permissions needed |
|---|---|---|
| Zoom | meeting helper process (`CptHost`) | none |
| Google Meet | tab scan in Safari / Chrome / Brave (Edge & Arc supported in config) | Automation, one prompt per browser |
| Web calls the tab scan can't see | mic-usage signal + window-title scan across **all** browser windows | none / Accessibility |
| Microsoft Teams | app is actively using the microphone | none |
| Webex | app is actively using the microphone | none |
| FaceTime | call pipeline is actively using the microphone | none |

The microphone detection reads CoreAudio *metadata* ("which processes have
live audio input right now") — it never records anything and triggers no
microphone permission prompt.

## The switcher — how jumping finds the right window

Clicking the icon (or pressing the hotkey) re-verifies the call and then
picks the most precise jump available:

1. **Exact tab** — if the call was found by the tab scan, the browser is told
   to select that tab and front that window (AppleScript).
2. **Exact window, any profile** — browsers hide some windows from their
   scripting API: **other Chrome profiles, incognito windows, and PWAs are
   invisible to the tab scan**. jumpcall is profile-agnostic here: it
   enumerates *every open window* of every running configured browser
   through the Accessibility API (which sees them all, uniformly), scores
   titles — a Meet meeting-code beats a platform marker like "Microsoft
   Teams", bigger window breaks ties — and raises exactly the winning
   window, un-minimizing it if needed.
3. **The browser itself** — if a browser is holding the microphone but no
   window title gives the call away, jumpcall still reports the live call
   and fronts the browser: worst case you're one window-switch away.

Native apps (Zoom, Teams, Webex, FaceTime) are simply activated — macOS
brings them across Spaces and full-screen apps on its own.

**Firefox limitation:** Firefox has no AppleScript tab access, so Meet calls
in Firefox can't be found by the tab scan. Use Safari or a Chromium browser
for Meet.

## Known limitations

- **Non-US keyboard layouts**: the hotkey is matched by physical key position
  (US-ANSI virtual key codes). On AZERTY/QWERTZ etc. the letter printed on the
  key may differ — pick a chord that works for your layout in config.json.
  Layout-aware matching is planned.
- **Teams / Webex / FaceTime detection is best-effort** until their current
  bundle identifiers are field-verified — run `jumpcall status --verbose`
  during a call and open an issue if a platform isn't detected.
- **Firefox** can't be scanned for Meet tabs (above).
- No detection of calls in browsers not listed in your `browsers` config.
- The cross-profile window switcher matches on window *titles*; if the call
  tab isn't the active tab of its window (so the title doesn't mention the
  call), jumpcall falls back to fronting the browser rather than the exact
  window.

## Requirements

- macOS 14 (Sonoma) or newer — the mic-usage detection uses a CoreAudio API introduced in 14
- Swift 6+ toolchain; the Xcode Command Line Tools are enough (`xcode-select --install`), no Xcode needed
- Tested on Apple Silicon + macOS 26; Intel should work but is untested — reports welcome

## Install

### Homebrew (recommended)

```bash
brew install joncode/tap/jumpcall
jumpcall install
```

(`jumpcall install` copies the app to `~/Applications`, enables
launch-at-login, and starts the menu-bar icon. Re-run it after
`brew upgrade jumpcall`.)

### From source

```bash
git clone https://github.com/joncode/jumpcall.git
cd jumpcall
make install
```

`make install` builds `JumpCall.app`, copies it to `~/Applications`, symlinks
the `jumpcall` CLI, registers it as a Login Item (visible in System Settings →
Login Items), and starts it.

The first time it looks for a Meet tab in a running browser, macOS will ask
"**JumpCall** wants access to control **Safari/Chrome/…**" — that's the tab
scan; approve it per browser you use for Meet. Deny it and everything else
still works.

## CLI

```
jumpcall              run the menu-bar app in the foreground
jumpcall install      install + login item + start   (--launchagent for classic agent)
jumpcall uninstall    remove everything              (--purge also deletes config)
jumpcall status -v    what each detector sees + per-process mic usage
jumpcall jump         one-shot: find the live call and focus it
```

`jumpcall status`/`jump` from a terminal attribute browser permission prompts
to your *terminal app* — that's a macOS rule (TCC blames the responsible
process). Normal menu-bar usage attributes them to JumpCall.

## Configuration

`~/.config/jumpcall/config.json` (created on first run; see
`config.example.json`):

- `pollSeconds` — detection cadence (default 5)
- `hotkey` / `hotkeyEnabled` — the chord, e.g. `"ctrl+alt+cmd+m"` (modifiers:
  `cmd`, `ctrl`, `alt`, `shift`, `fn`; keys: letters, digits, `f1`–`f19`,
  `space`, punctuation)
- `autoReposition` — re-create the icon at a better spot if the menu bar hides it (default true)
- `platforms` — enable/disable and priority-order the platforms
- `browsers` — which browsers to scan for Meet: `safari`, `chrome`, `brave`, `edge`, `arc`
- `iconStyle` — `tint` (green icon when live) or `badge` (green dot)
- `micMatchers` — **add your own platforms**: any app that opens the mic during
  calls can be detected by its bundle-id prefix, no code required:

```json
{
  "id": "discord",
  "displayName": "Discord",
  "bundlePrefixes": ["com.hnc.Discord"]
}
```

then add `{"id": "discord", "enabled": true, "priority": 6}` to `platforms`.

Tip: run `jumpcall status --verbose` *during a call* to see exactly which
bundle id owns the microphone.

## Versions & updating

Find your version any of three ways: right-click the menu-bar icon (bottom
of the menu), `jumpcall version`, or the first line of `jumpcall status`.

To update: `brew upgrade jumpcall && jumpcall install` (Homebrew), or
`git pull && make install` (source). Releases are tagged (`v0.2.0`, …);
see the changelog on each release.

**Heads-up:** updating replaces the binary, which invalidates the hotkey's
Accessibility grant (ad-hoc signing — see Troubleshooting for the fix and
the `JumpCall Dev` certificate that makes source-build grants persist).
An in-app update notice is planned.

## Troubleshooting

**Granted Accessibility but `jumpcall status` still says "waiting"?** The
grant is tied to the exact signed binary, and jumpcall is ad-hoc signed — so
each *rebuild* you install is a "new app" to macOS and the old System
Settings row goes stale. Fix:

```bash
tccutil reset Accessibility io.github.joncode.jumpcall
```

then relaunch JumpCall and grant the fresh prompt. This only affects
re-installing newer builds; a one-time install never hits it.

**Rebuilding often?** Give the build a stable identity so grants survive:
open Keychain Access → menu Keychain Access → Certificate Assistant →
Create a Certificate… → Name: `JumpCall Dev`, Identity Type: Self-Signed
Root, Certificate Type: **Code Signing** → Create. The Makefile detects it
automatically; ask to always allow codesign access on the first build.

**Icon not in the menu bar?** `jumpcall status` says whether it's genuinely
hidden by menu-bar overflow (macOS hides overflow icons silently). jumpcall
auto-repositions once per launch; if your bar is chronically full, free up
icons or use [Ice](https://github.com/jordanbaird/Ice). The hotkey works
regardless.

## Uninstall

```bash
jumpcall uninstall          # or: make uninstall
tccutil reset AppleEvents io.github.joncode.jumpcall   # optional: clear permissions
```

## How it works

A 5-second poll on a background queue runs four cheap probes: a process-list
scan (Zoom's `CptHost`), a CoreAudio process-object read (mic usage for
Teams/Webex/FaceTime and the web-call fallback), an Accessibility window-title
scan across all open browser windows (the profile-agnostic switcher), and —
only when a configured browser is running — an `osascript` tab enumeration
for Meet. Clicking the icon re-verifies before jumping, so a call that ended
seconds ago never gets a stale jump. Ships as a real `.app` bundle (assembled
by `make`, no Xcode) so TCC permissions attach to JumpCall itself.

## Roadmap

- Homebrew tap
- Raise Zoom's *meeting window* specifically (not just the app)
- Live hotkey re-capture UI (today: edit config.json and relaunch)

## Developing

```bash
make build     # release build (with toolchain preflight)
make test      # run the test suite (framework-free runner: swift run JumpCallTests)
make run       # build the bundle and launch it
make install   # full install to ~/Applications
```

Layout: `Sources/JumpCallKit` is the library (detection engine, matchers,
probes, config, UI); `Sources/jumpcall` is a thin executable entry;
`Tests/TestRunner` is a framework-free assert runner (Command Line Tools
ship neither XCTest nor a working Swift Testing runner, and jumpcall's
promise is "no Xcode required"). CI builds and tests every push.

## License

MIT
