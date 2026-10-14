#!/usr/bin/env bash
# Tests for ../export.R: a notebook's .nb.html from outputs the notebook shows.
#
#   tests/export_test.sh
#
# Needs Rscript with rmarkdown and Pandoc; without them it says so and passes.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export_r="$here/../export.R"

if ! Rscript -e 'quit(status = !(requireNamespace("rmarkdown", quietly = TRUE) && rmarkdown::pandoc_available()))' 2>/dev/null; then
  echo "skipped: export_test needs the rmarkdown package and Pandoc"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$3] got [$2]"; fi; }

cat > "$tmp/nb.Rmd" <<'EOF'
---
title: "Export"
output: html_notebook
---

Two is `r 1 + 1`; the mean is `r mean(session_only)`.

```{r first}
x <- c(2, 4, 6)
mean(x)
```

```{r}
plot(x)
```

> ```{r quoted}
> head(cars, 2)
> ```

```{r}
x
```

```{r}
x
```

```{r never-run}
stop("this must not run")
```

```{r off, eval=FALSE}
also_not_run()
```
EOF

Rscript -e 'png(commandArgs(TRUE)[1], 300, 200); plot(1); invisible(dev.off())' "$tmp/plot.png"

# The outputs in the shape kernel.R's /exec returns them, one entry per chunk.
python3 - "$tmp" > "$tmp/outputs.json" <<'PY'
import json, sys
tmp = sys.argv[1]
print(json.dumps([
  {"code": "x <- c(2, 4, 6)\nmean(x)", "outputs": [
    {"type": "text", "text": "[1] 4\n"},
    {"type": "message", "text": "a note\n"},
    {"type": "warning", "text": "careful", "call": "f(x)"},
    {"type": "error", "text": "\u001b[31mred\u001b[39m failure", "call": ""}]},
  {"code": "plot(x)", "outputs": [{"type": "plot", "file": tmp + "/plot.png", "width": 672, "height": 480}]},
  {"code": "head(cars, 2)", "outputs": [{"type": "table", "class": "data.frame", "nrow": 50, "ncol": 2,
     "cols": ["speed", "dist"], "types": ["dbl", "dbl"], "rownames": None,
     "rows": [["4", "2"], ["4", "10"]]}]},
  {"code": "x", "outputs": [{"type": "text", "text": "FIRST-X\n"}]},
  {"code": "x", "outputs": [{"type": "text", "text": "SECOND-X\n"}]},
  {"code": "stop(\"this must not run\")", "outputs": []},
  {"code": "also_not_run()", "outputs": []},
]))
PY

out=$(cd "$tmp" && Rscript "$export_r" "$tmp/nb.Rmd" "$tmp/outputs.json" 2>"$tmp/err")
st=$?
same "export exits 0" "$st" "0"
same "export prints the file it wrote" "$out" "$(cd "$tmp" && pwd -P)/nb.nb.html"
[ -s "$tmp/nb.nb.html" ] && ok "the .nb.html exists" || { bad "the .nb.html exists"; cat "$tmp/err"; }

check() {
  Rscript - "$tmp/nb.nb.html" "$tmp/nb.Rmd" "$1" <<'R'
a <- commandArgs(TRUE)
nb <- rmarkdown::parse_html_notebook(a[1])
html <- paste(readLines(a[1], warn = FALSE), collapse = "\n")
text <- gsub("<[^>]+>", "", html)
labels <- unique(vapply(nb$annotations, function(x) x$label, ""))
pos <- function(s) regexpr(s, text, fixed = TRUE)[[1L]]
cat(switch(a[3],
  embedded = identical(nb$rmd, readLines(a[2])),
  labels = all(c("source", "output", "message", "warning", "error", "plot") %in% labels),
  outputs = all(c(pos("[1] 4"), pos("a note"), pos("careful"), pos("red failure")) > 0),
  ansi = !grepl("\033", html, fixed = TRUE),
  table = pos("speed") > 0 && pos("The first 2 of 50 rows") > 0,
  order = pos("FIRST-X") > 0 && pos("FIRST-X") < pos("SECOND-X"),
  inline = pos("Two is 2") > 0 && pos("mean(session_only)") > 0,
  unrun = pos("this must not run") > 0 && pos("also_not_run()") > 0
))
R
}
same "the embedded .Rmd is the document, byte for byte" "$(check embedded)" "TRUE"
same "outputs carry RStudio's notebook annotations" "$(check labels)" "TRUE"
same "text, message, warning and error are shown" "$(check outputs)" "TRUE"
same "colour codes are stripped" "$(check ansi)" "TRUE"
same "tables are shown, with the rows left out said" "$(check table)" "TRUE"
same "identical chunks get their outputs in order" "$(check order)" "TRUE"
same "inline code: computed, or shown as code when it needs the session" "$(check inline)" "TRUE"
same "chunks without outputs show their code" "$(check unrun)" "TRUE"
[ ! -e "$tmp/nb.knit.md" ] && [ ! -d "$tmp/nb_files" ] && ok "no intermediate files are left" || bad "no intermediate files are left"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
