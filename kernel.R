#!/usr/bin/env Rscript
# ============================================================================
# tern-rmd kernel -- a persistent R session for the Tern "rmd" plugin.
#
# The plugin (Luau host) spawns this script and talks to it over HTTP/1.1 on
# 127.0.0.1.  Launch (cwd is also DOCDIR):
#
#   TERN_RMD_TOKEN=T TERN_RMD_PROOF=P \
#     Rscript kernel.R --port PORT --dir DOCDIR --data DATADIR [--idle S] [--log FILE]
#
# Secrets travel in the environment, never in argv, so `ps` cannot show them.
#
# Exit status: 2 = bad arguments / unusable data dir, 3 = cannot bind port,
#              4 = required R package missing, 0 = clean shutdown/idle exit.
#
# Endpoints (all require the request header `X-Token: T`, case-insensitive):
#   GET  /ping      -> {"ok":true,"pid":<int>,"version":"4.6.1","kernel":"2.0.0"}
#   POST /exec      -> {"ok":true,"outputs":[...],"ms":<num>,
#                       "error":<bool>,"interrupted":<bool>,"skipped":<bool>}
#   POST /complete  -> {"ok":true,"token":"mod","matches":[...]}
#   GET  /vars      -> {"ok":true,"vars":[{"name","class","summary"},...]}
#   POST /shutdown  -> {"ok":true}, then exit(0)
#
# Everything else: 403 {"ok":false,"error":"bad token"}, 404 unknown path,
# 400 malformed body, 500 internal error.  Every response carries
# `Content-Type: application/json; charset=utf-8`, an exact byte
# `Content-Length`, `Connection: close` and `X-Proof: P`.
#
# Security model:
#  * The server is R's own HTTP server (the one behind dynamic help), which
#    listens on 127.0.0.1 only: the session is unreachable from the network.
#    The kernel replaces that server's request router, so R's help pages and
#    session files are never served; every request goes through the token
#    check.
#  * `X-Token` authenticates the plugin to the kernel.  `X-Proof` (a second
#    secret the plugin generated) authenticates the kernel to the plugin: a
#    process squatting on the port cannot answer as this session.
#  * DATADIR (outputs, plots, logs) is made private to the user (mode 0700).
#
# Notes for the host (things that are easy to get wrong):
#  * requests are served one at a time; a request sent while /exec runs waits
#    until the chunk has finished.
#  * send SIGINT to the R process itself (Rscript and the sh wrapper below
#    exec into it, so its pid is the one /ping reports).  A SIGINT outside
#    user code is harmless: the kernel keeps serving.
#  * `--idle 0` (or negative) disables the idle timeout.  Only authenticated
#    requests count as activity.
#  * /exec runs the code in globalenv() with the session's variables, so
#    `ls()`, /vars and /complete all see the same objects.
#  * the kernel keeps every one of its own objects in a private environment:
#    a chunk only ever sees the user's objects, `rm(list = ls())` cannot delete
#    the server's functions and user code cannot shadow them.  Only the View()
#    shim is put on the search path (as the environment "tern:rmd").
#  * sourcing this file (tests, debugging) defines nothing and starts nothing;
#    it only serves when Rscript / R -f runs it as the program.
#
# Session behaviour worth knowing:
#  * cwd is DOCDIR; it is re-applied before every /exec so a stray setwd()
#    inside one chunk cannot break the next one (knitr-like).
#  * plots are recorded on a temporary white-background PNG device sized
#    fig.width x fig.height inches at `dpi` (tempdir(), removed afterwards).
#    Because the recording device and the output PNG have the same geometry,
#    the written PNG is byte-identical to rendering the same code directly at
#    that size.  Plot files are DATADIR/<id>-<n>.png where n counts the plots
#    that survived (1..n in output order); re-running the same chunk id
#    overwrites the same files.
#  * printed text is byte-exact R output (R itself pads the first line of a
#    sink'ed block with a space -- knitr output shows the same).
#  * `error=TRUE` keeps going at top-level-expression granularity, exactly like
#    knitr: the rest of the failing statement is skipped, the following ones
#    run.  Default: the error stops the chunk.
#  * the reply's `error` says an error stopped the chunk, so the chunks queued
#    after it should not run (as in Jupyter and RStudio).  The errors of an
#    `error=TRUE` chunk are part of its output and don't count; an interrupt
#    always does.
#  * `results='hide'` drops printed output *and* table outputs (both are
#    "results"); warning=/message=FALSE drop those items; other knitr options
#    (echo, include, ...) are accepted and ignored.
#  * output is bounded so a runaway chunk cannot freeze the notebook: a text
#    item keeps its first and last characters (TEXT_LIMIT), a chunk keeps at
#    most MAX_ITEMS items (errors always survive), and a reply that would
#    still exceed REPLY_LIMIT bytes drops its trailing items.  Each cut is
#    announced in the output.
#  * the stream file gets every output item as one JSON object per line, as
#    soon as it is produced, except plots: those lines are appended once the
#    chunk finished and the PNGs were written (a plot line therefore always
#    points at an existing file).  The final response is authoritative.
#  * SIGINT during /exec stops evaluation, keeps the session state and returns
#    the outputs gathered so far plus {"type":"error","text":"Interrupted"}.
#  * View(x) is overridden (on the search path as "tern:rmd") and produces a
#    `table` output instead of failing; the table is inserted where the View()
#    call happened.
#  * console capture: when the plugin redirects fd 1/fd 2 of the R process into
#    a file (its launch is `sh -c 'exec "$@" >>"$TERN_RMD_LOG" 2>&1' sh Rscript
#    kernel.R ...`, or pass `--log PATH`), the kernel reads that file back and
#    reports it as {"type":"console","text":...,"upto":<bytes>} items, so
#    R CMD INSTALL, system() and REprintf output appear in the notebook in
#    order.  The log is emptied at the start of every exec, flushed before
#    every other output item and once at the end, so console and R-level output
#    interleave (cat("a"); system("echo b"); cat("c") -> text a, console b,
#    text c).  Items larger than 64 KiB are cut to first 8 KiB + a note + last
#    48 KiB and carry `file`, the exec's full log copied to
#    DATADIR/<id>-console.log.  While a console log is active, kernel
#    diagnostics go to DATADIR/kernel.log instead of stderr; without a log
#    they go to stderr.
#    Caveat: R cannot wake itself while it is blocked inside one long silent
#    subprocess, so such a subprocess delivers its output at the next R-level
#    output (which install.packages() produces between steps).
# ============================================================================

