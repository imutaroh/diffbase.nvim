# scripts

## demo.sh

Builds a small Go project (`todo-api`) with a feature branch, and opens Neovim in a state that is ready
for a screenshot. Use it for the README images and for articles.

```sh
scripts/demo.sh [scene] [dir]
```

`dir` defaults to `${TMPDIR:-/tmp}/diffbase-demo`. The repository is rebuilt from scratch on every run,
with a fixed author and fixed dates, so the commit hashes never change. The script deletes `dir` only when
it is empty or carries the `.diffbase-demo` marker that the script itself writes; otherwise it refuses.

What the demo repository contains:

- `main`: one commit, "Initial todo API". A bare clone next to it (`origin.git`) is the `origin` remote,
  so `origin/HEAD` exists and the `main` base resolves without configuration.
- `feature/validation`: three commits on top of `main`. The first two are pushed, the last one is not, so
  the `unpushed` base has something to show too.
- Work in progress: `internal/todo/store.go` has an uncommitted change and `internal/todo/errors.go` is
  untracked, so the counts include both (the untracked file is fully green).

Against `main`, the files show:

| Path | Counts | What it shows |
| --- | --- | --- |
| `internal/todo/handler.go` | `+18 -16` | word diff (error messages), added validation, a deleted block |
| `internal/todo/store.go` | `+21 -24` | a renamed field and changed signatures (word diff) |
| `internal/todo/store_test.go` | `+22 -9` | an added test, updated calls |
| `internal/todo/validate.go` | `+40 -0` | new file |
| `internal/todo/errors.go` | `+9 -0` | untracked new file |
| `cmd/server/main.go` | `+3 -1` | a small change in another directory |
| `README.md` | `+9 -2` | a docs tweak |

### Scenes

Each scene starts plain `nvim` (your own config) in the demo repository, on `internal/todo/handler.go`.
It waits for the `DiffBaseChanged` event before it opens neo-tree, so lazy-loaded plugins are ready.

| Scene | Command | Shows |
| --- | --- | --- |
| `setup` (default) | `scripts/demo.sh` | Only builds the repository and prints its path and the scenes. |
| `hero` | `scripts/demo.sh hero` | `:DiffBase main`, neo-tree on the left, `handler.go` scrolled to `list()` and `create()`. |
| `tree` | `scripts/demo.sh tree` | `:DiffBase main`, neo-tree focused with `cmd/server` and `internal/todo` expanded. |
| `menu` | `scripts/demo.sh menu` | `:DiffBase main`, then the base menu (`require("diffbase").pick()`). |

The scenes need diffbase loaded through your plugin manager (`:DiffBase` must exist) and, for the counts
in the tree, neo-tree wired with `setup_opts()`. The menu shows the labels from your `bases` config.

### Screenshot tips

- **Window size:** aim for at least 40 rows. The `hero` scene puts `list()` at the top of the window (it
  sets `'scrolloff'` to 0 in that window so `zt` really reaches the top), and
  the deleted lines (shown as virtual lines) take rows too; on a short window `create()` scrolls out.
  Around 140 columns leaves room for neo-tree and the longest code lines.
- **Font size:** 14 to 16 pt keeps the `+N -M` counts readable after the image is scaled down on GitHub.
- **Root path in neo-tree:** the tree header shows the full path of `dir`. A short directory reads better
  than the default under `$TMPDIR`, for example `scripts/demo.sh hero ~/demo` (the directory must be
  empty or a previous demo). A relative `dir` works too; it is resolved against the current directory.
- **`.git` in neo-tree:** if your neo-tree config shows hidden files, the tree has a `.git` row. Press `H`
  (neo-tree's default `toggle_hidden`) in the tree before you capture; the demo repository has no other
  dotfiles, so nothing else disappears.
- **Startup messages:** each scene clears the command line once it is set up, so messages from your own
  config (deprecation warnings and the like) do not end up in the capture. If one appears later, run
  `:echo ""`.
- **Cursor:** with `cursorline` on, the current line gets the `CursorLine` background on top of the diff
  colors; `:set nocursorline` before you capture if that distracts. Cursor animation plugins can leave a trail in
  the capture; wait a moment after the last movement.
- **Light theme:** diffbase picks its light palette from `'background'`, so `:set background=light`
  (or a light colorscheme) gives the light variant for a second set of images.
