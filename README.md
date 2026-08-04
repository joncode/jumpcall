# jumpcall

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
| Microsoft Teams | app is actively using the microphone | none |
| Webex | app is actively using the microphone | none |
| FaceTime | call pipeline is actively using the microphone | none |

The microphone detection reads CoreAudio *metadata* ("which processes have
live audio input right now") — it never records anything and triggers no
microphone permission prompt.

**Firefox limitation:** Firefox has no AppleScript tab access, so Meet calls
in Firefox can't be found. Use Safari or a Chromium browser for Meet.

## Install

Requires macOS 14+ and Swift (Xcode Command Line Tools are enough: `xcode-select --install`).

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

## Uninstall

```bash
jumpcall uninstall          # or: make uninstall
tccutil reset AppleEvents io.github.joncode.jumpcall   # optional: clear permissions
```

## How it works

A 5-second poll on a background queue runs three cheap probes: a process-list
scan (Zoom's `CptHost`), a CoreAudio process-object read (mic usage for
Teams/Webex/FaceTime), and — only when a configured browser is running — an
`osascript` tab enumeration for Meet. Clicking the icon re-verifies before
jumping, so a call that ended seconds ago never gets a stale jump. Ships as a
real `.app` bundle (assembled by `make`, no Xcode) so TCC permissions attach
to JumpCall itself.

## Roadmap

- Homebrew tap
- Raise Zoom's *meeting window* specifically (not just the app)
- Live hotkey re-capture UI (today: edit config.json and relaunch)

## License

MIT