# ============================================================================
# Everything below runs inside one private environment: no kernel object ever
# lands in globalenv().  /vars and ls() therefore show only the user's own
# objects, a chunk starting with `rm(list = ls())` cannot delete the server's
# own functions, and a user variable can never shadow them either.  User code
# is still evaluated in globalenv() (see exec_chunk).  The block is a no-op
# when the file is source()d (tests, debugging): it only starts serving when
# Rscript / R -f runs this very file.
# ============================================================================
local({

  # the kernel's own environment (`environment()` at the top of the block);
  # the View() shim gets it as its parent so it can reach these helpers
  KERNEL_ENV <- environment()

  # Bumped with every protocol change: the plugin restarts a session whose
  # kernel version differs from the one it ships with.
  KERNEL_VERSION <- "2.0.0"

  # Output bounds (see "output is bounded" above).  REPLY_LIMIT stays well
  # under the 16 MiB the plugin's HTTP client accepts for one reply.
  TEXT_LIMIT <- 200000L                  # characters per text-like item
  MAX_ITEMS <- 2000L                     # output items per chunk
  REPLY_LIMIT <- 12 * 1024^2             # bytes of JSON per /exec reply
  STREAM_LIMIT <- 8 * 1024^2             # bytes written to the stream file

  # ---------------------------------------------------------------- utilities

  `%||%` <- function(a, b) if (is.null(a)) b else a

  # A very long text keeps its first three quarters and its last quarter of
  # TEXT_LIMIT characters, with a note where the middle was cut.
  clip_text <- function(txt) {
    if (!is.character(txt) || length(txt) != 1L || is.na(txt)) return(txt)
    n <- nchar(txt, type = "chars", allowNA = TRUE)
    if (is.na(n)) {
      # not valid in its encoding: count bytes instead
      n <- nchar(txt, type = "bytes")
      if (n <= TEXT_LIMIT) return(txt)
      txt <- iconv(txt, from = "UTF-8", to = "UTF-8", sub = "?")
      n <- nchar(txt, type = "chars", allowNA = TRUE)
      if (is.na(n)) return("<unprintable output>")
    }
    if (n <= TEXT_LIMIT + 1000L) return(txt)
    head <- TEXT_LIMIT %/% 4L * 3L
    tail <- TEXT_LIMIT %/% 4L
    paste0(substr(txt, 1L, head),
           sprintf("\n\u2026 %s characters omitted \u2026\n",
                   format(n - head - tail, big.mark = ",")),
           substr(txt, n - tail + 1L, n))
  }

  # Text-like items carry `text`; tables, plots and console items do not need
  # clipping (console items are cut by flush_console itself).
  clip_item <- function(item) {
    if (item$type %in% c("text", "message", "warning", "error")) item$text <- clip_text(item$text)
    item
  }

  # Diagnostics.  When a console log is active (see the console section below)
  # fd 2 belongs to the user, so kernel messages go to DATADIR/kernel.log
  # instead of stderr.
  log_msg <- function(...) {
    msg <- paste0(format(Sys.time(), "[%H:%M:%S]"), " ", paste0(..., collapse = ""), "\n")
    target <- if (is.null(cfg)) NULL else cfg$kernel_log
    if (is.null(target)) {
      cat(msg, sep = "", file = stderr())
    } else {
      tryCatch(cat(msg, sep = "", file = target, append = TRUE),
               error = function(e) cat(msg, sep = "", file = stderr()))
    }
  }

  # Raw bytes of fd 1/2 output -> a JSON-safe string.  Compiler output is not
  # guaranteed to be valid UTF-8 and may even contain NULs.
  console_text <- function(bytes) {
    if (!length(bytes)) return("")
    bytes[bytes == as.raw(0L)] <- charToRaw("?")
    txt <- tryCatch(rawToChar(bytes), error = function(e) NULL)
    if (is.null(txt)) return("<unprintable console output>")
    Encoding(txt) <- "UTF-8"
    out <- tryCatch(iconv(txt, from = "UTF-8", to = "UTF-8", sub = "?"),
                    error = function(e) NA_character_)
    if (length(out) != 1L || is.na(out)) {
      out <- tryCatch(iconv(txt, from = "latin1", to = "UTF-8", sub = "?"),
                      error = function(e) NA_character_)
    }
    if (length(out) != 1L || is.na(out)) "<unprintable console output>" else out
  }

  # Deparse a condition call the way the plugin wants it: "" when absent.
  deparse_call <- function(cl) {
    if (is.null(cl)) return("")
    txt <- tryCatch(paste(deparse(cl), collapse = " "), error = function(e) "")
    trimws(txt)
  }

  # Keep a JSON-safe scalar id for use inside plot file names.
  sanitize_id <- function(id) {
    id <- paste0(id)
    id <- gsub("[^A-Za-z0-9._-]", "_", id)
    if (!nzchar(id) || id == "." || id == "..") "e" else substr(id, 1L, 64L)
  }

  num_or <- function(x, default) {
    if (is.null(x) || length(x) != 1L) return(default)
    v <- suppressWarnings(as.numeric(x))
    if (length(v) != 1L || is.na(v) || !is.finite(v)) default else v
  }

  json_str <- function(x) {
    # One line, UTF-8, exactly the shape the plugin parses.
    as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null",
                                  na = "null", digits = NA))
  }

  # ------------------------------------------------------------- table outputs

  # Short type tags used by the plugin's table renderer.
  col_type <- function(v) {
    if (is.factor(v)) "fct"
    else if (inherits(v, "Date")) "date"
    else if (inherits(v, "POSIXt")) "dttm"
    else if (is.character(v)) "chr"
    else if (is.logical(v)) "lgl"
    else if (is.integer(v)) "int"
    else if (is.numeric(v)) "dbl"
    else if (is.list(v)) "list"
    else "other"
  }

  # One string per cell.  `format()` per column, NA rendered as "NA".
  col_cells <- function(v, n) {
    if (n <= 0L) return(character(0))
    vv <- if (length(v) >= n) v[seq_len(n)] else v
    out <- tryCatch(format_col(vv), error = function(e) NULL)
    if (is.null(out) || length(out) != length(vv)) out <- rep("<unprintable>", length(vv))
    out <- as.character(out)
    if (length(out) != length(vv)) out <- rep("", length(vv))
    out[is.na(vv)] <- "NA"
    out[is.na(out)] <- "NA"
    out
  }

  format_col <- function(v) {
    if (is.factor(v)) v <- as.character(v)
    if (is.list(v) && !is.data.frame(v)) {
      # list columns: scalar atomics format(), everything else deparsed
      return(vapply(v, function(el) {
        if (is.null(el)) "NULL"
        else if (is.atomic(el) && length(el) == 1L) format(el, trim = TRUE)
        else paste(deparse(el), collapse = " ")
      }, ""))
    }
    if (is.matrix(v) || is.data.frame(v)) {
      return(apply(format(v, trim = TRUE), 1L, paste, collapse = " "))
    }
    format(v, trim = TRUE, justify = "none")
  }

  # A `table` output item for a data.frame (incl. tibble/data.table) or matrix.
  make_table_item <- function(x, max_rows) {
    if (is.matrix(x)) {
      n_r <- nrow(x); n_c <- ncol(x)
      cols <- lapply(seq_len(n_c), function(j) x[, j])
      col_names <- colnames(x) %||% as.character(seq_len(n_c))
      row_names <- dimnames(x)[[1L]]
      default_rn <- is.null(row_names)          # matrices have no row names unless set
      cls <- class(x)[[1L]]
    } else {
      n_r <- nrow(x); n_c <- ncol(x)
      cols <- lapply(seq_len(n_c), function(j) x[[j]])
      col_names <- names(x) %||% rep("", n_c)
      row_names <- attr(x, "row.names")
      # .row_names_info(x, 1L) is <= 0 while the row names are the automatic 1..n
      default_rn <- tryCatch(.row_names_info(x, 1L) <= 0L, error = function(e) TRUE)
      cls <- class(x)[[1L]]
    }
    n_show <- if (is.na(max_rows) || max_rows < 0) n_r else min(as.integer(max_rows), n_r)
    n_show <- as.integer(n_show)

    cells <- matrix("", nrow = n_show, ncol = n_c)
    for (j in seq_len(n_c)) cells[, j] <- col_cells(cols[[j]], n_show)
    rows <- lapply(seq_len(n_show), function(i) I(cells[i, , drop = TRUE]))

    default_rn <- default_rn || length(row_names) == 0L
    # NA names would reach the plugin as JSON null; R prints them as "NA"
    rn <- if (default_rn) NULL else as.character(row_names)[seq_len(n_show)]
    if (!is.null(rn)) rn <- I(ifelse(is.na(rn), "NA", rn))
    col_names <- as.character(col_names)
    col_names[is.na(col_names)] <- "NA"

    list(
      type = "table",
      class = cls,
      nrow = n_r,
      ncol = n_c,
      cols = I(col_names),
      types = I(vapply(cols, col_type, "")),
      rownames = rn,
      rows = rows
    )
  }

  is_table_value <- function(x) is.data.frame(x) || is.matrix(x)

  # ------------------------------------------------- output collection (exec)

  new_collector <- function(max_rows, stream_con, hide) {
    col <- new.env(parent = emptyenv())
    col$items <- list()
    col$n <- 0L
    col$dropped <- 0L        # items past MAX_ITEMS, announced at the end
    col$max_rows <- max_rows
    col$stream <- stream_con
    col$stream_bytes <- 0
    col$hide_text <- isTRUE(hide$text)
    col$hide_message <- isTRUE(hide$message)
    col$hide_warning <- isTRUE(hide$warning)
    col$stream_ok <- !is.null(stream_con)
    # console (fd 1/2) capture, see flush_console() below
    col$id <- "e"
    col$console_path <- NULL
    col$console_offset <- 0
    col$console_truncated <- FALSE
    col$console_file <- NULL
    col
  }

  # Chunk options can silence whole classes of output (results='hide' drops
  # printed results, warning=/message=FALSE drop those conditions).  Used for
  # both the stream file and the final response, so the two always agree.
  item_wanted <- function(col, item) {
    type <- item$type
    if (identical(type, "text") || identical(type, "table")) return(!isTRUE(col$hide_text))
    if (identical(type, "message")) return(!isTRUE(col$hide_message))
    if (identical(type, "warning")) return(!isTRUE(col$hide_warning))
    TRUE
  }

  write_stream_line <- function(col, item) {
    if (is.null(col$stream) || !isTRUE(col$stream_ok)) return(invisible(NULL))
    err <- tryCatch({
      line <- json_str(clip_item(item))
      col$stream_bytes <- col$stream_bytes + nchar(line, type = "bytes") + 1
      if (col$stream_bytes > STREAM_LIMIT) {
        # the live view has shown enough; the final reply has the rest
        line <- json_str(list(type = "message",
                              text = "\u2026 more output arrives when the chunk finishes\n"))
        col$stream_ok <- FALSE
      }
      cat(line, "\n", sep = "", file = col$stream)
      flush(col$stream)
      NULL
    }, error = function(e) conditionMessage(e))
    if (!is.null(err)) {
      log_msg("stream write failed: ", err)
      col$stream_ok <- FALSE
    }
    if (!isTRUE(col$stream_ok)) {
      tryCatch(close(col$stream), error = function(e) NULL)
      col$stream <- NULL
    }
    invisible(NULL)
  }

  # Append an item to the response (and the stream file) without touching the
  # console log; used by everything, including the console reader itself.
  # Past MAX_ITEMS only errors are kept: they decide whether the chunk failed.
  col_add_item <- function(col, item) {
    if (col$n >= MAX_ITEMS && !identical(item$type, "error")) {
      col$dropped <- col$dropped + 1L
      return(invisible(NULL))
    }
    col$n <- col$n + 1L
    col$items[[col$n]] <- item
    if (item_wanted(col, item)) write_stream_line(col, item)
    invisible(NULL)
  }

  # Collect whatever went to fd 1/fd 2 (R's own C-level output and every
  # subprocess: R CMD INSTALL, system(), REprintf, ...) since the last call and
  # push it as a `console` item, so it interleaves in order with the R-level
  # output.  Called before every other output item and once at the end of an
  # exec.  Never signals.
  flush_console <- function(col) {
    path <- col$console_path
    if (is.null(path)) return(invisible(NULL))
    err <- tryCatch({
      flush(stdout())
      flush(stderr())
      size <- suppressWarnings(file.size(path))
      if (is.na(size) || size <= col$console_offset) return(invisible(NULL))
      con <- file(path, open = "rb")
      on.exit(close(con), add = TRUE)
      seek(con, where = col$console_offset, origin = "start")
      # bounded read: a runaway chunk cannot exhaust memory, the rest is
      # picked up by the next flush (and the full log stays in `path`)
      bytes <- readBin(con, "raw", n = min(size - col$console_offset, 8 * 1024^2))
      if (!length(bytes)) return(invisible(NULL))
      col$console_offset <- col$console_offset + length(bytes)
      item <- list(type = "console", text = console_text(bytes), upto = col$console_offset)
      if (length(bytes) > 65536L) {
        if (is.null(col$console_file)) {
          col$console_file <- file.path(cfg$data_dir,
                                        sprintf("%s-console.log", col$id))
        }
        col$console_truncated <- TRUE
        note <- sprintf("\n… %d bytes omitted — the full log is in %s …\n",
                        length(bytes) - 8192L - 49152L, col$console_file)
        item$text <- paste0(console_text(bytes[seq_len(8192L)]), note,
                            console_text(bytes[(length(bytes) - 49152L + 1L):length(bytes)]))
        item$file <- col$console_file
      }
      col_add_item(col, item)
      NULL
    }, error = function(e) conditionMessage(e))
    if (!is.null(err)) {
      log_msg("console read failed: ", err)
      col$console_path <- NULL      # do not repeat the complaint every item
    }
    invisible(NULL)
  }

  push_item <- function(col, item) {
    flush_console(col)
    col_add_item(col, item)
    invisible(NULL)
  }

  # evaluate() output handlers.  Everything is funnelled through these so that
  # the collected items survive an interrupt (evaluate's return value does not).
  make_output_handler <- function(col) {
    safe <- function(what, expr) {
      tryCatch(expr, error = function(e) {
        log_msg("output handler ", what, " failed: ", conditionMessage(e))
        invisible(NULL)
      })
    }
    evaluate::new_output_handler(
      # sources are not part of the response; a 2-argument handler that returns
      # NULL makes evaluate() skip pushing them altogether
      source = function(src, call) NULL,
      text = function(txt) safe("text", {
        if (length(txt)) push_item(col, list(type = "text", text = paste(txt, collapse = "")))
      }),
      graphics = function(plot) safe("graphics", {
        # keep the recorded plot; PNGs are written once the chunk has finished
        push_item(col, list(type = "plot", plot = plot, file = NULL,
                            width = NULL, height = NULL))
      }),
      message = function(cnd) safe("message", {
        push_item(col, list(type = "message", text = conditionMessage(cnd)))
      }),
      warning = function(cnd) safe("warning", {
        push_item(col, list(type = "warning", text = conditionMessage(cnd),
                            call = deparse_call(conditionCall(cnd))))
      }),
      error = function(cnd) safe("error", {
        push_item(col, list(type = "error", text = conditionMessage(cnd),
                            call = deparse_call(conditionCall(cnd))))
      }),
      value = function(value, visible, envir) safe("value", {
        if (!visible) return(invisible(NULL))
        if (is_table_value(value)) {
          push_item(col, make_table_item(value, col$max_rows))
          return(invisible(NULL))
        }
        # same as evaluate's default renderer, but we own the printing so the
        # captured text lands in the right place in our item list
        if (isS4(value)) {
          methods::show(value)
        } else {
          print_env <- new.env(parent = envir)
          print_env$value <- value
          evalq(print(value), envir = print_env)
        }
        invisible(NULL)
      })
    )
  }

  # ------------------------------------------------------------ chunk options

  # knitr chunk options ("fig.width=8, warning=FALSE", possibly starting with a
  # bare label such as "setup, include=FALSE").  The text must parse as the
  # arguments of one call, so a `)` cannot close the call early and smuggle in
  # a second expression; malformed text is ignored.  Option values are R
  # expressions evaluated in globalenv(), as knitr does when it runs the chunk.
  parse_chunk_opts <- function(text) {
    if (!is.character(text) || length(text) != 1L || is.na(text)) return(list())
    text <- trimws(text)
    if (!nzchar(text)) return(list())
    exprs <- tryCatch(parse(text = sprintf("alist(%s)", text), keep.source = FALSE),
                      error = function(e) NULL)
    if (length(exprs) != 1L || !is.call(exprs[[1L]]) ||
        !identical(exprs[[1L]][[1L]], as.name("alist"))) return(list())
    args <- as.list(exprs[[1L]])[-1L]
    nms <- names(args)
    if (is.null(nms)) return(list())
    out <- list()
    for (i in seq_along(args)) {
      nm <- nms[[i]]
      if (!nzchar(nm)) next                         # bare label: skip, do not eval
      v <- tryCatch(eval(args[[i]], envir = globalenv()), error = function(e) NULL)
      if (!is.null(v)) out[[nm]] <- v
    }
    out
  }

  # ------------------------------------------------------------ plot handling

  # Display-list entry -> engine operation name (R >= 4.5 stores fn + args where
  # the first argument is a NativeSymbolInfo; older R stored a call).
  dl_op_name <- function(entry) {
    x <- tryCatch(entry[[2]][[1]], error = function(e) NULL)
    nm <- NULL
    if (is.list(x) && !is.null(x[["name"]])) nm <- as.character(x[["name"]])
    else if (is.call(x)) nm <- as.character(x[[1]])
    if (is.null(nm) && is.list(entry) && !is.null(entry[["name"]])) nm <- as.character(entry[["name"]])
    if (is.null(nm) || !length(nm) || is.na(nm[[1]])) "" else nm[[1]]
  }

  # Operations that never put ink on the page (page setup / bookkeeping).
  page_setup_ops <- c("C_plot_new", "C_plot_window", "C_par", "C_clip", "C_layout",
                      "C_strHeight", "C_strWidth", "palette", "palette2", "C_palette",
                      "C_palette2")

  page_is_blank <- function(plot) {
    dl <- plot[[1]]
    if (!length(dl)) return(TRUE)
    ops <- vapply(dl, dl_op_name, "")
    # unknown operations count as visual: never drop a plot we do not understand
    !any(!(ops %in% page_setup_ops))
  }

  # TRUE when display list `a` is a prefix of `b` (same plot, more drawing added).
  dl_is_prefix <- function(a, b) {
    na <- length(a); nb <- length(b)
    if (na > nb) return(FALSE)
    if (na == 0L) return(TRUE)
    for (i in seq_len(na)) if (!identical(a[[i]], b[[i]])) return(FALSE)
    TRUE
  }

  # The PNG backend for both the recording device and the written plots (the
  # two must match for byte-identical output).  Cairo when R has it, else
  # R's own default, so an R built without cairo still draws plots.
  png_type <- function() {
    if (isTRUE(capabilities("cairo"))) "cairo" else getOption("bitmapType")
  }

  # Replay a recorded plot into a PNG.  The target device must have the display
  # list enabled or replayPlot() is a silent no-op (R >= 4.5 behaviour).
  render_plot <- function(plot, file, width_px, height_px, dpi) {
    opened <- FALSE
    painted <- FALSE
    tryCatch({
      grDevices::png(filename = file, width = width_px, height = height_px,
                     res = dpi, type = png_type(), bg = "white")
      opened <- TRUE
      grDevices::dev.control(displaylist = "enable")
      grDevices::replayPlot(plot)
      painted <- TRUE
    }, error = function(e) {
      log_msg("plot replay failed: ", conditionMessage(e))
    })
    if (opened) tryCatch(grDevices::dev.off(), error = function(e) NULL)
    if (!painted) tryCatch(unlink(file), error = function(e) NULL)
    painted
  }

  # Turn the collected plot snapshots into final `plot` items: drop the
  # intermediate snapshots of a plot that is still being built up, drop blank
  # pages, replay the rest into DATADIR/<id>-<n>.png and stream those items.
  finalise_plots <- function(col, items, id, data_dir, fig_w, fig_h, dpi) {
    idx <- which(vapply(items, function(it) identical(it$type, "plot"), TRUE))
    if (!length(idx)) return(items)

    keep <- rep(TRUE, length(idx))
    if (length(idx) >= 2L) {
      for (k in 2:length(idx)) {
        prev <- items[[idx[k - 1L]]]$plot
        cur <- items[[idx[k]]]$plot
        if (dl_is_prefix(prev[[1L]], cur[[1L]])) keep[k - 1L] <- FALSE
      }
    }
    for (k in seq_along(idx)) {
      if (keep[k] && page_is_blank(items[[idx[k]]]$plot)) keep[k] <- FALSE
    }

    width_px <- max(1L, as.integer(round(fig_w * dpi)))
    height_px <- max(1L, as.integer(round(fig_h * dpi)))
    css_w <- max(1L, as.integer(round(fig_w * 96)))
    css_h <- max(1L, as.integer(round(fig_h * 96)))

    rendered <- vector("list", length(idx))
    n_plot <- 0L
    for (k in seq_along(idx)) {
      if (!keep[k]) next
      n_plot <- n_plot + 1L
      file <- file.path(data_dir, sprintf("%s-%d.png", id, n_plot))
      if (!render_plot(items[[idx[k]]]$plot, file, width_px, height_px, dpi)) next
      item <- list(type = "plot", file = file, width = css_w, height = css_h)
      rendered[[k]] <- item
      if (item_wanted(col, item)) write_stream_line(col, item)
    }

    out <- list()
    n <- 0L
    k <- 0L
    for (i in seq_along(items)) {
      if (i %in% idx) {
        k <- k + 1L
        if (!is.null(rendered[[k]])) {
          n <- n + 1L
          out[[n]] <- rendered[[k]]
        }
      } else {
        n <- n + 1L
        out[[n]] <- items[[i]]
      }
    }
    out
  }

  # Merge runs of consecutive text items into one item.
  merge_text_items <- function(items) {
    out <- list()
    n <- 0L
    for (it in items) {
      if (identical(it$type, "text") && n > 0L && identical(out[[n]]$type, "text")) {
        out[[n]]$text <- paste0(out[[n]]$text, it$text)
      } else {
        n <- n + 1L
        out[[n]] <- it
      }
    }
    out
  }

  # --------------------------------------------------------------- /exec

  # Flush anything evaluate captured but has not handed to us yet.  Used by the
  # View() override so the table appears after the text that preceded it.
  flush_pending_output <- function() {
    tryCatch({
      f <- get("flush_console", envir = asNamespace("evaluate"))
      if (is.function(f)) f()
    }, error = function(e) NULL)
    invisible(NULL)
  }

  current_collector <- function() state$collector

  exec_chunk <- function(req) {
    t_start <- Sys.time()
    body <- req$body %||% list()
    code <- body$code
    if (!is.character(code) || length(code) != 1L) {
      return(list(status = 400L, payload = list(ok = FALSE, error = "missing code")))
    }
    code <- enc2utf8(code)
    id <- sanitize_id(body$id %||% "e")
    width <- max(20, num_or(body$width, 80))
    fig_w <- num_or(body$fig_width, 7)
    fig_h <- num_or(body$fig_height, 5)
    dpi <- num_or(body$dpi, 192)
    max_rows <- num_or(body$max_rows, 1000)
    if (max_rows < 0) max_rows <- 0
    opts <- parse_chunk_opts(body$opts)
    stream_path <- if (is.character(body$stream) && length(body$stream) == 1L && nzchar(body$stream)) body$stream else NULL

    # fig.width / fig.height / fig.dim chunk options
    if (is.numeric(opts[["fig.dim"]]) && length(opts[["fig.dim"]]) >= 2L) {
      fig_w <- as.numeric(opts[["fig.dim"]][1L])
      fig_h <- as.numeric(opts[["fig.dim"]][2L])
    }
    if (is.numeric(opts[["fig.width"]]) && length(opts[["fig.width"]]) >= 1L) fig_w <- as.numeric(opts[["fig.width"]][1L])
    if (is.numeric(opts[["fig.height"]]) && length(opts[["fig.height"]]) >= 1L) fig_h <- as.numeric(opts[["fig.height"]][1L])
    if (!is.finite(fig_w) || fig_w <= 0 || fig_w > 200) fig_w <- 7
    if (!is.finite(fig_h) || fig_h <= 0 || fig_h > 200) fig_h <- 5
    if (!is.finite(dpi) || dpi < 24 || dpi > 1200) dpi <- 192
    if (!is.finite(width) || width < 20 || width > 10000) width <- 80
    # keep the recording device sane: at most 10000 px on its longer edge
    if (max(fig_w, fig_h) * dpi > 10000) dpi <- 10000 / max(fig_w, fig_h)

    hide <- list(text = identical(opts[["results"]], "hide"),
                 message = isFALSE(opts[["message"]]),
                 warning = isFALSE(opts[["warning"]]))
    keep_going <- isTRUE(opts[["error"]])
    skip <- isFALSE(opts[["eval"]])

    stream_con <- NULL
    if (!is.null(stream_path)) {
      stream_con <- tryCatch(file(stream_path, open = "w"), error = function(e) {
        log_msg("cannot open stream file ", stream_path, ": ", conditionMessage(e))
        NULL
      })
    }
    col <- new_collector(max_rows, stream_con, hide)
    col$id <- id

    # Console capture: fd 1/fd 2 of this process are the plugin's console log
    # (see the header).  Start every exec from an empty log so console output
    # is attributed to the chunk that produced it.
    if (!is.null(cfg$console_log)) {
      err <- tryCatch({
        flush(stdout())
        flush(stderr())
        # file.create() truncates an existing file (file.truncate does not
        # exist in this R); O_APPEND writers continue at the new end
        file.create(cfg$console_log, showWarnings = FALSE)
        NULL
      }, error = function(e) conditionMessage(e))
      if (!is.null(err)) {
        log_msg("cannot reset console log ", cfg$console_log, ": ", err)
      }
      col$console_path <- cfg$console_log
      col$console_offset <- 0
    }

    state$collector <- col
    on.exit({
      state$collector <- NULL
      # write_stream_line() may have closed the stream already
      if (!is.null(col$stream)) tryCatch(close(col$stream), error = function(e) NULL)
    }, add = TRUE)

    # The reply, from what the collector gathered.  Safe to run again after an
    # interrupt: console flushing resumes at its offset and nothing else here
    # has side effects.
    finish <- function(skipped, interrupted) {
      # everything the chunk wrote to fd 1/2 belongs before the response
      flush_console(col)
      if (isTRUE(col$console_truncated) && !is.null(col$console_file)) {
        same_path <- isTRUE(tryCatch(identical(normalizePath(cfg$console_log, mustWork = FALSE),
                                               normalizePath(col$console_file, mustWork = FALSE)),
                                     error = function(e) FALSE))
        if (!same_path) {
          ok <- tryCatch(file.copy(cfg$console_log, col$console_file, overwrite = TRUE),
                         error = function(e) FALSE)
          if (!isTRUE(ok)) log_msg("cannot copy console log to ", col$console_file)
        }
      }
      items <- col$items
      keep <- vapply(items, function(it) item_wanted(col, it), TRUE)
      items <- merge_text_items(items[keep])
      # plot items are already final (type/file/width/height); a plot that was
      # never rendered (chunk interrupted, replay failed) is dropped
      items <- lapply(items, function(it) {
        if (identical(it$type, "plot")) {
          if (is.null(it$file)) return(NULL)
          return(it)
        }
        it$plot <- NULL
        clip_item(it)
      })
      items <- items[!vapply(items, is.null, TRUE)]
      if (col$dropped > 0L) {
        items[[length(items) + 1L]] <- note_item(sprintf(
          "%s more outputs not shown (a chunk shows at most %s)",
          format(col$dropped, big.mark = ","), format(MAX_ITEMS, big.mark = ",")))
      }
      ms <- round(as.numeric(difftime(Sys.time(), t_start, units = "secs")) * 1000, 1)
      # see `error` in the header: errors that error=TRUE let through don't
      # stop what is queued after the chunk
      has_error <- any(vapply(items, function(it) identical(it$type, "error"), TRUE))
      stopped <- isTRUE(interrupted) || (has_error && !keep_going)
      payload <- list(ok = TRUE, outputs = items, ms = ms, error = stopped,
                      interrupted = interrupted, skipped = skipped)
      json <- json_str(payload)
      if (nchar(json, type = "bytes") > REPLY_LIMIT) {
        payload$outputs <- fit_items(items)
        json <- json_str(payload)
      }
      list(status = 200L, json = json)
    }

    if (skip) return(finish(TRUE, FALSE))

    # knitr-like: each chunk starts in DOCDIR
    tryCatch(setwd(cfg$doc_dir), error = function(e) NULL)

    # Recording device: a PNG with the target geometry and a white background so
    # replaying the snapshots produces exactly what was drawn.
    scratch <- file.path(tempdir(), sprintf("tern-%s-%d-scratch.png", id, Sys.getpid()))
    dev_num <- NA_integer_
    device_ok <- tryCatch({
      grDevices::png(filename = scratch, width = max(1L, as.integer(round(fig_w * dpi))),
                     height = max(1L, as.integer(round(fig_h * dpi))), res = dpi,
                     type = png_type(), bg = "white")
      grDevices::dev.control(displaylist = "enable")
      dev_num <- grDevices::dev.cur()
      TRUE
    }, error = function(e) {
      log_msg("cannot open graphics device: ", conditionMessage(e))
      FALSE
    })
    on.exit({
      if (!is.na(dev_num) && dev_num %in% grDevices::dev.list()) {
        tryCatch(grDevices::dev.off(dev_num), error = function(e) NULL)
      }
      tryCatch(unlink(scratch), error = function(e) NULL)
    }, add = TRUE)
    if (!device_ok) {
      push_item(col, list(type = "error", call = "",
                          text = "cannot open a graphics device; plots are unavailable in this chunk"))
    }

    handler <- make_output_handler(col)
    old_opts <- options(width = width)
    on.exit(options(old_opts), add = TRUE)

    close_recorder <- function() {
      if (!is.na(dev_num) && dev_num %in% grDevices::dev.list()) {
        tryCatch(grDevices::dev.off(dev_num), error = function(e) NULL)
      }
      dev_num <<- NA_integer_
    }

    interrupted <- FALSE
    tryCatch({
      infra_error <- NULL
      tryCatch(
        evaluate::evaluate(code, envir = globalenv(),
                           stop_on_error = if (keep_going) 0L else 1L,
                           new_device = FALSE, output_handler = handler),
        error = function(e) infra_error <<- conditionMessage(e)
      )
      if (!is.null(infra_error)) {
        push_item(col, list(type = "error", text = paste0("kernel: ", infra_error), call = ""))
      }
      # the recording device is closed before the individual plots are rendered
      close_recorder()
      if (device_ok) {
        col$items <- tryCatch(finalise_plots(col, col$items, id, cfg$data_dir, fig_w, fig_h, dpi),
                              error = function(e) {
                                log_msg("plot finalise failed: ", conditionMessage(e))
                                col$items
                              })
      }
    }, interrupt = function(e) {
      interrupted <<- TRUE
      close_recorder()
    })

    if (interrupted) {
      push_item(col, list(type = "error", text = "Interrupted", call = ""))
    }
    # A second SIGINT (`i i` pressed twice) can land while the reply is being
    # built; build it again rather than lose the chunk's outputs.
    for (attempt in 1:5) {
      res <- tryCatch(finish(FALSE, interrupted), interrupt = function(e) NULL)
      if (!is.null(res)) return(res)
    }
    interrupted_reply()
  }

  # A muted line in the output saying what was left out.
  note_item <- function(text) {
    list(type = "message", text = paste0("\u2026 ", text, "\n"))
  }

  # The leading outputs that fit in REPLY_LIMIT, plus a note saying how many
  # did not.  Errors always stay: they are small once clipped, and they tell
  # the plugin the chunk failed.
  fit_items <- function(items) {
    sizes <- vapply(items, function(it) nchar(json_str(it), type = "bytes") + 1, 0)
    is_error <- vapply(items, function(it) identical(it$type, "error"), TRUE)
    budget <- REPLY_LIMIT - 65536 - sum(sizes[is_error])
    keep <- is_error | cumsum(ifelse(is_error, 0, sizes)) <= budget
    c(items[keep], list(note_item(sprintf(
      "%d outputs were too large to show here; write big results to a file instead",
      sum(!keep)))))
  }

  # What /exec answers when an interrupt hit outside the chunk's own code.
  interrupted_reply <- function() {
    list(status = 200L, payload = list(
      ok = TRUE, ms = 0, error = TRUE, interrupted = TRUE, skipped = FALSE,
      outputs = list(list(type = "error", text = "Interrupted", call = ""))))
  }

  # ------------------------------------------------------------- /complete

  complete_line <- function(line) {
    out <- tryCatch({
      utils:::.assignLinebuffer(line)
      utils:::.assignEnd(nchar(line))
      token <- utils:::.guessTokenFromLine()
      utils:::.completeToken()
      list(token = token, matches = utils:::.retrieveCompletions())
    }, error = function(e) list(token = "", matches = character(0)))
    token <- out$token
    if (!is.character(token) || length(token) != 1L || is.na(token)) token <- ""
    matches <- tryCatch(as.character(out$matches), error = function(e) character(0))
    if (is.null(matches)) matches <- character(0)
    if (length(matches) > 200L) matches <- matches[seq_len(200L)]
    list(ok = TRUE, token = token, matches = I(matches))
  }

  # ------------------------------------------------------------------ /vars

  global_vars <- function() {
    nms <- ls(globalenv())
    vars <- lapply(nms, function(nm) {
      x <- tryCatch(get(nm, envir = globalenv()), error = function(e) NULL)
      cls <- tryCatch(class(x)[[1L]], error = function(e) "unknown")
      if (is.null(cls) || is.na(cls)) cls <- "unknown"
      summary <- tryCatch({
        lines <- utils::capture.output(str(x, max.level = 0, give.attr = FALSE))
        if (!length(lines)) "" else {
          txt <- gsub("[[:space:]]+", " ", trimws(lines[[1L]]))
          substr(txt, 1L, 120L)
        }
      }, error = function(e) "")
      if (!nzchar(summary)) summary <- cls
      list(name = nm, class = cls, summary = summary)
    })
    list(ok = TRUE, vars = vars)
  }

  # --------------------------------------------------------------------- HTTP
  #
  # Requests arrive through R's built-in HTTP server (Rhttpd, started in
  # main()): it listens on 127.0.0.1 only, reads each request whole and calls
  # tools:::httpd(path, query, body, headers), which the kernel replaces with
  # `dispatch` below.  Rhttpd runs one request at a time on R's main thread,
  # whenever the main loop sleeps.  Two Rhttpd facts shape the code: it does
  # not tell a handler the method of a request (GET and POST differ only in
  # the body), and it swallows form-encoded bodies, so POST bodies must be
  # sent as application/json.

  # The header block Rhttpd hands over ("Name: value" lines) -> a list with
  # lower-case names.  A line that is not valid text is skipped.
  parse_headers <- function(raw) {
    out <- list()
    lines <- tryCatch(strsplit(rawToChar(raw), "\r?\n", useBytes = TRUE)[[1L]],
                      error = function(e) character(0))
    for (ln in lines) {
      kv <- tryCatch({
        name <- sub(":.*$", "", ln, useBytes = TRUE)
        if (identical(name, ln) || !nzchar(name)) NULL
        else list(tolower(trimws(name)), trimws(sub("^[^:]*:", "", ln, useBytes = TRUE)))
      }, error = function(e) NULL)
      if (!is.null(kv)) out[[kv[[1L]]]] <- kv[[2L]]
    }
    out
  }

  # The JSON body of a POST, or NULL when it is missing or malformed.
  parse_body <- function(body) {
    if (!is.raw(body) || !length(body)) return(NULL)
    txt <- tryCatch(rawToChar(body), error = function(e) NULL)
    if (is.null(txt)) return(NULL)
    Encoding(txt) <- "UTF-8"
    tryCatch(jsonlite::fromJSON(txt), error = function(e) NULL)
  }

  # A reply in Rhttpd's format: list(body, content type, headers, status).
  # Only replies to an authenticated request carry X-Proof, which shows the
  # plugin that this session, and not some other program on the port,
  # answered; a client without the token never learns it.
  http_reply <- function(status, json, proof = TRUE) {
    headers <- c(if (proof) paste0("X-Proof: ", cfg$proof), "Connection: close")
    list(charToRaw(enc2utf8(json)), "application/json; charset=utf-8", headers,
         as.integer(status))
  }

  # The endpoints, by path alone (see above; every one needs the token).
  # Returns list(status, payload) or list(status, json).
  route <- function(path, body) {
    if (identical(path, "/ping")) {
      return(list(status = 200L, payload = list(ok = TRUE, pid = Sys.getpid(),
                                                version = as.character(getRversion()),
                                                kernel = KERNEL_VERSION)))
    }
    if (identical(path, "/exec")) {
      req <- parse_body(body)
      if (is.null(req)) {
        return(list(status = 400L, payload = list(
          ok = FALSE, error = "invalid json body (send it as Content-Type: application/json)")))
      }
      return(exec_chunk(list(body = req)))
    }
    if (identical(path, "/complete")) {
      req <- parse_body(body)
      line <- if (is.list(req) && is.character(req$line) && length(req$line) == 1L) req$line else ""
      if (is.na(line)) line <- ""
      return(list(status = 200L, payload = complete_line(line)))
    }
    if (identical(path, "/vars")) {
      return(list(status = 200L, payload = global_vars()))
    }
    if (identical(path, "/shutdown")) {
      # the main loop exits once this reply has been sent
      state$shutdown <- TRUE
      return(list(status = 200L, payload = list(ok = TRUE)))
    }
    list(status = 404L, payload = list(ok = FALSE, error = "not found"))
  }

  # Rhttpd's entry point (installed as tools:::httpd).  The token check comes
  # first; authenticated traffic, before and after the work, is what keeps an
  # idle session alive.  A SIGINT that lands outside a chunk's code (it was
  # meant for a chunk that had just finished) must not cost the reply: /exec
  # answers "Interrupted", the other requests change nothing and are served
  # again.
  dispatch <- function(path, query = NULL, body = NULL, headers = NULL, ...) {
    h <- tryCatch(parse_headers(headers), error = function(e) list(),
                  interrupt = function(e) list())
    if (!identical(h[["x-token"]], cfg$token)) {
      return(http_reply(403L, json_str(list(ok = FALSE, error = "bad token")), proof = FALSE))
    }
    on.exit(state$last_seen <- Sys.time(), add = TRUE)
    for (attempt in 1:3) {
      res <- tryCatch({
        state$last_seen <- Sys.time()
        route(path, body)
      }, interrupt = function(e) NULL,
         error = function(e) {
           log_msg("unhandled error: ", conditionMessage(e))
           list(status = 500L, payload = list(ok = FALSE, error = paste0("kernel: ", conditionMessage(e))))
         })
      if (!is.null(res)) return(http_reply(res$status, res$json %||% json_str(res$payload)))
      if (identical(path, "/exec")) return(http_reply(200L, json_str(interrupted_reply()$payload)))
    }
    http_reply(500L, json_str(list(ok = FALSE, error = "interrupted")))
  }

  # ------------------------------------------------------------- arguments

  usage <- function() {
    cat("usage: TERN_RMD_TOKEN=T TERN_RMD_PROOF=P Rscript kernel.R --port PORT",
        "--dir DOCDIR --data DATADIR [--idle SECONDS] [--log FILE]\n", file = stderr())
  }

  # Flags take their value as `--flag value` or `--flag=value`.
  parse_argv <- function(argv) {
    env <- function(name) { v <- Sys.getenv(name); if (nzchar(v)) v else NULL }
    out <- list(port = NULL, token = env("TERN_RMD_TOKEN"), proof = env("TERN_RMD_PROOF"),
                dir = NULL, data = NULL, idle = 120, log = NULL)
    flags <- c("--port", "--dir", "--data", "--idle", "--log")
    i <- 1L
    while (i <= length(argv)) {
      arg <- argv[[i]]
      inline <- grepl("=", arg, fixed = TRUE)
      key <- if (inline) sub("=.*$", "", arg) else arg
      if (!key %in% flags) {
        i <- i + 1L
        next
      }
      val <- if (inline) sub("^[^=]*=", "", arg) else if (i < length(argv)) argv[[i + 1L]] else NULL
      i <- i + if (inline) 1L else 2L
      switch(key,
             "--port" = out$port <- suppressWarnings(as.integer(val)),
             "--dir" = out$dir <- val,
             "--data" = out$data <- val,
             "--idle" = out$idle <- suppressWarnings(as.numeric(val)),
             "--log" = out$log <- val)
    }
    out
  }

  # ------------------------------------------------------------------ setup

  setup_session <- function(cfg) {
    setwd(cfg$doc_dir)

    repos <- getOption("repos")
    cran <- if (is.null(repos)) NULL else unname(repos["CRAN"])
    if (is.null(cran) || is.na(cran) || !nzchar(cran) || identical(cran, "@CRAN@")) {
      options(repos = c(CRAN = "https://cloud.r-project.org"))
    }

    lib <- Sys.getenv("R_LIBS_USER")
    if (nzchar(lib)) {
      for (p in strsplit(lib, .Platform$path.sep, fixed = TRUE)[[1L]]) {
        p <- path.expand(trimws(p))
        if (!nzchar(p)) next
        if (!dir.exists(p)) {
          tryCatch(dir.create(p, recursive = TRUE, showWarnings = FALSE), error = function(e) NULL)
        }
        if (dir.exists(p) && !(p %in% .libPaths())) .libPaths(c(p, .libPaths()))
      }
    }

    # ANSI output survives: the plugin renders escape sequences
    options(crayon.enabled = TRUE, cli.num_colors = 256L)
    # never let R fall back to opening Rplots.pdf inside the document directory
    options(device = function(...) grDevices::pdf(file = NULL))
    # immediate warnings instead of R's deferred warning buffer
    options(warn = 1L)

    # View(x) -> table output.  The shim sits on the search path, so user code
    # finds it, but its parent is the kernel environment: the helpers stay
    # invisible to chunks.
    tern_env <- new.env(parent = KERNEL_ENV)
    tern_env$View <- function(x, title) {
      col <- current_collector()
      if (!is.null(col)) {
        flush_pending_output()
        item <- tryCatch({
          if (is_table_value(x)) {
            make_table_item(x, col$max_rows)
          } else {
            df <- tryCatch(as.data.frame(x), error = function(e) NULL)
            if (!is.null(df)) make_table_item(df, col$max_rows) else NULL
          }
        }, error = function(e) NULL)
        if (is.null(item)) {
          txt <- tryCatch(paste(utils::capture.output(print(x)), collapse = "\n"),
                          error = function(e) "<unprintable>")
          push_item(col, list(type = "text", text = paste0(txt, "\n")))
        } else {
          push_item(col, item)
        }
      }
      invisible(x)
    }
    # attach() announces the masked View(); keep the kernel's stderr clean
    invisible(utils::capture.output(suppressMessages(attach(tern_env, name = "tern:rmd"))))
    invisible(tern_env)
  }

  # ------------------------------------------------------------------- main

  main <- function() {
    argv <- commandArgs(trailingOnly = TRUE)
    args <- parse_argv(argv)
    # The secrets are in cfg now; chunks (Sys.getenv(), system("env")) and
    # every subprocess they start must not see them.
    Sys.unsetenv(c("TERN_RMD_TOKEN", "TERN_RMD_PROOF"))

    if (is.null(args$port) || is.na(args$port) || args$port < 1L || args$port > 65535L ||
        is.null(args$token) || is.null(args$proof) ||
        is.null(args$dir) || is.null(args$data)) {
      usage()
      quit(save = "no", status = 2L)
    }

    cfg$port <- as.integer(args$port)
    cfg$token <- args$token
    cfg$proof <- args$proof
    cfg$doc_dir <- tryCatch(normalizePath(args$dir, mustWork = FALSE), error = function(e) args$dir)
    cfg$data_dir <- tryCatch(normalizePath(args$data, mustWork = FALSE), error = function(e) args$data)
    cfg$idle <- if (is.null(args$idle) || is.na(args$idle)) 120 else as.numeric(args$idle)
    # console log (fd 1/2 of this process and of every subprocess it starts)
    # and, while that is active, where kernel diagnostics must go instead
    cfg$console_log <- NULL
    cfg$kernel_log <- NULL
    if (!dir.exists(cfg$doc_dir)) {
      log_msg("document directory does not exist: ", cfg$doc_dir)
      quit(save = "no", status = 2L)
    }
    if (!dir.exists(cfg$data_dir)) {
      if (!dir.create(cfg$data_dir, recursive = TRUE, showWarnings = FALSE)) {
        log_msg("data directory does not exist and cannot be created: ", cfg$data_dir)
        quit(save = "no", status = 2L)
      }
    }
    # outputs, plots and logs can hold anything a chunk printed: keep them
    # away from other users of this machine
    Sys.chmod(cfg$data_dir, mode = "0700", use_umask = FALSE)
    probe <- file.path(cfg$data_dir, sprintf(".tern-write-test-%d", Sys.getpid()))
    if (!tryCatch({ file.create(probe); TRUE }, error = function(e) FALSE) || !file.exists(probe)) {
      log_msg("data directory is not writable: ", cfg$data_dir)
      quit(save = "no", status = 2L)
    }
    unlink(probe)

    # Where the plugin redirects fd 1/fd 2 (see the header): --log wins, then
    # TERN_RMD_LOG.  Without it the kernel behaves exactly as before.
    console_log <- args$log
    if (is.null(console_log) || !nzchar(console_log)) console_log <- Sys.getenv("TERN_RMD_LOG")
    if (nzchar(console_log)) {
      console_log <- tryCatch(normalizePath(console_log, mustWork = FALSE),
                              error = function(e) console_log)
      cfg$console_log <- console_log
      cfg$kernel_log <- file.path(cfg$data_dir, "kernel.log")
    }

    # evaluate 1.0.4 is the first 1.x that keeps new_device = FALSE from
    # opening a device of its own, which the plot recording relies on.
    needs <- c(evaluate = "1.0.4", jsonlite = "1.7.0")
    for (pkg in names(needs)) {
      if (!requireNamespace(pkg, quietly = TRUE) ||
          utils::packageVersion(pkg) < needs[[pkg]]) {
        log_msg("required R package is missing or too old: ", pkg, " (needs ", needs[[pkg]], ")")
        quit(save = "no", status = 4L)
      }
    }

    setup_session(cfg)
    state$collector <- NULL
    state$shutdown <- FALSE

    # Serve through Rhttpd (see the HTTP section): stop a help server the
    # user's .Rprofile may have started, route every request to `dispatch`,
    # then listen on 127.0.0.1:PORT.  (utils::assignInNamespace() refuses base
    # namespaces when called from a function, hence the explicit unlock.)
    Sys.unsetenv("R_DISABLE_HTTPD")
    tryCatch(suppressMessages(tools::startDynamicHelp(FALSE)), error = function(e) NULL)
    tools_ns <- asNamespace("tools")
    unlockBinding("httpd", tools_ns)
    assign("httpd", dispatch, envir = tools_ns)
    lockBinding("httpd", tools_ns)
    options(help.ports = cfg$port)
    port <- tryCatch(suppressMessages(suppressWarnings(tools::startDynamicHelp(TRUE))),
                     error = function(e) {
                       log_msg("cannot start the HTTP server: ", conditionMessage(e))
                       -1L
                     })
    if (!identical(suppressWarnings(as.integer(port)), cfg$port)) {
      log_msg("cannot listen on 127.0.0.1:", cfg$port)
      quit(save = "no", status = 3L)
    }

    log_msg("kernel ", KERNEL_VERSION, " listening on 127.0.0.1:", cfg$port,
            " (pid ", Sys.getpid(), ", R ", as.character(getRversion()), ")")

    # Rhttpd answers requests while R sleeps here; the loop itself only
    # checks whether it is time to go.
    state$last_seen <- Sys.time()
    repeat {
      tryCatch({
        Sys.sleep(0.25)
        if (isTRUE(state$shutdown)) {
          log_msg("shutdown requested")
          quit(save = "no", status = 0L)
        }
        idle_for <- as.numeric(difftime(Sys.time(), state$last_seen, units = "secs"))
        if (cfg$idle > 0 && idle_for > cfg$idle) {
          log_msg("idle timeout (", cfg$idle, "s), exiting")
          quit(save = "no", status = 0L)
        }
      }, error = function(e) log_msg("loop error: ", conditionMessage(e)),
         interrupt = function(e) log_msg("interrupt while idle ignored"))
    }
  }

  # Shared session state.  Both are environments, not lists, so every function
  # below can mutate them in place (a `cfg$field <- x` on a list would only
  # touch a local copy).  They live in the kernel's private environment, so
  # output handlers and the View() shim can reach them while user code cannot.
  state <- new.env(parent = emptyenv())
  cfg <- new.env(parent = emptyenv())

  # Start serving only when this file is the program R was asked to run
  # (Rscript / R -f).  A source()d file has a frame carrying `ofile`, which is
  # how tests and debugging reuse this file without starting a server.
  sourced <- vapply(seq_len(sys.nframe()),
                    function(i) is.character(sys.frame(i)$ofile), TRUE)
  if (!any(sourced)) main()
})
