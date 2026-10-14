#!/usr/bin/env Rscript
# deps.R -- checks for, and installs, the R packages the R Notebook plugin uses.
#
#   Rscript deps.R                    report; exit status 1 when a package needed
#                                     to run chunks is missing or too old
#   Rscript deps.R --install          install what running chunks needs
#   Rscript deps.R --install --knit   ... and rmarkdown too, for knitting
#
# Packages go to your personal R library (created when it doesn't exist yet),
# from CRAN unless you chose another repository.  Nothing needs root.

needed <- c(evaluate = "1.0.4", jsonlite = "1.7.0")   # running chunks
knitting <- c(rmarkdown = "2.0")                       # knitting (needs Pandoc too)

args <- commandArgs(trailingOnly = TRUE)
install <- "--install" %in% args
with_knit <- "--knit" %in% args

# Reads the installed version without loading the package, so a newer one can
# still be installed in this session.
installed_ok <- function(pkg, min) {
  v <- tryCatch(utils::packageVersion(pkg), error = function(e) NULL)
  !is.null(v) && v >= min
}

report <- function(pkgs, why) {
  missing <- character(0)
  for (pkg in names(pkgs)) {
    if (installed_ok(pkg, pkgs[[pkg]])) {
      cat(sprintf("  ok       %s %s%s\n", pkg, utils::packageVersion(pkg), why))
    } else {
      cat(sprintf("  missing  %s (%s or newer)%s\n", pkg, pkgs[[pkg]], why))
      missing <- c(missing, pkg)
    }
  }
  missing
}

# The first entry of R_LIBS_USER, created and put first on the library path.
personal_library <- function() {
  lib <- strsplit(Sys.getenv("R_LIBS_USER"), .Platform$path.sep, fixed = TRUE)[[1L]]
  lib <- path.expand(lib[nzchar(lib)][1L])
  if (is.na(lib)) stop("R_LIBS_USER is not set, so there is no personal library to install into")
  if (!dir.exists(lib) && !dir.create(lib, recursive = TRUE, showWarnings = FALSE)) {
    stop("cannot create the personal library ", lib)
  }
  .libPaths(c(lib, .libPaths()))
  lib
}

cat(sprintf("R %s\n", getRversion()))
if (getRversion() < "4.0.0") {
  cat("  R 4.0 or newer is needed; get a current R from https://cloud.r-project.org\n")
  quit(save = "no", status = 1L)
}
missing <- report(needed, "")
missing_knit <- report(knitting, "  (for knitting)")
# Pandoc as rmarkdown finds it (including RStudio's copy), else on the PATH.
pandoc <- tryCatch(
  if (rmarkdown::pandoc_available()) as.character(rmarkdown::pandoc_version()) else NA_character_,
  error = function(e) {
    if (!nzchar(Sys.which("pandoc"))) return(NA_character_)
    v <- tryCatch(system2("pandoc", "--version", stdout = TRUE)[1L], error = function(e) "")
    sub("^pandoc\\S*\\s+", "", v)
  })
if (!is.na(pandoc)) {
  cat(sprintf("  ok       Pandoc %s  (for knitting)\n", pandoc))
} else {
  cat("  missing  Pandoc  (for knitting: https://pandoc.org/installing.html, or install RStudio)\n")
}

to_install <- c(if (install) missing, if (install && with_knit) missing_knit)
if (length(to_install)) {
  lib <- personal_library()
  repos <- getOption("repos")
  if (is.null(repos) || is.na(repos["CRAN"]) || identical(unname(repos["CRAN"]), "@CRAN@")) {
    repos <- c(CRAN = "https://cloud.r-project.org")
  }
  cat(sprintf("\nInstalling %s into %s ...\n", paste(to_install, collapse = ", "), lib))
  utils::install.packages(to_install, lib = lib, repos = repos)
  still <- names(needed)[!vapply(names(needed), function(p) installed_ok(p, needed[[p]]), TRUE)]
  if (length(still)) {
    cat(sprintf("\nStill missing: %s (see the messages above)\n", paste(still, collapse = ", ")))
    quit(save = "no", status = 1L)
  }
  cat("\nDone.\n")
  quit(save = "no", status = 0L)
}

if (length(missing)) {
  cat("\nTo install what running chunks needs:  Rscript deps.R --install\n")
  quit(save = "no", status = 1L)
}
