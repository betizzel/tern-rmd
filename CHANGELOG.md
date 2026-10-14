# Changelog

## 0.2.0 (2026-10-13)

A security and reliability release. Sessions started by 0.1.0 are stopped and
replaced the first time you run a chunk after updating.

### Security

- **R is reachable from this machine only.** The session used to listen on
  every network interface, guarded by its token alone, and anyone on the same
  network could stall it before authenticating. It now serves through R's
  built-in HTTP server on 127.0.0.1, with the kernel's own router in front:
  R's help pages and session files are not served either.
- **Opening a notebook runs nothing.** R starts with the first chunk you run.
  A folder's `.Rprofile` and `.Renviron` are read only when the folder is
  yours (not writable by everyone, not owned by someone else); otherwise R
  uses your home folder's and a notice says so. Knitting follows the same rule.
- **The plugin knows it is talking to its own session.** Every start gets
  fresh secrets: a token that R checks, and a proof that R sends back, only
  to requests carrying the token. A program squatting on the port can't pose
  as R, and the secrets are removed from R's environment, so `Sys.getenv()`
  in a chunk can't print them.
- **Only verified processes are signalled.** A process id saved before a
  reboot or crash is checked with `ps` before it is stopped; previously it
  could hit an unrelated program.
- **Files are confined to the notebook's data folder.** Plot and log paths
  from R's replies or the output cache are only read, opened or deleted there,
  and outputs are validated before they are drawn.
- **Private data folder.** Outputs, plots and logs are made readable by you
  only (mode 0700) before R starts, and the console log is a fresh file for
  every session.
- Chunk options can no longer smuggle in extra R expressions with a `)`.
- Notebooks are read from regular files only (up to 64 MiB), so a link to
  `/dev/zero` or a pipe can't hang Tern.

### Fixed

- Undo takes back a whole word at a time (the first letter of each word used
  to be its own step).
- Enter at the start of an indented line no longer doubles its indentation.
- Backspace in Markdown cells and in the options field deletes one character,
  not a whole `()` pair.
- Chunks are found exactly as knitr finds them: a chunk closes at a fence with
  its own prefix and backtick count (so a chunk opened with four backticks may
  contain a line of three), `{r-foo}` is Markdown, and `{r, fig.cap='}'}` is a
  chunk.
- Chunks inside a blockquote or a list item run: their `> ` or indent is
  removed before R sees the code, as knitr does.
- A file with mixed line endings is saved with them unchanged.
- A chunk printing megabytes no longer makes the notebook think R died:
  very long output is cut in the middle, at most 2,000 outputs are kept (errors
  always), and each cut is announced.
- `c` and `x` copy a snapshot of the cell, so later edits don't change what
  `v` pastes.
- The Environment panel (`e`) says when R is busy or not running.
- The shortcut help described Tab and ↑/↓ wrongly.
- A second `i i` while a chunk finishes no longer loses its outputs.
- Tables with `NA` column or row names render.
- `kernel.R --flag=value` no longer skips the argument after it.

### Changed

- Faster while chunks run: only new stream lines are decoded, and a large
  console log (a long package build) is tailed instead of read whole three
  times a second. Caret positions in long cells are computed natively.
- Plots fall back to R's default PNG backend when R was built without cairo.
- Clear messages when `Rscript` is missing, when R packages are missing or too
  old (with the command that fixes it), when knitting needs rmarkdown or
  Pandoc, and on Windows (use Tern in WSL).
- Requires evaluate 1.0.4 or newer.

### Added

- **HTML for R Notebooks, as in RStudio.** For an `output: html_notebook`
  document, saving with `s` or `Ctrl+S` also writes `NAME.nb.html` beside it
  from the outputs you see, without running any chunk again; `K` writes it on
  demand (RStudio's Preview). RStudio opens the file with its outputs. Other
  formats still knit.
- `install.sh`: checks R and its packages, installs what's missing into your
  personal R library, and installs the plugin.
- `deps.R`: the package check and installer on its own.
- `LICENSE` (MIT) and this changelog.

## 0.1.0

First version.
