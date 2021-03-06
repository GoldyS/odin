context("odin_validate")


test_that("valid model", {
  code <- c("initial(x) <- 1", "deriv(x) <- 1")
  res <- odin_validate(code, "text")
  expect_true(res$success)
  expect_null(res$error)
  expect_is(res$result, "json")
  expect_equal(res$messages, list())
})


test_that("invalid model", {
  code <- c("initial(x) <- 1", "deriv(x)")
  res <- odin_validate(code, "text")
  expect_false(res$success)
  expect_null(res$result)
  expect_is(res$error, "odin_error")
  expect_equal(res$messages, list())
})


test_that("unused variables can be detected", {
  code <- c("initial(x) <- 1", "deriv(x) <- 1", "a <- 1")
  res <- odin_validate(code, "text")
  expect_equal(length(res$messages), 1L)
  expect_match(res$messages[[1]]$msg, "Unused equation: a")
  expect_equivalent(res$messages[[1]]$line, 3)
})


test_that("invalid R", {
  code <- c("a b")
  res <- odin_validate(code, "text")
  expect_false(res$success)
  expect_null(res$result)
  expect_is(res$error, "error")
  expect_equal(res$messages, list())
})
