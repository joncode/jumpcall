# Proposal 001: Media Jump — take me to whatever's playing

**Status:** proposed · **Author:** @joncode · **Target:** v0.5

## Motivation

The same "where did that window go" pain jumpcall solves for calls exists
for media. You're working on one screen; a YouTube video is playing on
another (or buried three windows deep, or in a different Chrome profile).
You want to pause it, change it, or look at it — and now you're hunting.

jumpcall already knows how to end that hunt: detect the thing by its audio
footprint, find its window profile-agnostically, jump, and boomerang back.
This proposal extends that loop from *calls* to *anything currently playing
audio or video*.

Example: YouTube playing in Chrome on display 2, you're in your editor on
display 1 → press the chord → you're on the YouTube tab → pause it → press
again → back in your editor.

## Why this is cheap: the signal already exists

The CoreAudio process-object probe that powers call detection reads two
flags per process, and jumpcall already captures both:

- `isRunningInput` — mic in use → **call** (used today)
- `isRunningOutput` — audio playing → **media** (captured, currently unused)

So "which app is playing sound right now" costs **zero new permissions and
zero new probes** — same permissionless metadata read, same 5s poll.

Window targeting reuses the existing switcher: the Accessibility scan that
finds a Meet window in any Chrome profile finds a YouTube tab the same way
(`"… - YouTube"` in the window title), and native apps (Spotify, Music,
VLC) are just app activations. The boomerang inherits unchanged.

## Design

### MediaMatcher

A new matcher, **always lower priority than every call platform** — a live
call beats a playing video, without exception. Detection:

1. Any process with `isRunningOutput` whose bundle id matches a configured
   media app (defaults: Spotify `com.spotify.client`, Music
   `com.apple.Music`, VLC `org.videolan.vlc`, TV `com.apple.TV`,
   Podcasts `com.apple.podcasts`) → handle activating that app.
2. Any *browser* with `isRunningOutput` → AX window-title scan against
   media markers (`- YouTube`, `· Twitch`, `Netflix`, `- SoundCloud`,
   `Spotify - Web Player`, …) → raise that exact window; fall back to
   activating the browser.

Like `micMatchers`, the lists are config data (`mediaMatchers`,
`mediaTitleMarkers`) — users add their own players without code, and the
Settings window can grow an equivalent of "Add Call App…" later
("start playing something and I'll spot it").

### Interaction contract (the important decisions)

- **Opt-in.** `mediaJump: false` by default. jumpcall's identity is
  calls-first; media widens the "chord is consumed" surface, so the user
  must choose it (Settings → a "Jump to media too" toggle).
- **Priority: call > media, always.** With both live, everything targets
  the call. Media is only reachable when no call is live.
- **Hotkey: same chord, extended pass-through.** With media jump enabled
  and something playing (no call), the chord jumps to the media window,
  and the boomerang bounces back — identical muscle memory. With nothing
  live *and* nothing playing, the chord still passes through untouched.
  (Alternative considered: a second chord just for media. Rejected as
  default — two chords to remember kills the simplicity — but could be
  offered later as `mediaHotkey` for power users.)
- **Icon: third state.** Idle (template) / **green** (call) / a visually
  distinct **media state** (e.g., blue tint or a `play.fill` glyph) so the
  icon never lies about what a click will do. Click and long-press
  semantics carry over: click jumps to media; click while on the media
  window opens the menu; hold for menu.
- **Menu** shows "Playing: YouTube — Chrome" with the same Jump / Return
  items.

### Noise control

`isRunningOutput` is noisier than mic use — notification dings and system
sounds flicker it. Mitigations:

- Only bundle ids / title markers from the configured lists count — an
  arbitrary app emitting a ding is ignored.
- Require the output flag on **two consecutive polls** (~10s sustained)
  before flipping the icon to the media state, so blips never register.
  (Calls keep single-poll latency; media can afford the extra beat.)
- `systemsoundserverd`, `com.apple.PowerChime` etc. are excluded outright.

## Implementation sketch

| Piece | Where | Size |
|---|---|---|
| `processesPlayingAudio()` | `AudioInputProbe` (rename to `AudioProbe`) | ~5 lines — filter on the flag we already store |
| `MediaMatcher` | `Matchers/` | ~80 lines, mirrors `MicUsageMatcher` + Meet's AX fallback |
| Media title markers in the window scan | `AXWindowProbe` | extend the marker table + a `mediaTitleLooksLikePlayback` |
| Config: `mediaJump`, `mediaMatchers`, `mediaTitleMarkers` | `Config` | tolerant-decode like everything else |
| Icon third state | `StatusItemController` | one more `liveImage` variant |
| Engine: media as a post-call detection pass with 2-poll debounce | `DetectionEngine` | modest |
| Settings toggle | `SettingsWindow` | one toggle + caption |

No new permissions. No new probes. Tests: marker matching and matcher
ordering are pure functions, same style as the existing 71 assertions.

## Open questions

1. Is the 2-poll debounce right, or should paused-then-resumed media
   re-trigger instantly?
2. Multiple sources playing (Spotify + a YouTube tab): priority list order
   like call platforms, or most-recently-started? (Proposal: config list
   order, consistent with calls.)
3. Should the media icon state be suppressed while detection shows a call
   within the last N seconds (call-end grace period)?

Feedback welcome — comment here or on the tracking discussion.
