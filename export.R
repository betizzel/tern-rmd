#!/usr/bin/env Rscript
# export.R -- writes a notebook's NAME.nb.html from the outputs the notebook
# shows, without running any chunk.  This is what RStudio does when you save
# an `output: html_notebook` document: the HTML holds the code, the outputs and
# the .Rmd itself, so RStudio can open it again.
#
#   Rscript export.R DOC.Rmd OUTPUTS.json
#
# OUTPUTS.json lists the document's code chunks in order, each as
# {"code": "...", "outputs": [...]}, the outputs in the shape kernel.R's /exec
# returns them.  A chunk is matched to its entry by its code (identical chunks
# in order), so labels, eval=FALSE chunks and other engines don't matter.  A
# chunk with no entry shows its code only.  Inline `r` code is evaluated in a
# fresh session, as when knitting; when it needs objects that only the
# notebook's session has, it shows as code instead of failing the export.
#
# Prints the path of the written file.  Needs rmarkdown (and Pandoc).

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
  cat("usage: Rscript export.R DOC.Rmd OUTPUTS.json\n", file = stderr())
  quit(save = "no", status = 2L)
}
input <- args[[1L]]
for (pkg in c("rmarkdown", "knitr", "jsonlite")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop("there is no package called '", pkg, "'", call. = FALSE)
  }
}

`%||%` <- function(a, b) if (is.null(a)) b else a

entries <- jsonlite::fromJSON(args[[2L]], simplifyVector = FALSE)
used <- rep(FALSE, length(entries))

# Code compared without trailing whitespace and surrounding blank lines.
normalize <- function(code) {
  lines <- sub("[ \t\r]+$", "", strsplit(paste(code, collapse = "\n"), "\n", fixed = TRUE)[[1L]])
  while (length(lines) && !nzchar(lines[[1L]])) lines <- lines[-1L]
  while (length(lines) && !nzchar(lines[[length(lines)]])) lines <- lines[-length(lines)]
  paste(lines, collapse = "\n")
}
keys <- vapply(entries, function(e) normalize(e$code %||% ""), "")

# The session prints with colours (cli, crayon); HTML gets the plain text.
strip_ansi <- function(x) {
  gsub("\033\\[[0-9;?]*[ -/]*[@-~]|\033\\][^\a\033]*(?:\a|\033\\\\)", "", x, perl = TRUE)
}

parse_call <- function(call) {
  if (!is.character(call) || length(call) != 1L || !nzchar(call)) return(NULL)
  tryCatch(str2lang(call), error = function(e) NULL)
}

table_output <- function(o) {
  cols <- vapply(o$cols %||% list(), function(x) as.character(x %||% "NA"), "")
  rows <- lapply(o$rows %||% list(), function(r) vapply(r, function(x) as.character(x %||% "NA"), ""))
  cells <- if (length(rows)) do.call(rbind, rows) else matrix(character(0), 0L, length(cols))
  df <- as.data.frame(cells, stringsAsFactors = FALSE)
  names(df) <- cols
  types <- vapply(o$types %||% list(), function(x) as.character(x %||% ""), "")
  for (j in seq_along(df)) {
    if (isTRUE(types[j] %in% c("dbl", "int"))) df[[j]] <- suppressWarnings(as.numeric(df[[j]]))
  }
  if (length(o$rownames)) {
    rownames(df) <- make.unique(vapply(o$rownames, function(x) as.character(x %||% "NA"), ""))
  }
  out <- list(knitr::knit_print(rmarkdown::paged_table(df)))
  total <- suppressWarnings(as.numeric(o$nrow %||% nrow(df)))
  if (isTRUE(total > nrow(df))) {
    out <- c(out, list(rmarkdown::html_notebook_output_html(
      sprintf("<p><em>The first %d of %s rows.</em></p>", nrow(df), format(total, big.mark = ",")))))
  }
  out
}

# One output item of the notebook -> what knitr would have seen from evaluate().
as_output <- function(o) {
  text <- strip_ansi(as.character(o$text %||% ""))
  switch(o$type %||% "",
         text = , console = text,
         message = simpleMessage(text),
         warning = simpleWarning(sub("\n$", "", text), call = parse_call(o$call)),
         error = simpleError(sub("\n$", "", text), call = parse_call(o$call)),
         plot = if (is.character(o$file) && file.exists(o$file)) {
           rmarkdown::html_notebook_output_png(path = o$file)
         },
         table = table_output(o),
         NULL)
}

source_of <- function(code) structure(list(src = code), class = "source")

output_source <- function(code, context, ...) {
  key <- normalize(code)
  hit <- which(!used & keys == key)[1L]
  if (is.na(hit)) return(list(source_of(code)))
  used[[hit]] <<- TRUE
  outs <- list()
  for (o in entries[[hit]]$outputs) {
    out <- as_output(o)
    if (is.null(out)) next
    # a table brings more than one piece (the table and maybe a note)
    if (is.list(out) && !inherits(out, "condition")) outs <- c(outs, out) else outs <- c(outs, list(out))
  }
  c(list(source_of(code)), outs)
}

# Inline `r` code that fails outside the notebook's session stays as code.
inline <- knitr::knit_hooks$get("evaluate.inline")
knitr::knit_hooks$set(evaluate.inline = function(code, envir = knitr::knit_global()) {
  tryCatch(inline(code, envir), error = function(e) paste0("`r ", code, "`"))
})

out <- rmarkdown::render(input, output_format = "html_notebook",
                         output_options = list(output_source = output_source),
                         envir = new.env(parent = globalenv()), quiet = TRUE)
cat(normalizePath(out), "\n", sep = "")
