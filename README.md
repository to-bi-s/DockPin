# DockPin

Pins the macOS Dock to the screen of your choice — and keeps it there.

With "Displays have separate Spaces" on, macOS decides for itself which display gets the Dock
(for a Dock on the left edge: the display whose center is furthest left), and it re-decides on
every login and display change. If that isn't the screen you want, DockPin fixes it. Pick a screen
from the menu bar, done.

## Install

Needs macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```
git clone https://github.com/to-bi-s/DockPin.git
cd DockPin
./build.sh
./install.sh
```

`install.sh` copies the app to `~/Applications`, starts it, and registers it as a login item.
macOS then asks for **Accessibility** access — grant it; DockPin starts working the moment you do.

To remove it: choose **Quit** in the menu (that restores your display arrangement), then
`./uninstall.sh`.

## Use

The menu bar icon opens a small menu:

- **DockPin active / inactive** — green or red dot. Click to pause or resume.
- One entry per connected display — click one to pin the Dock there. The check mark shows the
  current choice; it is remembered across logins.
- **Info** — this page.
- **Quit** — restores the display arrangement and quits.

## How it works

DockPin has no secret API: macOS offers none, and the "push the pointer against the edge" gesture
that moves the Dock is detected inside WindowServer from raw hardware input, so it cannot be
simulated. Instead, DockPin rearranges the *logical* display layout so that the pinned screen is
the one macOS picks on its own, remembers where every moved display really is, and uses an event
tap to teleport the pointer across the old seams — so moving the mouse between screens feels
exactly like the physical layout. Quitting puts the arrangement back.

Two things follow from this:

- While DockPin runs, **System Settings → Displays** shows a layout that differs from your desk.
  That is the mechanism; don't drag it back. Quit DockPin if you need to rearrange displays.
- A second instance exits at once, and a display move that doesn't stick is retried a few times
  and then given up, so DockPin never fights the system.

Details are in the header comment of `DockPin.swift`. Logs go to `~/Library/Logs/DockPin.log`.

## License

GPL-3.0 — see `LICENSE`.

## Building a release

`./release.sh` builds the app signed with a Developer ID, notarizes it (keychain profile
`neutron-notary` by default, override with `NOTARY_PROFILE`), staples the ticket and writes
`release/DockPin-<version>.zip`. The app icon is compiled from `DockPin.icon` with Xcode's `actool`
when a full Xcode is selected.
