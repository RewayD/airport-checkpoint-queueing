args <- commandArgs(trailingOnly = FALSE)
script_arg <- grep("^--file=", args, value = TRUE)
script_path <- normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE)
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)

required_packages <- c(
  "dplyr",
  "ggplot2",
  "knitr",
  "lubridate",
  "purrr",
  "readr",
  "rmarkdown",
  "tidyr"
)
missing_packages <- setdiff(required_packages, rownames(installed.packages()))
if (length(missing_packages) > 0) {
  stop(
    paste0(
      "Install the following packages before running the pipeline: ",
      paste(missing_packages, collapse = ", ")
    ),
    call. = FALSE
  )
}

dir.create(file.path(project_root, "report"), recursive = TRUE, showWarnings = FALSE)

if (!rmarkdown::pandoc_available()) {
  machine <- Sys.info()[["machine"]]
  candidate <- if (identical(machine, "arm64")) {
    "/Applications/RStudio.app/Contents/Resources/app/quarto/bin/tools/aarch64"
  } else {
    "/Applications/RStudio.app/Contents/Resources/app/quarto/bin/tools/x86_64"
  }
  if (file.exists(file.path(candidate, "pandoc"))) {
    Sys.setenv(RSTUDIO_PANDOC = candidate)
  }
}
if (!rmarkdown::pandoc_available()) {
  stop("Pandoc was not found. Render from RStudio or install Pandoc.", call. = FALSE)
}

source(file.path(project_root, "tests", "test_queueing_functions.R"), local = new.env())
source(file.path(project_root, "scripts", "01_generate_synthetic_data.R"), local = new.env())
source(file.path(project_root, "scripts", "02_analyze_queue.R"), local = new.env())

rmarkdown::render(
  input = file.path(project_root, "analysis", "airport_checkpoint_queueing.Rmd"),
  output_file = "airport_checkpoint_queueing.html",
  output_dir = file.path(project_root, "report"),
  knit_root_dir = project_root,
  clean = TRUE,
  quiet = FALSE,
  envir = new.env(parent = globalenv())
)

docs_dir <- file.path(project_root, "docs")
dir.create(docs_dir, recursive = TRUE, showWarnings = FALSE)
copied <- file.copy(
  file.path(project_root, "report", "airport_checkpoint_queueing.html"),
  file.path(docs_dir, "index.html"),
  overwrite = TRUE
)
if (!isTRUE(copied)) stop("Could not copy the report into docs/.", call. = FALSE)

capture.output(
  sessionInfo(),
  file = file.path(project_root, "results", "sessionInfo.txt")
)

message("Pipeline complete. Open report/airport_checkpoint_queueing.html.")
