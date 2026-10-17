# rex-to-nvim

A tiny macOS app that opens code files in Neovim inside Rex. It registers as a
handler for ~220 code file types, so you can pick it from Finder's **Open With**
menu or make it the default app with **Get Info → Open with → Change All…**

It never stays running and never shows a window or dialog: it has no Dock
icon, hands each file off to Rex, and quits. Problems are written to the log.

## What happens when you open a file

1. Finds the working directory: the root of the file's git repository, or
   the file's own folder if it isn't in one.
2. If the file is in a git repository and a Rex pane is already running
   Neovim in that repository, it opens the file there (`:tab drop`, which
   switches to the file's tab if it's already open) and focuses that pane.
   Neovims at the repository root are preferred over ones in a subfolder.
3. Otherwise it creates a Rex session there (`rex new`) and types
   `nvim -p <files>` into its shell, so quitting Neovim leaves you at a prompt
   instead of closing the session.
4. Switches this Mac's Rex app to the session and brings Rex to the front.

To find running Neovims, it asks Rex for each pane's foreground process and its
working directory (`rex block call … process`). It then talks to that Neovim
over its RPC socket (`nvim --server … --remote-expr`). If the Neovim doesn't
answer within 3 seconds, it falls back to a new session.

Opening several files from the same repository at once puts them in one
session, as Neovim tabs.

## Making it the default app

- **File types only this app knows** (`.rs`, `.go`, `.vue`, `.astro`, …): it
  declares them itself and owns them, so they open in Neovim right after
  install.
- **File types other apps also handle** (`.ts`, `.json`, `.md`, `.swift`,
  `.svg`, …): it only registers as an alternate. It appears in Open With, but
  macOS keeps them on the other app. To use it for one, select a file of that
  type in Finder, then **Get Info → Open with: Neovim → Change All…**

Opening the app on its own does nothing.

## Build and install

Requires the Xcode Command Line Tools and Rex.

```sh
make install     # builds build/Neovim.app and installs it to /Applications
make uninstall   # removes it and unregisters its file types
```

`APP_NAME`, `BUNDLE_ID` and `INSTALL_DIR` can be overridden, e.g.
`make install APP_NAME="Neovim (Rex)"`.

Activity and errors are logged to `~/Library/Logs/rex-to-nvim.log`.

## Configuration

Optional, in `~/.config/rex-to-nvim/config.json`:

```json
{
  "command": ["nvim", "-p", "{files}"],
  "cwd": "gitRoot",
  "keepShell": true,
  "client": "auto",
  "rex": "/path/to/rex"
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `command` | `["nvim", "-p", "{files}"]` | What to run. `{files}` expands to every opened path, `{file}` to the first. |
| `cwd` | `"gitRoot"` | `"gitRoot"` or `"parent"` (always the file's folder). |
| `keepShell` | `true` | Run the command from a shell. `false` runs it directly, so quitting it ends the session. |
| `reuseNvim` | `true` | Open files from a git repository in a Neovim already running in it. |
| `openCommand` | `"tab drop"` | The Ex command a reused Neovim opens each file with, e.g. `"drop"` or `"edit"`. |
| `client` | `"auto"` | Which Rex app to switch to the session: `"auto"` (this Mac), `"none"`, or a client label or ID from `rex client ls`. |
| `rex` | found automatically | Path to the `rex` binary. By default it's looked up on `PATH`, then in the newest Rex server install. |

## Which file types it claims

Exactly the code extensions listed in `data/extensions.txt`. Edit that file and
run `make install` to add or remove one. `tools/gen-plist.swift` maps each to
the type macOS already uses for it, or declares one (conforming to
`public.source-code`) if macOS doesn't know it. The build refuses extensions
macOS maps to a catch-all type like plain text, since claiming that would claim
every text file.

Icons and names come from [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons),
snapshotted in `data/devicons.json`. Note that macOS treats `.ts` as MPEG-2
video and `.svg` as an image, so claiming them also lists Neovim for those.

To refresh the snapshot from your installed plugin:

```sh
make devicons
```

## Icons

`tools/gen-icons.swift` renders every icon at build time:

- **App icon:** the Neovim mark in white on a blue tile.
- **Document icons:** one per file type. Each is a white page with the type's
  devicons glyph and, centered beneath it, its extension, both in the type's
  color. Below 64px the label is dropped and the glyph enlarged so it stays
  legible. Colors too pale to read on white are darkened.

Glyphs come from Symbols Nerd Font (`assets/fonts`, MIT licensed).

macOS caches icons aggressively. If changed icons don't show up after
`make install`, run `killall iconservicesagent Finder`. If that's not enough,
log out and back in.

## Layout

```
Sources/main.swift          the app: receives open events, drives the rex CLI
tools/gen-plist.swift       devicons.json → Info.plist (+ build/types.json)
tools/gen-icons.swift       types.json → AppIcon.icns + one .icns per file type
tools/export-devicons.lua   nvim-web-devicons → data/devicons.json
data/                       extensions.txt (what to claim), devicons snapshot
assets/fonts/               Symbols Nerd Font, for the document icon glyphs
```
