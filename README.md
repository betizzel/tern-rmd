# R Notebook for Tern

Opens R Markdown (`.Rmd`) files as notebooks, the way Tern's notebook block opens `.ipynb` files. Markdown is rendered (math included), chunks are editable code with line numbers, and running a chunk shows its output right under it: printed text, messages, warnings and errors, plots (click one to zoom), and data frames as paged tables. Every chunk runs in one live R session, so objects carry over from chunk to chunk like they do in RStudio.

The file on disk stays plain R Markdown. The plugin keeps the text byte for byte, line endings included, and only rewrites the chunks you edit. You can knit it with `rmarkdown` as usual, and RStudio opens it exactly as before.

## Install

```sh
tern plugin link ~/Developer/tern-rmd
```

You need R (`Rscript` on the `PATH`) with the `evaluate` and `jsonlite` packages. Knitting also needs `rmarkdown`.

## Open a notebook

- `tern open homework.Rmd` in any pane, or open the file from the Files pane or the palette.
- **New R Notebook block** in the palette lists the folder's `.Rmd` files (`n` creates `Untitled.Rmd`).
- Click the file name in the status bar to open the raw `.Rmd` in a file block. A `.Rmd` path you click in a terminal also opens as text.

## Keys

The keys follow Jupyter's command and edit modes, with RStudio's shortcuts on top. Press `?` in the notebook to see this list.

**Command mode** (`Esc`):

| Key | Does |
| --- | --- |
| `Enter` | Edit the cell |
| `Shift+Enter` | Run the cell, then select the next one |
| `Ctrl+Enter` | Run the cell |
| `Alt+Enter` | Run the cell, then insert a chunk below |
| `j` `k` / `↓` `↑` | Select the next / previous cell |
| `a` / `b` | Insert a chunk above / below |
| `Ctrl+Alt+I` | Insert a chunk below and start typing in it |
| `m` / `y` | Turn the cell into Markdown / R |
| `d d` | Delete the cell (`z` brings it back) |
| `x` `c` `v` `V` | Cut, copy, paste below, paste above |
| `Alt+↑` / `Alt+↓` | Move the cell up / down |
| `l` | Edit the chunk's label and options (`r setup, fig.width=8`) |
| `o` / `O` | Hide or show the outputs / clear them |
| `R` / `P` | Run every chunk / every chunk above this one |
| `i i` / `0 0` | Interrupt / restart R |
| `e` | Environment: the objects in the R session |
| `s` or `Ctrl+S` | Save |
| `K` or `Ctrl+Shift+K` | Knit (renders with the `output:` from the header) |

**Edit mode**:

| Key | Does |
| --- | --- |
| `Esc` | Back to command mode |
| `Shift+Enter` | Run the chunk, then select the next cell |
| `Ctrl+Enter` | Run the current line or the selection, as in RStudio |
| `Ctrl+Shift+Enter` | Run the whole chunk |
| `Tab` | Complete the name before the caret. The list also opens on its own while you type; `↑` `↓` pick, `Tab`/`Enter` accept |
| `Alt+-` / `Ctrl+Shift+M` | Insert `<-` / `\|>` |
| `Ctrl+Shift+C` or `Ctrl+/` | Comment or uncomment lines |
| `Ctrl+Z` / `Ctrl+Shift+Z` | Undo / redo |
| `↑` on the first line, `↓` on the last | Move into the neighbouring cell |

You can also use the mouse. Click a cell to select it, double-click it to edit it, and use the ▶ and ⏩ buttons on a chunk to run it or every chunk above it. The status bar shows R's state; click it to interrupt R while it runs, or to restart it after it stopped.

## Behaviour worth knowing

- **Saving.** Edits are saved to the file 1.5 s after you stop typing. If another program changes the file while the notebook has no unsaved edits, the notebook reloads it and keeps the output of every chunk whose code didn't change.
- **Outputs.** Outputs are kept in the plugin's data folder (`~/.local/state/tern/plugin-data/rmd`), not in the `.Rmd`, so they come back when you reopen the notebook. Knitting writes them into the HTML. A `html_notebook` header produces the `.nb.html` your course asks for.
- **The R session.** Each notebook gets its own session, started in the `.Rmd`'s folder, so `read.csv("data.csv")` finds files next to the notebook. The session survives plugin reloads, unless an update changed `kernel.R`; then it restarts and a toast says so. It stops when you close the notebook, and if Tern goes away first it exits on its own after two idle minutes. An error stops the chunks queued behind it, as in Jupyter.
- **Chunk options.** `eval`, `error`, `warning`, `message`, `results='hide'`, `fig.width`, `fig.height` and `fig.dim` are honoured when you run a chunk. Knitting honours every knitr option.
- **Packages.** `install.packages()` works from a chunk. CRAN is preset, and your personal library is created if it doesn't exist yet. Packages build from source on Linux, so the compiler output streams into a grey console box under the chunk while it runs, like RStudio's console. Its last lines are where a failed build says why (for example `gfortran: command not found`). Long logs keep their start and end, with a link to the full log.
- **Limits.** Only R chunks run (other engines show an error). Functions that read from the keyboard (`readline()`, `menu()`) don't work in a chunk. The session's HTTP port is bound on every interface because base R can't do otherwise. Each session uses a random 128-bit token that every request must carry.

## How it's built

| File | Role |
| --- | --- |
| `host.luau` | The `rmd.notebook` block: cells, view, keys, running, saving, knitting |
| `rmd.luau` | Splits `.Rmd` into cells and joins them back, byte for byte |
| `buffer.luau` | The text editing behind each cell (caret, selection, undo, R helpers) |
| `kernel.luau` | Starts `kernel.R` and talks to it |
| `kernel.R` | The R session: a small HTTP server on base R sockets around `evaluate` |
| `window.luau` | Routes `.Rmd` opens to the notebook |
| `notebook.css` | The notebook's look |

Tern's process API only reports a program when it exits, so the R session is a tiny HTTP server: the plugin polls `/ping` until R answers, then sends each chunk to `/exec`. While a chunk runs, R streams its outputs to a file that the plugin polls. Interrupting sends `SIGINT` to R.

## Tests

```sh
luau tests/rmd_test.luau      # .Rmd parse/serialize round trips
luau tests/buffer_test.luau   # editing behaviour
tests/kernel_test.sh          # the R session's HTTP API (needs curl, python3)
```

`luau` is the Luau CLI from [luau-lang/luau releases](https://github.com/luau-lang/luau/releases). Run `tern plugin types .` to write `tern.d.luau` for luau-lsp.
