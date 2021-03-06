##' Validate an odin model.  This function is closer to
##' \code{\link{odin_}} than \code{\link{odin}} because it does not do
##' any quoting of the code.  It is primarily intended for use within
##' other applications.
##'
##' @title Validate an odin model
##'
##' @inheritParams odin_parse
##'
##' @export
##' @author Rich FitzJohn
odin_validate <- function(x, type = NULL, options = NULL) {
  msg <- collector_list()
  .odin$note_function <- msg$add
  on.exit(.odin$note_function <- NULL)

  ## NOTE: this does not involve the cache at all, though it possibly
  ## should.  If we do involve the cache we'll need to come up with
  ## something that can be purged or we'll have memory grow without
  ## bounds.
  res <- tryCatch(
    odin_parse_(x, type = type, options = options),
    error = identity)

  success <- !inherits(res, "error")
  error <- if (success) NULL else res
  result <- if (success) res  else NULL

  list(success = success,
       result = result,
       error = error,
       messages = msg$get())
}
