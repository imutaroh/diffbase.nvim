# diffbase.nvim

「何と比べた差分を見るか」を選ぶと、**いつもの編集画面**がそのまま GitHub の PR 差分のような表示になります。
変わった行の背景が緑と赤になり、行の中で変わった単語と消えた行も見えます。neo-tree では全ファイルの横に
`+追加 -削除` の行数が出ます。比べる相手は、デフォルトブランチ・直前のコミット・未 push の変更・任意の
1 コミットから選べます。

差分用のタブも新しいレイアウトも開きません。同じウィンドウで同じバッファを編集し続けられます。

[English README](README.md)

<!-- screenshot: editing view with diffbase on (green/red line backgrounds, word diff, deleted lines) -->
<!-- screenshot: neo-tree with "+12 -3" counts next to files and directories -->
<!-- screenshot: the :DiffBase picker menu -->

## 機能

- **メニューから比較の基準を選ぶ**（`:DiffBase`）
  - **main**：このブランチでの変更すべて。自動検出したデフォルトブランチとの merge-base と比べます。
  - **previous**：直前のコミット（`HEAD~1`）。
  - **unpushed**：まだ push していない変更（`@{upstream}` との merge-base）。
  - **Pick a commit…**（任意で有効化、`commit_view = true`）：1 つのコミットが変えた内容だけを見ます
    （[コミット表示](#コミット表示)を参照）。
  - **Off**（基準を設定しているときだけ出ます）
  - それ以外の ref は `:DiffBase ref <ref>` か `require("diffbase").set(ref)` で指定できます。
- **gitsigns.nvim**（任意）も同じ基準に合わせます。ON の間は行の背景・行番号・単語差分・削除行の表示を
  有効にします。OFF にすると、ON にする前の表示設定とグローバルな基準に戻します
  （[既知の制限](#既知の制限)を参照）。
- **neo-tree.nvim**（任意）
  - 変更のあるファイルの横に `+追加 -削除` を表示します。ディレクトリには配下の合計を、バイナリファイルには
    `bin` を表示します。
  - `neotree = { git_base = true }` にすると、neo-tree 自身の git マーク（M/A）も同じ基準になります。neo-tree
    側の不具合があるため既定では OFF です（[neo-tree の git マークが消える](#neo-tree-の-git-マークが消える)を参照）。
- **新規ファイルは全行が緑**になります。一度も `git add` していない未追跡ファイルも含みます。gitsigns が
  なくても動きます。
- **未追跡ファイルも行数に数えます**（追加行として）。サブモジュールは数えません（その中の変更は、この
  リポジトリの行ではないため）。
- **ステータスライン用の文字列**（例：`Δ main +120 -34`）を返します。
- **GitHub 風の配色**。`'background'` に応じてダーク版とライト版を切り替えます。ON にしたときにハイライト
  グループを保存し、OFF で元に戻します。
- **非同期でデバウンスつき**。行数の集計は `vim.system` で行うので編集を止めません。基準を切り替えた後に
  届いた古い結果は捨てます。
- **デフォルトのキーマップはありません。**

## 必要なもの

- Neovim 0.10 以上
- git 2.24 以上（`:checkhealth diffbase` で確認します）
- Unix 系の OS（macOS、Linux）。git に `/dev/null` を渡しているため、Windows は対象外です。
- 任意：[gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)（v1 / v2）。行と単語のハイライトに使います。
  diffbase は基準を切り替えるたびに gitsigns の完了コールバックを待ちます（gitsigns v0.8 以降が呼びます）。
- 任意：[neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim)。ファイルツリーへの行数表示に使います。
  行数表示はどの版でも動きます。`neotree = { git_base = true }` にする場合は、**neo-tree 3.42.0 以降を
  使ってください。** コミット `6679b93`（2026-08-05、PR #2072 "use correct argument order for git_base
  callback"）を含む最初のリリースです。
  それより古い版は、git の基準を設定すると描画のたびに
  `attempt to index local 'git_status' (a boolean value)` というエラーを出します。diffbase を使わない
  `:Neotree git_base=HEAD~1` でも同じエラーになります。diffbase はこの古い版を見分けて、その場合は
  neo-tree の git の基準を設定しません（一度だけ警告し、`:checkhealth diffbase` でも警告します）。
  現在の版にも、開いているツリーに git の基準を設定したときの別の問題が
  あります。[neo-tree の git マークが消える](#neo-tree-の-git-マークが消える)を参照してください。

gitsigns も neo-tree もなくても、新規ファイルのハイライト・行数の API・ステータスライン用の文字列・
コマンドは使えます。

## インストール

### lazy.nvim

```lua
{
  "imutaroh/diffbase.nvim",
  cmd = "DiffBase",
  keys = {
    { "<leader>gn", function() require("diffbase").pick() end, desc = "Diff against… (diffbase)" },
  },
  opts = {},
}
```

### vim.pack（Neovim 0.12 以上）

```lua
vim.pack.add({ "https://github.com/imutaroh/diffbase.nvim" })
require("diffbase").setup()
vim.keymap.set("n", "<leader>gn", function() require("diffbase").pick() end, { desc = "Diff against… (diffbase)" })
```

`setup()` は省略できます。その場合は最初に使ったときに既定値で初期化します。

詳しいリファレンスは `:help diffbase` にあります。lazy.nvim と `vim.pack` は、clone したプラグインのヘルプタグを
作ります。ローカルのチェックアウト（lazy.nvim の `dir =` や `dev = true`）では、一度 `:helptags ALL` を実行してください。

## おすすめの設定

```lua
-- lazy.nvim
return {
  {
    "imutaroh/diffbase.nvim",
    cmd = "DiffBase",
    keys = {
      { "<leader>gn", function() require("diffbase").pick() end, desc = "Diff against… (diffbase)" },
    },
    opts = {
      -- default_branch = "origin/develop", -- if auto-detection picks the wrong branch
    },
  },

  -- Optional: +added -removed next to files in neo-tree.
  {
    "nvim-neo-tree/neo-tree.nvim",
    dependencies = { "nvim-lua/plenary.nvim", "MunifTanjim/nui.nvim", "imutaroh/diffbase.nvim" },
    opts = function(_, opts)
      return require("diffbase.integrations.neotree").setup_opts(opts)
    end,
  },

  -- Optional: line and word highlights. Your own gitsigns settings are restored when diffbase turns off.
  { "lewis6991/gitsigns.nvim", opts = {} },
}
```

すでに neo-tree の spec があるなら、その `dependencies` に `"imutaroh/diffbase.nvim"` を足し、`opts` から
`setup_opts()` を呼んでください（どちらの書き方でも lazy.nvim が spec をまとめます）。依存として指定すると
diffbase は neo-tree と一緒に読み込まれる（neo-tree を遅延読み込みしていなければ起動時）ため、
`cmd = "DiffBase"` で読み込みが遅れるのは neo-tree 連携を使わない場合だけです。

gitsigns のハンク移動（`require("gitsigns").nav_hunk("next")`）も diffbase が設定した基準に従うので、
ブランチ全体の変更箇所を順に移動できます。

### neo-tree との連携

`setup_opts(opts)` は neo-tree の setup オプションに手を加えます。何回呼んでも結果は同じです。

- 組み込みの全ソース（`filesystem`・`buffers`・`git_status`・`document_symbols`）と、`opts.sources` に
  書かれた（モジュールパスでない）ソース名に `diffbase` コンポーネントを登録します。手を加える `file` /
  `directory` レンダラーはこれらのソースで共有されるため、コンポーネントがないソースでは各行に
  "Component diffbase not found." と出てしまいます。
- `file` と `directory` のレンダラーの `container` の中で、`name` の直後に `{ "diffbase", zindex = 10 }`
  を挿入します。
- `renderers.file` や `renderers.directory` を自分で設定していなければ、先に neo-tree の既定値を
  コピーします。設定していれば、ソースごとのレンダラーも含めてそちらに挿入します。

手で組み込む場合は次のようにします。

```lua
local diffbase_tree = require("diffbase.integrations.neotree")
require("neo-tree").setup({
  -- Register it in every source that uses these renderers.
  filesystem = { components = { diffbase = diffbase_tree.component } },
  buffers = { components = { diffbase = diffbase_tree.component } },
  git_status = { components = { diffbase = diffbase_tree.component } },
  renderers = {
    file = {
      -- ...
      { "container", content = {
        { "name", zindex = 10 },
        { "diffbase", zindex = 10 },
        -- ...
      } },
    },
    -- The same entry in `directory` shows the totals of directories.
    directory = {
      -- ...
      { "container", content = {
        { "name", zindex = 10 },
        { "diffbase", zindex = 10 },
        -- ...
      } },
    },
  },
})
```

既定では、diffbase は行数が変化に追従するよう neo-tree を再描画するだけです。neo-tree 自身の git マークは
`HEAD` との差分を表示したままです。`neotree = { git_base = true }` にすると、neo-tree の git の基準
（`git_base_by_worktree` と、旧版向けの `git_base`）も設定して git の状態を読み直させるので、neo-tree の
M/A マークも同じ基準になります。diffbase を OFF にすると、ON にする前の値（たとえば
`:Neotree git_base=main` で自分で設定した基準）に戻します。元の値がなければ設定を消します。diffbase を
ON にした後で開いた neo-tree にも基準を設定します。

**neo-tree 側の既知の問題（`git_base = true` のときだけ）：** 現在の neo-tree では、すでに開いているツリーの
git の基準を設定・解除すると、`git status` の出力が変わるまで neo-tree の git マーク（M、?、✗）が消えます。
詳しくは [neo-tree の git マークが消える](#neo-tree-の-git-マークが消える)を参照してください。
`git_base` が既定で OFF なのはこのためです。

### ステータスライン（lualine）

既存の `lualine_x` にコンポーネントを足してください（この例では後ろに lualine の既定の項目を残しています）。

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      {
        function() return require("diffbase").status() end,
        cond = function() return package.loaded["diffbase"] ~= nil and require("diffbase").status() ~= "" end,
      },
      "encoding",
      "fileformat",
      "filetype",
    },
  },
})
```

`status()` の戻り値は次のとおりです。

| 状態 | 例 |
| --- | --- |
| OFF | `""` |
| 基準を設定中 | `Δ main +120 -34`、`Δ previous +5 -2`、`Δ HEAD~2 +6 -2` |
| 基準と同じ名前の ref を設定中 | `Δ ref:main +5 -1`（`:DiffBase ref main`。`main` 基準の merge-base ではなく、ブランチの先端と比べています） |
| コミット表示中 | `Δ commit 9cce4ec +5 -1` |
| OFF だがコミット表示から戻っていない | `Δ detached (from feature)` |

行数は、最初の非同期の集計が終わってから表示されます。

## コマンド

| コマンド | 動作 |
| --- | --- |
| `:DiffBase` / `:DiffBase pick` | メニューを開く |
| `:DiffBase main` | デフォルトブランチとの merge-base と比べる |
| `:DiffBase previous` | `HEAD~1` と比べる |
| `:DiffBase unpushed` | `@{upstream}` との merge-base と比べる |
| `:DiffBase <name>` | `bases` に定義した任意の基準 |
| `:DiffBase ref <ref>` | 任意の git ref と比べる（`HEAD`、ブランチ、リモートブランチ、タグを補完） |
| `:DiffBase commit` | コミットを選んで、その変更だけを見る（HEAD を detach する。`commit_view = true` が必要） |
| `:DiffBase back` | コミット表示を抜けて元のブランチに戻り、OFF にする |
| `:DiffBase off` | OFF にする（コミット表示からは**抜けない**） |
| `:DiffBase refresh` | 行数を再計算する（デバウンスつき） |

サブコマンド `pick`・`commit`・`back`・`off`・`refresh`・`ref` が先に判定されます。そのため、これらと同じ
名前の基準は `:DiffBase <name>` では呼べません。

### コミット表示

コミット表示はチェックアウトを切り替えるため、既定では無効です。次のように有効にします。

```lua
require("diffbase").setup({ commit_view = true })
```

有効にすると、メニューに **Pick a commit…** が加わり、`:DiffBase commit` が使えるようになります（無効の間、
このコマンドは有効にする方法を警告するだけです）。コミットを選ぶと `git switch --detach` でリポジトリを
そのコミットに切り替え、親コミットと比べます。最初のコミット（親がないコミット）は空のツリーと比べます。

- **一覧に出るコミット**：`<デフォルトブランチ>..HEAD` のコミットです。この範囲が空のときは、`HEAD` から
  直近 `commit_list_limit` 件を出します。
- **切り替えを断る条件**：追跡中のファイルに未コミットの変更（ステージ済みかどうかを問わず）があるとき、
  またはリポジトリ内のファイルのバッファに未保存の変更があるときは、切り替えません。未追跡ファイルは
  妨げになりません。あるリポジトリでコミット表示をしている間は、別のリポジトリではコミット表示もほかの
  基準も始められません。先に `:DiffBase back` を実行してください。サブモジュールはこの判定から外します。`git switch` は
  サブモジュールのチェックアウトを更新しないため、表示中のコミットとずれていても変更とはみなしません。
- **数える対象**：そのコミットが変えた内容だけです。コミット表示中は、作業ツリーの未追跡ファイルを数えず、
  新規ファイルとしてもハイライトしません（`include_untracked` の設定によらず）。
- **選び直し**：コミット表示中にもう一度選ぶと、detach した HEAD ではなく戻り先のブランチから一覧を
  作ります。ブランチのコミットを行き来できます。
- **戻り方**：`:DiffBase back`（またはメニューの先頭に出る "Back to …"）で、元のブランチ（またはコミット）に
  戻ります。追跡中のファイルが変更されているときや、リポジトリ内のバッファに未保存の変更があるときは
  戻りません。
- **Neovim の外での切り替え**：HEAD が表示中のコミットで detach された状態でなくなったら（ターミナルで
  `git switch` した場合など）、コミット表示は終わったものとみなします。`back` と次のコミット表示が、
  今いる場所から別の場所へ切り替えることはありません。このとき `back` は警告して OFF にするだけです。
- **detach 中の OFF**：`:DiffBase off` はハイライトを消しますが、HEAD は detach したままです。ステータス
  ラインには `Δ detached (from <branch>)` と出ます。
- **detach したままの終了**：Neovim の終了時、diffbase は何もしません。コミット表示のまま Neovim を
  終了したら、`git switch -` で戻ってください（複数のコミットを行き来した場合は `git switch <branch>`）。

## API

```lua
local diffbase = require("diffbase")

diffbase.setup(opts?)          -- optional; see Configuration
diffbase.pick()                -- vim.ui.select menu
diffbase.set(ref, opts?)       -- -> boolean
diffbase.set_preset(name)      -- -> boolean; a name from `bases`
diffbase.view_commit()         -- commit picker
diffbase.back()                -- -> boolean; leave commit view
diffbase.off()
diffbase.refresh()             -- debounced
diffbase.get()                 -- -> { base, label, name, root, detached_from }
diffbase.stats(path?)          -- -> { added, removed, binary, new } | nil
diffbase.status()              -- -> string
```

- **`set(ref, opts?)`**
  - `ref` は git の ref 文字列か、`ref` を返す関数 `function(ctx)` です。`ctx` は `{ root, default_branch }`。
    特別な ref `"@default"` は検出したデフォルトブランチを指します。
  - `opts.merge_base`（boolean）を true にすると、`ref` そのものではなく `git merge-base <ref> HEAD` と比べます。
  - `opts.label` はメニューと通知の文言、`opts.name` は `status()` に出る短い名前です。どちらも省略すると
    ref になります。`"@default"` と関数の ref は、解決した先の ref（例：`origin/main`）になります。設定した
    基準と同じ名前の ref は `ref:<ref>` になり、ステータスラインやメニューでその基準と取り違えません。
  - ref を解決できないとき、または別のリポジトリがコミット表示中のときは、警告を出して `false` を返します。
  - ref は設定した時点で一度だけコミットに解決します。その後の再計算では行数だけを数え直し、比べる
    コミットは変えません。
- **`get()`**
  - `base` は比べているコミットです。最初のコミットをコミット表示しているときは空のツリーになります。
  - `root` は正規化したリポジトリのルートです。
  - `detached_from` は、コミット表示中に戻る先のブランチ（またはコミット）です。
- **`stats(path?)`**
  - `path` を省略すると現在のバッファを対象にします。
  - ディレクトリを渡すと配下の合計を返します。ディレクトリの `binary` と `new` は常に `false` です。
  - OFF のとき、または変更のないパスでは `nil` を返します。
  - パスは realpath で解決するので、シンボリックリンク経由で開いたリポジトリでも動きます。git が追跡して
    いるシンボリックリンクは（git と同じく）リンク自身の行数を返し、リポジトリの外からリポジトリ内を指す
    リンクはリンク先の行数を返します。
- **`_open_commit(root, sha, text?)`** は、ピッカーを通さずに `sha` のコミット表示を開きます。独自の
  ピッカーやテスト向けに公開しているもので、互換性は保証しません。

### イベント

diffbase は `User` の autocmd `DiffBaseChanged` を発火します。`data` は `require("diffbase").get()` です。

- 行数の集計が終わるたび（この時点で状態は更新済み）
- `off()` の後
- `back()` の後

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "DiffBaseChanged",
  callback = function(ev)
    -- ev.data.base, ev.data.name, ...
    vim.cmd.redrawstatus()
  end,
})
```

### neo-tree 連携モジュール

```lua
local t = require("diffbase.integrations.neotree")
t.setup_opts(opts)       -- -> opts
t.component(config, node, state)
t.set_base(root, base)   -- -> changed; base = nil restores the previous values
t.refresh(full)          -- full = re-read git status, else redraw
```

## 設定

既定値は次のとおりです（`lua/diffbase/config.lua` から転記）。

```lua
require("diffbase").setup({
  default_branch = nil, -- nil = auto-detect: origin/HEAD, then origin/main, origin/master, main, master
  bases = { -- menu order; `ref` may be a function(ctx) -> ref
    { name = "main", label = "Changes on this branch (vs default branch)", ref = "@default", merge_base = true },
    { name = "previous", label = "Last commit", ref = "HEAD~1" },
    { name = "unpushed", label = "Not pushed yet", ref = "@{upstream}", merge_base = true },
  },
  commit_view = false, -- opt-in: "Pick a commit…" and :DiffBase commit (detaches HEAD)
  commit_list_limit = 20, -- used only when <default branch>..HEAD is empty
  include_untracked = true, -- count untracked files and highlight them as new (not in commit view)
  gitsigns = { enabled = true, linehl = true, numhl = true, word_diff = true, show_deleted = true },
  neotree = { git_base = false }, -- also set neo-tree's own git base (see Known issues)
  new_file_highlight = true, -- paint every line of files that do not exist in the base
  -- GitHub-style: new side green, old side red; the stronger shade marks changed words.
  colors = {
    dark = {
      new_line = "#1f3d2b",
      new_word = "#2f6f47",
      new_fg = "#3fb950",
      old_line = "#4a1f27",
      old_word = "#8b2f3c",
      old_fg = "#f85149",
    },
    light = {
      new_line = "#dafbe1",
      new_word = "#aceebb",
      new_fg = "#1a7f37",
      old_line = "#ffebe9",
      old_word = "#ffcecb",
      old_fg = "#cf222e",
    },
  },
  stat_format = nil, -- function(stat) -> string | { { text, highlight }, ... }
  refresh_events = { "BufWritePost", "FocusGained" },
  debounce_ms = 150,
})
```

オプションの合成と検証のしかた：

- テーブルは既定値に深くマージします。たとえば `colors = { dark = { new_line = "#123456" } }` なら、
  その 1 色だけが変わります。
- `bases` と `refresh_events` はリストなので、指定すると既定値を**置き換えます**（マージしません）。
- `colors = false` にすると、ハイライトグループには一切触れません。
- 型の合わないオプションが 1 つでもあると（配色の各色も対象で、文字列か数値である必要があります）、
  または `commit_list_limit` が正の整数でない、`debounce_ms` が 0 以上の整数でないと、
  問題をすべて並べた警告を 1 回出し、**全オプションを**既定値に戻します。
- Neovim が受け付けない色の文字列（色名の綴り間違いなど）は警告を 1 回出し、その色のグループだけ変えずに
  残します。ほかの機能はそのまま動きます。
- 未知のキー（トップレベルと、`gitsigns` / `neotree` の中）があると警告を出します。警告はセッション中
  1 回だけです。

各オプションの意味：

| オプション | 意味 |
| --- | --- |
| `default_branch` | `"@default"` が指す ref。例：`"origin/develop"`。 |
| `bases[].name` | 短い名前。`:DiffBase <name>` と `status()` で使います。 |
| `bases[].label` | メニューの文言。 |
| `bases[].ref` | ref 文字列、`"@default"`、または ref を返す `function(ctx)`。 |
| `bases[].merge_base` | `HEAD` との merge-base と比べます。 |
| `commit_view` | [コミット表示](#コミット表示)（`git switch --detach`）を有効にする。既定は無効。 |
| `gitsigns.*` | ON にする gitsigns の設定。`true` にしたものだけを保存して元に戻します。 |
| `neotree.git_base` | neo-tree の git の基準も設定し、git の状態を読み直させて M/A マークを同じ基準にするかどうか。neo-tree 側の不具合があるため既定は `false` です（[既知の問題](#neo-tree-の-git-マークが消える)を参照）。どちらの場合も、コンポーネントの行数が変化に追従するよう neo-tree の再描画はします（neo-tree が読み込み済みのときだけ）。 |
| `stat_format` | neo-tree に出す文字列を変えます。文字列（`NeoTreeDimText` で表示、`""` なら非表示）か、`{ text = ..., highlight = ... }` のリストを返します。 |
| `refresh_events` | ON の間、デバウンスつきで再計算を起こすイベント。`{}` で無効になります。 |

`stat_format` の例：

```lua
stat_format = function(s)
  if s.binary then return " bin" end
  return { { text = (" %d/%d"):format(s.added, s.removed), highlight = "Comment" } }
end
```

## ハイライト

| グループ | 既定 | 用途 |
| --- | --- | --- |
| `DiffBaseNewLine` | `DiffAdd` へのリンク | 基準に存在しないファイルの行の背景 |
| `DiffBaseNewNr` | `DiffAdd` へのリンク | そのファイルの行番号 |

`colors` が `false` でなければ、diffbase は ON の間に次のことをします。

- 下に挙げるグループの現在の定義を保存してから、配色で塗り替えます。
- `DiffBaseNewLine` と `DiffBaseNewNr` も塗り替えます。そのため ON の間は、自分で定義した色より配色が
  優先されます。
- `ColorScheme` や `'background'` の変更があると、保存し直してから塗り直します（次のイベントループで行います。
  [既知の制限](#既知の制限)を参照）。
- OFF にすると、保存した定義をそのまま戻します。もともと未定義だったグループは未定義のままにします。

塗り替える gitsigns のグループは次のとおりです。

- `new_line`：`GitSignsAddLn`、`GitSignsChangeLn`、`GitSignsChangedeleteLn`、`GitSignsUntrackedLn`
- `new_word`：`GitSignsAddLnInline`、`GitSignsChangeLnInline`、`GitSignsAddInline`、`GitSignsChangeInline`、
  `GitSignsAddVirtLnInline`、`GitSignsChangeVirtLnInline`
- `old_line`：`GitSignsDeleteLn`、`GitSignsTopdeleteLn`、`GitSignsDeleteVirtLn`
- `old_word`：`GitSignsDeleteLnInline`、`GitSignsDeleteInline`、`GitSignsDeleteVirtLnInline`、
  `GitSignsDeleteVirtLnInLine`
- `new_fg`（太字）：`GitSignsAddNr`、`GitSignsChangeNr`、`GitSignsChangedeleteNr`、`GitSignsUntrackedNr`
- `old_fg`（太字）：`GitSignsDeleteNr`、`GitSignsTopdeleteNr`

neo-tree の行数表示には `NeoTreeGitAdded`、`NeoTreeGitDeleted`、`NeoTreeDimText` を使います。

## ヘルスチェック

`:checkhealth diffbase` を実行すると、次の内容を表示します。

- Neovim のバージョンと git のバージョン（2.24 未満ならエラー）
- gitsigns と neo-tree の有無（lazy.nvim で入れている場合はバージョンも）
- 現在のリポジトリと、検出したデフォルトブランチ
- 有効な基準と、コミット表示から戻っていないかどうか

リポジトリは、diffbase が有効ならその状態から、なければ `:checkhealth` を実行したバッファから、それもなければ
カレントディレクトリから探します。

遅延読み込み（`cmd = "DiffBase"`。neo-tree 連携を使うと diffbase は neo-tree と一緒に読み込まれるので、
それを使わない場合）では、lazy.nvim はプラグインを読み込むまでそのヘルスチェックを見せない
ため、`:checkhealth diffbase` は読み込み前だと "No healthcheck found" になります。先に `:DiffBase off`
（OFF のときは何もしません）か `:Lazy load diffbase.nvim` を実行してください。起動時のスクリプトは
`:DiffBase` コマンドを定義するだけなので、`lazy = false` で最初から読み込んでも負担はほとんどありません。

## 既知の制限

- **バッファ単位の gitsigns の基準**：`:Gitsigns change_base` を global なしで実行して 1 つのバッファだけに
  設定した基準は、`:DiffBase off` でリセットされます。diffbase が戻すのはグローバルな基準だけです。
- **基準に存在しないファイル**：基準に存在しないファイル（表示中のコミットで追加されたファイルなど）では、
  バッファを読み直す（`:edit`）まで gitsigns の古い差分が残ることがあります。diffbase 自身の新規ファイルの
  ハイライトは正しく表示されます。
- **カラースキームと diffbase を 1 行で実行**：`:colorscheme X | DiffBase off`（または `| DiffBase <base>`）
  のように 1 行で実行すると、OFF にしたときに前のカラースキームの `GitSigns*` の定義に戻ります。別々の
  コマンドとして実行してください。
- **コミット表示中の終了**：Neovim の終了時に diffbase は元へ戻しません。`git switch -` で戻ってください。
- **git リポジトリの外での `:DiffBase`**：基準のメニューはそのまま開き、「not inside a git repository」の警告は
  項目を選んだ後に出ます。`:DiffBase main` などのサブコマンドはすぐに警告します。

## よくある質問

### diffview.nvim とは何が違う？

diffview.nvim は専用のタブを開き、左右に並べた差分とファイル一覧を表示します。レビューにはとても便利です。
diffbase はレイアウトを一切変えません。本物のバッファを編集し続けたまま、その上に差分をハイライトとして
重ね、普段使っているファイルツリーに行数を出します。両方を併用できます。

### gitsigns の `change_base` だけとは何が違う？

diffbase も行のハイライトには `change_base` を使っています。その上に次のものを足しています。

- merge-base で解決するプリセット（ブランチ全体の変更、未 push の変更）とデフォルトブランチの自動検出
- linehl・numhl・word_diff・show_deleted をまとめて ON にし、後で自分の設定値に戻す仕組み
- 適用して後で元に戻す配色
- neo-tree の `+追加 -削除` 表示と、任意で neo-tree 自身の git マークの基準合わせ（下の既知の問題も参照）
- 未追跡ファイルの集計と、新規ファイルとしてのハイライト
- gitsigns なしでも動く新規ファイルのハイライト
- コミット表示（1 コミットを親と比べ、終わったら戻る）
- ステータスライン用の文字列と `DiffBaseChanged` イベント

### neo-tree が `attempt to index local 'git_status' (a boolean value)` を出す

`neotree = { git_base = true }` のときだけ起きます。neo-tree が 3.42.0（コミット `6679b93`）より古い版です。このコミットで
git の基準を設定したときの不具合が直っています。neo-tree を更新するか、既定の `git_base = false` に戻して
ください。diffbase と関係ないことは、`:Neotree git_base=HEAD~1` を単独で実行すると
確かめられます。diffbase はこの古い版を見分けて基準を設定せず、`:checkhealth diffbase` で警告します。

### neo-tree の git マークが消える

`neotree = { git_base = true }` のときだけ起きます。現在の neo-tree（`ffdf8d9` で確認）では、すでに開いているツリーに git の基準を設定・解除すると、neo-tree の
git status が空になります。M、?、✗ のマークが消え、Git タブは "working tree clean" と表示し、
`:DiffBase off` の後も `git status` の出力が変わる（ファイルを作る・編集するなど）までマークは消えたままです。
diffbase を使わなくても、`:Neotree show` の後に `:Neotree show git_base=HEAD~1` を実行すると同じことが
起きます。原因は neo-tree 側（`git status` の出力が前回と同じとき、キャッシュを使う経路が空の status を
渡してしまう）にあり、diffbase からは回避できません。マークが必要なら既定の `git_base = false` のままに
してください。diffbase は neo-tree の git の基準に触れなくなり、`+追加 -削除` の表示はそのまま動きます。

### "no upstream branch is configured for '<branch>'" と出る

`unpushed` を使うには upstream の設定が必要です。`git push -u` か `git branch --set-upstream-to` で
設定してください。関連するメッセージ：

- "the upstream branch '<remote>/<branch>' of '<branch>' is gone (deleted on the remote)"：upstream の
  ブランチがリモートで削除され、prune 済みです。`git push -u` でもう一度 push するか、別の upstream を
  設定してください。
- "HEAD is detached; 'unpushed' needs a branch with an upstream"：先にブランチへ切り替えてください。

### `main` が違うブランチを選ぶ

`default_branch = "origin/develop"`（任意の ref）を設定するか、`git remote set-head origin --auto` で
`origin/HEAD` を直してください。

### リポジトリを書き換える？

書き換えるのはコミット表示だけです。`git switch --detach <commit>` を実行し、`back` で
`git switch <元のブランチ>` を実行します。それ以外の git コマンドはすべて読み取りのみです。行数の集計は
`GIT_OPTIONAL_LOCKS=0` をつけて実行するので、git の任意のロックも取りません。

## ライセンス

MIT。[LICENSE](LICENSE) を参照してください。
