# AGENTS.md

Notes for agents working on rex-to-nvim. Read README.md first for what the app
does and how it's configured; this file covers how it's built, how to test it,
and the traps found so far.

## What this is

A background-only macOS app (shown as **Neovim**, bundle ID `local.rex-to-nvim`,
executable `rex-to-nvim`) that registers as a handler for ~250 text file types.
When macOS asks it to open files, it hands them to Rex and quits:

- File in a git repo with a Neovim already running there in some Rex pane →
  `:tab drop` the file into that Neovim over its RPC socket and focus the pane.
- Otherwise → `rex new` a session at the repo root (or the file's folder) and
  type `nvim -p <files>` into its shell.

It never stays running and never shows a Dock icon (`LSUIElement`).

## Layout

| Path | Role |
| --- | --- |
| `Sources/main.swift` | The whole app: AppKit delegate, config, git root lookup, Rex and Neovim discovery, forwarding. |
| `tools/gen-plist.swift` | Decides which extensions to claim and their UTIs. Writes `build/Info.plist` and `build/types.json`. |
| `tools/gen-icons.swift` | Renders `AppIcon.icns` and one `doc-*.icns` per type from `build/types.json`. Compiled with `swiftc`, not run as a script, for speed. |
| `tools/export-devicons.lua` | Refreshes `data/devicons.json` from nvim-web-devicons (`make devicons`). |
| `data/include.txt`, `data/exclude.txt` | Manual overrides to the claim rules. |
| `assets/fonts/` | Symbols Nerd Font (MIT) for document icon glyphs. |
| `design/` | Icon explorations, kept for reference. `all-doc-icons.png` is a contact sheet and may be stale. |

## Build and install

Only the Xcode Command Line Tools are installed: no Xcode, no `xcodebuild`, no
asset catalogs. The app bundle is assembled by hand in the Makefile.

```sh
make install     # build/Neovim.app → ~/Applications/Neovim.app, then lsregister
make uninstall
make clean
```

The pipeline is: `gen-plist` (Info.plist + types.json) → `gen-icons` (icns) →
assemble → ad-hoc `codesign` → `ditto` to `~/Applications` → unregister the
`build/` copy → `lsregister -f` the installed copy.

There are no tests. Verify behavior by running the installed app (below).

## Testing changes

- Write `{"client": "none"}` to `~/.config/rex-to-nvim/config.json` to test
  without switching the Rex app to the new session. That matters when you
  are yourself running inside a Rex pane the user is watching. Delete the file
  afterwards; it doesn't exist by default.
- Trigger the app with `open -a ~/Applications/Neovim.app <files>`. It should
  exit within a second or two (`pgrep -x rex-to-nvim`).
- Every forward is logged to `~/Library/Logs/rex-to-nvim.log`, including the
  session or pane it used.
- Inspect results with `rex capture -s <session> -b <block> --trim` and
  `rex block call -s <session> -b <block> process`. Kill test sessions with
  `rex kill <session>` when done.
- Use a scratch git repo for tests. The user's own Neovim (often hosting the
  agent in a `:terminal`) has its cwd in this repo, so opening files from this
  repo will open tabs in it.
- To see icons as Finder does, render `NSWorkspace.shared.icon(forFile:)` to
  a PNG.

## Traps found so far

**LaunchServices and UTIs**
- `.ts` is `public.mpeg-2-transport-stream` (and `.mts` AVCHD video) on macOS,
  not TypeScript. They are forced in via `data/include.txt`.
- Extensions macOS doesn't know get types declared by the app itself
  (`<bundle id>.ext.<ext>`). Once the app is installed, `UTType(filenameExtension:)`
  returns those declarations, so `gen-plist` must not mistake them for system
  types. It treats any identifier ending in `.ext.<ext>` as its own, under any
  bundle ID. Without this, alternate builds declared 0 types instead of 180.
- `lsregister -u` takes a moment to settle. A build run immediately after
  unregistering can still see old declarations.
- macOS auto-registers `build/Neovim.app`. `make install` unregisters it so
  only one copy handles files.
- Changing the bundle ID resets the user's default apps for system types
  (`.ts`, `.json`, `.md`, `.svg`…). Avoid it, or warn the user.

**Icons**
- macOS caches icons per app. Each build stamps `CFBundleVersion` with a
  timestamp, but that alone may not refresh them; the user may need
  `killall iconservicesagent Finder` (the agent's sandbox may block that).
- `CGContext.setShadow` offsets and blur are in device pixels, not affected by
  the transform, so `gen-icons` scales them by the output size.
- `CTLineGetImageBounds` is relative to the context's current text position,
  which drawing advances. Reset `textPosition` to `.zero` before measuring.

**Rex**
- `rex new -- cmd` makes `cmd` the session's only process, so the session dies
  when it exits. The app instead starts a shell session and types the command
  with `rex send` + `rex send-key enter`. Quoting follows the user's login
  shell (fish quoting differs from POSIX).
- `rex block ls --json` needs `-s SESSION`; iterate `rex ls --json` sessions.
- `rex block call -s S -b B process` → `.foreground` gives `name`, `pid`,
  `path` and `cwd` of the pane's foreground program.
- Several Rex apps can be connected (e.g. another Mac over Tailscale). Pick the
  `app` client over the unix transport whose pid matches the running
  `com.superlogical.rex` app.
- Don't name sessions; the user prefers Rex's own names.

**Neovim**
- Neovim 0.10+ is two processes. Rex reports the UI process, but the RPC
  socket belongs to its child server process:
  `$TMPDIR/nvim.$USER/<random>/nvim.<child pid>.0`. Match sockets by parent
  pid (`sysctl` `KERN_PROC_PID`); `pgrep -P` is unreliable from sandboxes.
- Use the binary path Rex reports for `nvim --server … --remote-expr`. The
  GUI app has no PATH. Calls have a 3s timeout and fall back to a new session.

**GUI app environment**
- No shell PATH. `rex` is found via config, then PATH, then the newest
  `~/Library/Application Support/com.superlogical.rex/RexServer/Versions/<n>/…`.
  `rex new` runs commands through the login shell, so `nvim` resolves there.

## Conventions

- Swift in a single file per target, two-space indent, doc comments on types
  and non-obvious functions, comments that explain *why*.
- Keep the app forward-and-exit: no long-running work, no UI beyond an error
  alert.
- Ask before changing the bundle ID or anything else that resets the user's
  file associations.
