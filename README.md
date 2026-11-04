# Battery Peek

A tiny macOS app that shows your battery level in a corner of the screen, floating above all other windows — including full-screen apps.

![Battery Peek in the bottom-right corner, showing 60% while charging](docs/screenshot.png)

## Features

- Small pill with a battery icon, percentage and the current time (24-hour `HH:MM`), always on top, on every Space and over full-screen apps
- Click-through: it never blocks the mouse
- Color-coded: green when charging or plugged in, yellow at ≤ 20%, red at ≤ 10%
- Flashes yellow when the battery is under 3% and not plugged in
- Sounds an alarm at 3% or below when not plugged in, repeating every minute until you plug in:
  - always through the built-in speakers at a fixed volume, ignoring their volume and mute settings
  - also through your current output (headphones, AirPods…) at its own volume, raised to at least 30% and unmuted
  - pauses playing media first and resumes it afterwards (needs Accessibility permission, see below)
  - every device's volume and mute are restored once the beeps end
- Updates instantly on power changes (IOKit notifications), with a 60-second fallback poll
- Menu bar icon to pick the corner (remembered between launches) or quit
- No Dock icon, no dependencies — a single Swift file

## Requirements

- macOS 13 or later, Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`

## Build and run

```sh
./build.sh            # builds build/BatteryPeek.app
open build/BatteryPeek.app
```

To install into `/Applications`:

```sh
./build.sh --install
```

To start it at login, add Battery Peek in **System Settings → General → Login Items**.

### Accessibility permission (optional)

To pause media during the low-battery alarm, Battery Peek simulates the Play/Pause key, which needs **System Settings → Privacy & Security → Accessibility**. It asks on launch; without it the alarm still sounds, it just doesn't pause anything. The build is ad-hoc signed, so after each rebuild remove Battery Peek from that list and add it again.

## Project layout

```
Sources/main.swift   the entire app (AppKit + SwiftUI)
build.sh             compiles, writes Info.plist, ad-hoc signs the bundle
```

## License

[MIT](LICENSE)
