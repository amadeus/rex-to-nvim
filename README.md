# ft-forwarder

A tiny macOS app that opens text files in Neovim inside a new Rex session. It registers as a handler for ~250 text
file types, so you can pick it from Finder's **Open With** menu or make it the
default app with **Get Info → Open with → Change All…**

It never stays running: it has no Dock icon, hands each file off to Rex,
and quits.

## What happens when you open a file

1. Finds the working directory: the root of the file's git repository, or
   the file's own folder if it isn't in one.
2. Creates a Rex session there (`rex new`) and types `nvim -p <files>` into
   its shell, so quitting Neovim leaves you at a prompt instead of closing
   the session.
3. Switches this Mac's Rex app to the new session and brings Rex to the front.

Opening several files from the same repository at once puts them in one
session, as Neovim tabs.

## Build and install

Requires the Xcode Command Line Tools and Rex.

```sh
make install     # builds build/Neovim.app and installs it to ~/Applications
make uninstall   # removes it and unregisters its file types
```

`APP_NAME`, `BUNDLE_ID` and `INSTALL_DIR` can be overridden, e.g.
`make install APP_NAME="Neovim (Rex)"`.

Activity and errors are logged to `~/Library/Logs/ft-forwarder.log`.

## Configuration

Optional, in `~/.config/ft-forwarder/config.json`:

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
| `client` | `"auto"` | Which Rex app to switch to the session: `"auto"` (this Mac), `"none"`, or a client label or ID from `rex client ls`. |
| `rex` | found automatically | Path to the `rex` binary. By default it's looked up on `PATH`, then in the newest Rex server install. |

## Which file types it claims

The list comes from [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons),
snapshotted in `data/devicons.json`. `tools/gen-plist.swift` turns it into the
app's `Info.plist` at build time, claiming an extension when:

- macOS knows the type and considers it text (this includes SVG), or
- macOS doesn't know the type and Neovim has a filetype for it. The app then
  declares the type itself, conforming to `public.source-code`.

`data/include.txt` and `data/exclude.txt` override those rules. For example,
`.ts` is forced in because macOS treats it as MPEG-2 video.

To refresh the snapshot from your installed plugin:

```sh
make devicons
```

## Layout

```
Sources/main.swift          the app: receives open events, drives the rex CLI
tools/gen-plist.swift       devicons.json → Info.plist (+ build/types.json)
tools/export-devicons.lua   nvim-web-devicons → data/devicons.json
data/                       devicons snapshot, include/exclude lists
```

## Not done yet

- Per-type document icons generated from the devicons glyphs and colors, and a
  Neovim app icon. The build already picks up `build/icons/*.icns` once they
  exist; until then, files show a generic page icon.
