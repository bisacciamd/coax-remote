# coax-remote

Turn your phone into a remote for [Coax](https://apps.apple.com/app/id6752622762) running on
a Mac. Channel up/down, shuffle, jump to any channel, both of Coax's
[two full screens](#two-full-screens), the info overlay, and a tappable channel
guide — served from the Mac itself, so there's no app to install.

Add it to your Home Screen and it launches chrome-less, like a native remote.

<p align="center">
  <img src="docs/screenshot.png" width="300" alt="The remote on an iPhone: current channel, channel up/down, chaos, full screen, weather and search">
  &nbsp;&nbsp;
  <img src="docs/screenshot-guide.png" width="300" alt="The channel guide open on an iPhone: every channel, tappable">
</p>

Above: the remote running as a Home Screen web app on an iPhone. On the left, the
status panel shows what's on and the volume keys are greyed out — this Mac feeds a
TV over HDMI, which owns its own volume (see [caveats](#notes-and-caveats)). On the
right, the channel guide: every channel Coax generated, tap to tune.

```
iPhone ──http──▶ Hammerspoon ──menu bar──▶ Coax
```

Coax has no scripting interface, so this drives it the two stable ways there are.
Mostly the **menu bar**, via `hs.application:selectMenuItem` — the most reliable
handle on the app, and the only one that survives the video area being a single
Metal-drawn view. But some controls exist *only* as on-screen HUD buttons with no
menu item and no key shortcut — the info pane, and the `FULL SCRN` panel toggle —
so those are reached by walking the window's **accessibility tree** and matching a
button on its description. Channel up/down are arrow keys.

## What you get

A web remote (the main thing), plus two other ways in — all on one dispatcher:

| Front end | How | Good for |
|---|---|---|
| **Web** | `http://your-mac:8765` | the remote itself; add to Home Screen |
| **CLI** | `coax full`, `coax ch 113` | Shortcuts over SSH → Siri, Action Button, widgets |
| **File** | `echo u > /tmp/coax_cmd` | anything that can write a file |

### Commands

| Command | Does |
|---|---|
| `u` / `d` | channel up / down |
| `scrn [on\|off]` | the stream panel full screen — Coax's own **FULL SCRN** |
| `full [on\|off]` | the app *window's* full screen — [a different axis](#two-full-screens) |
| `info [on\|off]` | the info / EPG overlay on top of either — a cinema declutter |
| `ch <n>` | tune to a channel number |
| `find <text>` | tune to the first channel matching text — `find horror`, `find tarantino` |
| `chaos [category]` | random channel, never the one already on |
| `cat <category>` | first channel of a category |
| `weather` / `whatson` / `recent` | the one-off channels |
| `list [category]` | the guide, as text |
| `theme [retro\|modern]` | switch theme |
| `wt` / `multi` | Watch Together / Multi-Window |
| `vol <up\|down\|0-100>` / `mute` | system output volume — see the caveat below |
| `status` | what's on, both full screen states, volume |
| `open` / `quit` | launch / quit Coax |
| `screenoff` | put the display to sleep |
| `help` | the list above |

Categories: Genre, Studio, Decades, Recents, Director, Collections, Actors, Now
Playing, Weather — matched loosely, so `nowplaying`, `now playing` and `now` all
work. Aliases exist for the obvious alternatives (`up`, `next`, `fs`, `shuffle`,
`tune`, `guide`, `power`, `sleep`, …).

## Two full screens

Coax has two, they are independent, and mixing them up is the single most likely
way to be confused by this remote — so:

| | What it resizes | When you want it |
|---|---|---|
| **`scrn`** | the **stream panel** inside the app — the guide plays its stream in a pane beside the EPG, and this hands the whole app view to the player | every time you sit down to watch |
| **`full`** | the **app window**, against the desktop | once, when you first set the Mac up on the TV |

**On the phone they share one key: tap for the panel, hold for the window.** The
key is labelled `⛶ FULL SCRN` with a `HOLD: WINDOW` hint underneath, lights up
while the panel is full, and the status line reads `full scrn` or `in guide`.

A hold rather than a double-tap, deliberately. The panel takes a moment to swap,
and the instinct when a press looks like it missed is to press again — under a
double-tap scheme that second press would fire the rare command at exactly the
wrong moment, yanking the window out of full screen mid-film. A hold is the one
gesture an impatient thumb can't produce by accident. It commits at 600 ms, gives
you a two-beat haptic and lights the key when it does, and aborts if your finger
travels more than 12 px, so scrolling past the key never triggers it.

### Why this needed its own command

`scrn` is not `full` with a different argument, because Coax labels **both** of
them `"Enter Full Screen"` in the accessibility layer. The menu item of that name
resizes the window; a HUD button with the identical description resizes the panel.
The panel has no menu item and no key shortcut at all, so entering means finding
and pressing that button.

Leaving sends **Escape** instead of pressing `Back to Guide`, because the player's
HUD auto-hides after a few seconds and takes its whole accessibility subtree with
it — by the time you want out, there is often no button left to press. Escape works
either way.

Reading the state is a three-way match for the same reason:

| What's in the accessibility tree | State |
|---|---|
| an `Enter Full Screen` button | guide — panel not full |
| a `Back to Guide` button | player, HUD still up — panel full |
| nothing at all | player, HUD hidden — panel full |

The guide's own HUD never auto-hides, so an empty tree is unambiguous. After
acting, `scrn` waits for the view to actually swap and reports **what it observes**
rather than what it was asked for — the web remote paints its key from the state
travelling back with that reply, and a press that didn't take should say so.

## Install

Requires [Hammerspoon](https://www.hammerspoon.org/) and Coax.

```sh
git clone https://github.com/bisacciamd/coax-remote.git
cd coax-remote

# Hammerspoon loads modules from ~/.hammerspoon
ln -s "$PWD/coax.lua"         ~/.hammerspoon/coax.lua
ln -s "$PWD/coaxweb.lua"      ~/.hammerspoon/coaxweb.lua
ln -s "$PWD/coax-remote.html" ~/.hammerspoon/coax-remote.html
ln -s "$PWD/bin/coax"         /usr/local/bin/coax      # optional CLI
```

Add to `~/.hammerspoon/init.lua`:

```lua
coax = require("coax").start()
```

Then **grant Hammerspoon Accessibility** in System Settings → Privacy & Security
→ Accessibility. This is the step everything depends on: it's what lets
Hammerspoon read Coax's menus. (Hammerspoon is signed, so the grant sticks —
an ad-hoc AppleScript helper loses it on every rebuild.)

Reload the config. You'll see a `Coax remote loaded` alert, and the token is
generated into `~/.hammerspoon/coax-token`.

### Get the URL onto your phone

```lua
-- in the Hammerspoon console
coax.web.url("your-mac.local")
```

Open that in Safari on the phone → Share → **Add to Home Screen**. The token is
carried in the bookmark, so you never type it.

### Options

```lua
coax = require("coax").start({
  port       = 8765,
  interface  = nil,          -- "localhost" to refuse anything off-machine
  extraHosts = { "tv-mac" }, -- extra hostnames you reach it by (see Security)
  web        = true,
  alert      = true,
})
```

## Security

This hands whoever reaches it control of your Mac, so:

- **Token on every route**, as `?t=` or an `X-Coax-Token` header. Generated on
  first run into `~/.hammerspoon/coax-token` (chmod 600, 128 bits), compared
  without early-exit, and never expires — your bookmark keeps working across
  restarts.
- **The token is scrubbed from the address bar.** The page stashes it in
  `localStorage` and `replaceState`s it out of the URL, so it doesn't linger in
  browser history — or in a screenshot you post somewhere.
- **DNS-rebinding guard.** Requests whose `Host` is a real domain are refused; a
  browser only ever reaches this by IP, `localhost`, `.local` or a tailnet name.
  Add your own names via `extraHosts`.
- **It is plain HTTP on your LAN.** Anyone already sniffing that segment can read
  the token. Treat it as house-key-grade, not password-grade. If you want it
  off-LAN, put it on [Tailscale](https://tailscale.com/) rather than forwarding a
  port.
- Commands run from a fixed dispatch table — no shell is constructed from input.

## Notes and caveats

**Volume may do nothing, and that's macOS.** If your Mac outputs to a TV over
HDMI/DisplayPort, macOS exposes no software volume for it — `outputVolume()`
returns `nil` and the set runs its own mixer. The remote detects this, greys the
volume keys out and says which device is in charge, rather than reporting a level
it can't change. On built-in speakers it works normally.

**Haptics: one tick, and only on iOS 17.4+.** WebKit never shipped
`navigator.vibrate`, and iOS 26.5 patched the scripted-haptic trick, so a web
page gets a single fixed system tick and no control over intensity. Each key
carries an invisible `<input type="checkbox" switch>` (clipped with `clip-path`,
which clips hit-testing) so your finger lands on a real control and iOS ticks.
Per-button *feels* only materialise where `navigator.vibrate` exists (Android);
elsewhere the difference is carried by the press animation.

**Channel titles go stale.** Menu titles embed the current programme
(`CH 113: Horror - Nope (6:45PM-9PM)`), so a lookup refetches the menus and
retries once. That's why an occasional command takes a beat longer.

**Double-tap zoom** is disabled with `touch-action: manipulation`; pinch-zoom is
deliberately left working.

Every command and reply is logged to `/tmp/coax_log`.

## API

| Route | Returns |
|---|---|
| `GET /api/status` | `{running, channel, num, name, panel, full, infoShown, device, volume, muted, canVolume}` |
| `GET /api/guide` | `[{num, name, cat, now}, …]` — `&fresh=1` bypasses the menu cache |
| `GET /api/cmd?c=<cmd>` | `{reply, state}` |

`status` and `guide` never focus Coax, so polling them won't yank the app forward
while you're using the Mac.

### Dashboard tile (Homepage)

```yaml
- Media:
    - Coax:
        icon: mdi-television-classic
        href: http://YOUR-MAC-IP:8765/?t={{HOMEPAGE_VAR_COAX_TOKEN}}
        siteMonitor: http://YOUR-MAC-IP:8765/api/status?t={{HOMEPAGE_VAR_COAX_TOKEN}}
        widget:
          type: customapi
          url: http://YOUR-MAC-IP:8765/api/status?t={{HOMEPAGE_VAR_COAX_TOKEN}}
          refreshInterval: 10000
          mappings:
            - field: channel
              label: On air
            - field: name
              label: Channel
```

with `HOMEPAGE_VAR_COAX_TOKEN` in Homepage's `.env`. `customapi` fetches
server-side, so the container has to be able to reach the Mac.

## Not built

- **Stream Options, the sleep timer and Coax's own Shuffle Chaos: reachable, just
  not wired up.** An earlier version of this README claimed the accessibility tree
  didn't expose them. It does — the guide HUD offers `Stream Options` and
  `Sleep Timer` as described buttons, and `View ▸ Show Stream Options` (⌘⇧O) and
  `Watch ▸ Shuffle Chaos` are plain menu items. So these are a few lines each
  rather than a dead end; they're absent because nothing has needed them yet, and
  they're untested. (The existing `chaos` command picks a random channel itself,
  deliberately never the one already on, rather than using Coax's shuffle.)
- TV volume would need HDMI-CEC hardware or the set's own network remote.

## Licence

MIT — see [LICENSE](LICENSE).

Not affiliated with Coax or its developer. Coax is lovely; go buy it.
