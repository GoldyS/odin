## Not a great name, but this section will create the code that *will*
## be compiled (i.e., the C sources).  The name can get picked up
## later.
generate_c_compiled <- function(eqs, dat, rewrite) {
  core <- list(get_internal = generate_c_compiled_get_internal(dat),
               finalise = generate_c_compiled_finalise(dat, rewrite),
               create = generate_c_compiled_create(eqs, dat, rewrite),
               initmod_desolve = generate_c_compiled_initmod_desolve(dat),
               contents = generate_c_compiled_contents(dat, rewrite),
               set_user = generate_c_compiled_set_user(eqs, dat),
               set_initial = generate_c_compiled_set_initial(dat, rewrite),
               metadata = generate_c_compiled_metadata(dat, rewrite),
               initial_conditions =
                 generate_c_compiled_initial_conditions(dat, rewrite))

  if (dat$features$discrete) {
    core$rhs <- generate_c_compiled_update(eqs, dat, rewrite)
    core$rhs_dde <- generate_c_compiled_update_dde(dat)
  } else {
    core$rhs <- generate_c_compiled_deriv(eqs, dat, rewrite)
    core$rhs_dde <- generate_c_compiled_deriv_dde(dat)
    core$rhs_desolve <- generate_c_compiled_deriv_desolve(dat)
    core$output <- generate_c_compiled_output(eqs, dat, rewrite)
  }
  core$rhs_r <- generate_c_compiled_rhs_r(dat, rewrite)

  core <- core[!vlapply(core, is.null)]

  list(name = lapply(core, "[[", "name"),
       declaration = unname(vcapply(core, "[[", "declaration")),
       definition = c_flatten_eqs(c(lapply(core, "[[", "definition"))))
}


generate_c_compiled_headers <- function() {
  c("#include <R.h>",
    "#include <Rmath.h>",
    "#include <Rinternals.h>",
    "#include <stdbool.h>",
    "#include <R_ext/Rdynload.h>")
}


generate_c_compiled_struct <- function(dat) {
  struct_element <- function(x) {
    type <- x$storage_type
    if (type == "interpolate_data") {
      type <- "void"
    }
    is_ptr <- x$rank > 0L || type == "ring_buffer" || type == "void"
    sprintf(if (is_ptr) "%s *%s;" else "%s %s;", type, x$name)
  }
  i <- vcapply(dat$data$elements, "[[", "location") == "internal"
  els <- vcapply(unname(dat$data$elements[i]), struct_element)

  body <- collector()
  body$add("typedef struct %s {", dat$meta$c$internal_t)
  body$add(paste0("  ", els), literal = TRUE)
  body$add("} %s;", dat$meta$c$internal_t)

  body$get()
}


generate_c_compiled_finalise <- function(dat, rewrite) {
  ptr <- dat$meta$c$ptr
  internal <- dat$meta$internal
  internal_t <- dat$meta$c$internal_t

  body <- collector()
  body$add("%s *%s = %s(%s, 0);",
          internal_t, internal, dat$meta$c$get_internal, ptr)
  body$add("if (%s) {", ptr)

  storage_type <- vcapply(dat$data$elements, "[[", "storage_type")
  if (dat$features$has_interpolate) {
    i <- names_if(storage_type == "interpolate_data")
    body$add("  cinterpolate_free(%s);", vcapply(i, rewrite))
    body$add("  %s = NULL;", vcapply(i, rewrite))
  }

  if (dat$features$has_delay && dat$features$discrete) {
    i <- names_if(storage_type == "ring_buffer")
    body$add("  ring_buffer_destroy(%s);", vcapply(i, rewrite))
    body$add("  %s = NULL;", vcapply(i, rewrite))
  }

  if (dat$features$has_array || dat$features$has_delay) {
    for (el in dat$data$elements) {
      if (el$rank > 0 && el$location == "internal" &&
          el$storage_type %in% c("int", "double")) {
        body$add("  Free(%s->%s);", internal, el$name)
      }
    }
  }

  body$add("  Free(%s);", internal)
  body$add("  R_ClearExternalPtr(%s);", ptr)
  body$add("}")

  ret <- c_function("void", dat$meta$c$finalise,
                    c(SEXP = dat$meta$c$ptr),
                    body$get())
  ret$declaration <- paste("static", ret$declaration)
  ret
}


generate_c_compiled_get_internal <- function(dat) {
  internal_t <- dat$meta$c$internal_t
  internal <- dat$meta$internal
  ptr <- dat$meta$c$ptr

  body <- collector()
  body$add("%s *%s = NULL;", internal_t, internal)
  body$add("if (TYPEOF(%s) != EXTPTRSXP) {", ptr)
  body$add('  Rf_error("Expected an external pointer");')
  body$add("}")
  body$add("%s = (%s*) R_ExternalPtrAddr(%s);", internal, internal_t, ptr)
  body$add("if (!%s && closed_error) {", internal)
  body$add('  Rf_error("Pointer has been invalidated");')
  body$add("}")
  body$add("return %s;", internal)

  c_function(paste0(internal_t, "*"), dat$meta$c$get_internal,
             c(SEXP = ptr, int = "closed_error"),
             body$get())
}


generate_c_compiled_create <- function(eqs, dat, rewrite) {
  ptr <- "ptr"
  internal <- dat$meta$internal
  internal_t <- dat$meta$c$internal_t

  body <- collector()
  body$add("%s *%s = (%s*) Calloc(1, %s);",
           internal_t, internal, internal_t, internal_t)

  ## Assign all arrays as NULL, which allows all allocations to be
  ## written as Free/Calloc because Free will not try to free a
  ## pointer that has been set to NULL.
  ##
  ## NOTE: previously we ignored user equations here
  ##   !identical(dat$equations[[x$name]]$type, "user")
  ## but I don't think that's needed
  null_initial <- names_if(vlapply(dat$data$elements, function(x) {
    (x$rank > 0 && x$location == "internal") ||
      x$storage_type == "ring_buffer"
  }))

  body$add("%s = NULL;", vcapply(null_initial, rewrite, USE.NAMES = FALSE))

  body$add(c_flatten_eqs(eqs[dat$components$create$equations]))

  if (dat$features$has_user) {
    user_names <- vcapply(dat$user, "[[", "name")
    user <- vcapply(user_names, generate_c_compiled_create_user, dat, rewrite,
                    USE.NAMES = FALSE)
    body$add(user)
  }

  if (dat$features$has_delay && !dat$features$discrete) {
    body$add("%s = NA_REAL;", rewrite(dat$meta$initial_time))
  }

  body$add("SEXP %s = PROTECT(R_MakeExternalPtr(%s, R_NilValue, R_NilValue));",
           ptr, internal)
  body$add("R_RegisterCFinalizer(%s, %s);", ptr, dat$meta$c$finalise)
  body$add("UNPROTECT(1);")
  body$add("return %s;", ptr)

  args <- c(SEXP = dat$meta$user)

  c_function("SEXP", dat$meta$c$create, args, body$get())
}


generate_c_compiled_deriv <- function(eqs, dat, rewrite) {
  variables <- dat$components$rhs$variables
  equations <- dat$components$rhs$equations

  unpack <- lapply(variables, c_unpack_variable, dat, dat$meta$state, rewrite)

  body <- collector()
  body$add(c_flatten_eqs(c(unpack, eqs[equations])))

  if (dat$features$has_output) {
    variables_output <- setdiff(dat$components$output$variables, variables)
    unpack_output <- lapply(variables_output, c_unpack_variable, dat,
                            dat$meta$state, rewrite)
    equations_output <- setdiff(dat$components$output$equations, equations)
    output <- c_flatten_eqs(c(unpack_output, eqs[equations_output]))

    body$add("if (output) {")
    body$add(paste0("  ", output), literal = TRUE)
    body$add("}")
  }

  args <- c(set_names(dat$meta$internal, paste0(dat$meta$c$internal_t, "*")),
            double = dat$meta$time,
            "double *" = dat$meta$state,
            "double *" = dat$meta$result,
            "double *" = dat$meta$output)
  c_function("void", dat$meta$c$rhs, args, body$get())
}


generate_c_compiled_output <- function(eqs, dat, rewrite) {
  if (!dat$features$has_output) {
    return(NULL)
  }

  variables <- dat$components$output$variables
  equations <- dat$components$output$equations

  unpack <- lapply(variables, c_unpack_variable, dat, dat$meta$state, rewrite)

  body <- collector()
  body$add("%s *%s = (%s*) %s;",
           dat$meta$c$internal_t, dat$meta$internal, dat$meta$c$internal_t,
           dat$meta$c$ptr)
  body$add(c_flatten_eqs(c(unpack, eqs[equations])), literal = TRUE)
  args <- c("size_t" = "n_eq",
            "double" = dat$meta$time,
            "double *" = dat$meta$state,
            "size_t" = "n_output",
            "double *" = dat$meta$output,
            "void *" = dat$meta$c$ptr)

  c_function("void", dat$meta$c$output_dde, args, body$get())
}


## NOTE: This uses deSolve's really peculiar global variable approach
## for getting the parameters into the function.  In the previous
## version of odin, we had a wrapper function that passed the
## parameters into a downstream function, but here we're going to
## avoid that and just generate out
generate_c_compiled_deriv_desolve <- function(dat) {
  body <- sprintf_safe("%s(%s, *%s, %s, %s, %s);",
                       dat$meta$c$rhs, dat$meta$c$internal_ds, dat$meta$time,
                       dat$meta$state, dat$meta$result, dat$meta$output)
  args <- c("int *" = "neq",
            "double *" = dat$meta$time,
            "double *" = dat$meta$state,
            "double *" = dat$meta$result,
            "double *" = dat$meta$output,
            "int *" = "np")
  c_function("void", dat$meta$c$rhs_desolve, args, body)
}


generate_c_compiled_deriv_dde <- function(dat) {
  args <- c("size_t" = "neq",
            "double" = dat$meta$time,
            "double *" = dat$meta$state,
            "double *" = dat$meta$result,
            "void *" = dat$meta$internal)
  body <- sprintf_safe("%s((%s*)%s, %s, %s, %s, NULL);",
                       dat$meta$c$rhs, dat$meta$c$internal_t,
                       dat$meta$internal, dat$meta$time, dat$meta$state,
                       dat$meta$result, dat$meta$output)
  c_function("void", dat$meta$c$rhs_dde, args, body)
}


generate_c_compiled_rhs_r <- function(dat, rewrite) {
  discrete <- dat$features$discrete
  if (discrete) {
    time_access <- "INTEGER"
    time_type <- "int"
  } else {
    time_access <- "REAL"
    time_type <- "double"
  }
  body <- collector()
  body$add("SEXP %s = PROTECT(allocVector(REALSXP, LENGTH(%s)));",
          dat$meta$result, dat$meta$state)
  body$add("%s *%s = %s(%s, 1);",
          dat$meta$c$internal_t, dat$meta$internal,
          dat$meta$c$get_internal, dat$meta$c$ptr)
  if (dat$features$has_output) {
    output_ptr <- sprintf("%s_ptr", dat$meta$output)
    body$add("SEXP %s = PROTECT(allocVector(REALSXP, %s));",
             output_ptr, rewrite(dat$data$output$length))
    body$add('setAttrib(%s, install("%s"), %s);',
             dat$meta$result, dat$meta$output, output_ptr)
    body$add("UNPROTECT(1);")
    body$add("double *%s = REAL(%s);", dat$meta$output, output_ptr)
  } else {
    body$add("double *%s = NULL;", dat$meta$output)
  }

  if(dat$features$has_stochastic) {
    body$add("GetRNGstate();")
  }

  eval_rhs <- sprintf_safe(
    "%s(%s, %s(%s)[0], REAL(%s), REAL(%s), %s);",
    dat$meta$c$rhs, dat$meta$internal, time_access, dat$meta$time,
    dat$meta$state, dat$meta$result, dat$meta$output)

  ## In order to run the derivative calculation safely, we have to set
  ## the initial time.  But in order to make this safe, we need to put
  ## that back later (because otherwise after the first evaluation of
  ## the derivative it might look like we have the ability to compute
  ## derivatives with history but that history does not actually exist
  ## yet).
  if (dat$features$has_delay) {
    initial_time <- rewrite(dat$meta$initial_time)
    set_initial_time <- c(
      sprintf_safe("const %s %s = %s;",
                   time_type, dat$meta$initial_time, initial_time),
      c_expr_if(sprintf_safe("ISNA(%s)", dat$meta$initial_time),
                sprintf_safe("%s = %s(%s)[0];",
                             initial_time, time_access, dat$meta$time)))
    reset_initial_time <-
      c_expr_if(sprintf_safe("ISNA(%s)", dat$meta$initial_time),
                sprintf_safe("%s = %s;", initial_time, dat$meta$initial_time))
    body$add(c(set_initial_time, eval_rhs, reset_initial_time))
  } else {
    body$add(eval_rhs)
  }

  if(dat$features$has_stochastic) {
    body$add("PutRNGstate();")
  }

  body$add("UNPROTECT(1);")
  body$add("return %s;", dat$meta$result)

  args <- c(SEXP = dat$meta$c$ptr, SEXP = dat$meta$time, SEXP = dat$meta$state)
  c_function("SEXP", dat$meta$c$rhs_r, args, body$get())
}


generate_c_compiled_update <- function(eqs, dat, rewrite) {
  variables <- union(dat$components$rhs$variables,
                     dat$components$output$variables)
  equations <- union(dat$components$rhs$equations,
                     dat$components$output$equations)
  unpack <- lapply(variables, c_unpack_variable, dat, dat$meta$state, rewrite)
  body <- c_flatten_eqs(c(unpack, eqs[equations]))

  args <- c(set_names(dat$meta$internal, paste0(dat$meta$c$internal_t, "*")),
            "size_t" = dat$meta$time,
            "double *" = dat$meta$state,
            "double *" = dat$meta$result,
            "double *" = dat$meta$output)
  c_function("void", dat$meta$c$rhs, args, body)
}


generate_c_compiled_update_dde <- function(dat, rewrite) {
  args <- c("size_t" = "n_eq",
            "size_t" = dat$meta$time,
            "double *" = dat$meta$state,
            "double *" = dat$meta$result,
            "size_t" = "n_out",
            "double *" = dat$meta$output,
            "void *" = dat$meta$internal)
  body <- sprintf_safe("%s((%s*)%s, %s, %s, %s, %s);",
                       dat$meta$c$rhs, dat$meta$c$internal_t,
                       dat$meta$internal, dat$meta$time, dat$meta$state,
                       dat$meta$result, dat$meta$output)
  c_function("void", dat$meta$c$rhs_dde, args, body)
}


generate_c_compiled_initmod_desolve <- function(dat) {
  body <- collector()
  body$add("static DL_FUNC get_desolve_gparms = NULL;")
  body$add("if (get_desolve_gparms == NULL) {")
  body$add("  get_desolve_gparms =")
  body$add('    R_GetCCallable("deSolve", "get_deSolve_gparms");')
  body$add("}")
  body$add("%s = %s(get_desolve_gparms(), 1);",
           dat$meta$c$internal_ds, dat$meta$c$get_internal)

  args <- c("void(* odeparms)" = "(int *, double *)")
  global <- sprintf_safe("static %s *%s;",
                         dat$meta$c$internal_t, dat$meta$c$internal_ds)
  ret <- c_function("void", dat$meta$c$initmod_desolve, args, body$get())
  ret$definition <- c(global, ret$definition)
  ret
}


generate_c_compiled_contents <- function(dat, rewrite) {
  n_arrays_allocated <- 0L
  extract <- function(x, i, body) {
    if (x$storage_type %in% c("ring_buffer", "interpolate_data")) {
      ## nothing for now at least - later we'll return something more
      return()
    }
    info <- c_type_info(x$storage_type)
    if (x$rank == 0L) {
      body$add("SET_VECTOR_ELT(contents, %d, %s(%s->%s));",
               i, info$scalar_allocate, dat$meta$internal, x$name)
    } else {
      body$add("SEXP %s = PROTECT(allocVector(%s, %s));",
               x$name, info$sexp_name, rewrite(x$dimnames$length))
      n_arrays_allocated <<- n_arrays_allocated + 1L
      body$add("memcpy(%s(%s), %s, %s * sizeof(%s));",
               info$sexp_access, x$name, rewrite(x$name),
               rewrite(x$dimnames$length), info$c_name)
      if (x$rank > 1L) {
        dim <- paste(vcapply(x$dimnames$dim, rewrite), collapse = ", ")
        body$add("odin_set_dim(%s, %d, %s);", x$name, x$rank, dim)
      }
      body$add("SET_VECTOR_ELT(contents, %d, %s);",
               i, x$name)
    }
  }

  i <- vcapply(dat$data$elements, "[[", "location") == "internal"
  contents <- dat$data$elements[i]

  body <- collector()
  body$add("%s *%s = %s(%s, 1);",
          dat$meta$c$internal_t, dat$meta$internal,
          dat$meta$c$get_internal, dat$meta$c$ptr)
  body$add("SEXP contents = PROTECT(allocVector(VECSXP, %d));",
           length(contents))
  for (i in seq_along(contents)) {
    extract(contents[[i]], i - 1, body)
  }
  body$add("SEXP nms = PROTECT(allocVector(STRSXP, %d));", length(contents))
  body$add('SET_STRING_ELT(nms, %d, mkChar("%s"));',
          seq_along(contents) - 1L, names(contents))
  body$add("setAttrib(contents, R_NamesSymbol, nms);")
  body$add("UNPROTECT(%d);", 2 + n_arrays_allocated)
  body$add("return contents;")

  args <- c(SEXP = dat$meta$c$ptr)
  c_function("SEXP", dat$meta$c$contents, args, body$get())
}


generate_c_compiled_set_user <- function(eqs, dat) {
  body <- collector()
  if (dat$features$has_user) {
    body$add("%s *%s = %s(%s, 1);",
             dat$meta$c$internal_t, dat$meta$internal,
             dat$meta$c$get_internal, dat$meta$c$ptr)
    body$add(c_flatten_eqs(eqs[dat$components$user$equations]), literal = TRUE)
  }
  body$add("return R_NilValue;")
  args <- c(SEXP = dat$meta$c$ptr, SEXP = dat$meta$user)
  c_function("SEXP", dat$meta$c$set_user, args, body$get())
}


generate_c_compiled_set_initial <- function(dat, rewrite) {
  if (!dat$features$has_delay) {
    return(NULL)
  }

  set_initial1 <- function(x) {
    rhs <- c_extract_variable(x, dat$data$elements, dat$meta$state, rewrite)
    sprintf_safe("%s = %s;", rewrite(x$initial), rhs)
  }

  ## TODO: see generate_c_compiled_initial_conditions for more that
  ## could be harmonised here
  time_ptr <- sprintf("%s_ptr", dat$meta$time)
  state_ptr <- sprintf("%s_ptr", dat$meta$state)
  use_dde_ptr <- sprintf("%s_ptr", dat$meta$c$use_dde)

  ptr <- dat$meta$c$ptr
  internal <- dat$meta$internal
  internal_t <- dat$meta$c$internal_t

  set_initial_variables <-
    c_flatten_eqs(lapply(dat$data$variable$contents, set_initial1))

  args <- list(SEXP = ptr, SEXP = time_ptr, SEXP = state_ptr)
  if (!dat$features$discrete) {
    args <- c(args, SEXP = use_dde_ptr)
  }

  body <- collector()
  body$add("%s *%s = %s(%s, 1);",
           internal_t, internal, dat$meta$c$get_internal, ptr)
  body$add("const double %s = REAL(%s)[0];", dat$meta$time, time_ptr)
  body$add("%s = %s;", rewrite(dat$meta$initial_time), dat$meta$time)
  if (!dat$features$discrete) {
    body$add("%s = INTEGER(%s)[0];", rewrite(dat$meta$c$use_dde), use_dde_ptr)
  }
  body$add("if (%s != R_NilValue) {", state_ptr)
  body$add("  double * %s = REAL(%s);", dat$meta$state, state_ptr)
  body$add(paste0("  ", set_initial_variables))
  body$add("}")
  body$add("return R_NilValue;")

  c_function("SEXP", dat$meta$c$set_initial, args, body$get())
}


generate_c_compiled_initial_conditions <- function(dat, rewrite) {
  set_initial <- function(el) {
    data_info <- dat$data$elements[[el$name]]
    lhs <- c_variable_reference(el, data_info, dat$meta$state, rewrite)
    if (data_info$rank == 0L) {
      sprintf("%s = %s->%s;", lhs, dat$meta$internal, el$initial)
    } else {
      sprintf_safe(
        "memcpy(%s, %s, %s * sizeof(double));",
        lhs, rewrite(el$initial), rewrite(data_info$dimnames$length))
    }
  }

  if (length(dat$components$initial$equations)) {
    subs <- lapply(dat$data$variable$contents, function(x) rewrite(x$initial))
    eqs_initial <- dat$equations[dat$components$initial$equations]
    eqs_initial <- lapply(ir_substitute(eqs_initial, subs),
                          generate_c_equation, dat, rewrite)
    if (dat$features$initial_time_dependent && dat$features$has_stochastic) {
      eqs_initial <- c("GetRNGstate();", eqs_initial, "PutRNGstate();")
    }
  } else {
    eqs_initial <- NULL
  }

  time_ptr <- sprintf("%s_ptr", dat$meta$time)
  state_r <- sprintf("r_%s", dat$meta$state)
  initial <- c_flatten_eqs(lapply(dat$data$variable$contents, set_initial))

  body <- collector()
  if (dat$features$initial_time_dependent) {
    if (dat$features$discrete) {
      type <- "int"
      unpack <- "INTEGER"
    } else {
      type <- "double"
      unpack <- "REAL"
    }
    body$add("%s %s = %s(%s)[0];", type, dat$meta$time, unpack, time_ptr)
  }
  body$add("%s *%s = %s(%s, 1);",
          dat$meta$c$internal_t, dat$meta$internal,
          dat$meta$c$get_internal, dat$meta$c$ptr)
  body$add(c_flatten_eqs(eqs_initial), literal = TRUE)
  body$add("SEXP %s = PROTECT(allocVector(REALSXP, %s));",
          state_r, rewrite(dat$data$variable$length))
  body$add("double * %s = REAL(%s);", dat$meta$state, state_r)
  body$add(initial, literal = TRUE)
  body$add("UNPROTECT(1);")
  body$add("return %s;", state_r)

  args <- c(SEXP = dat$meta$c$ptr, SEXP = time_ptr)
  c_function("SEXP", dat$meta$c$initial_conditions, args, body$get())
}


generate_c_compiled_metadata <- function(dat, rewrite) {
  variables <- names(dat$data$variable$contents)
  output <- names(dat$data$output$contents)

  ## Used for both variable and output:
  len <- function(i, v, target) {
    d <- dat$data$elements[[v]]
    if (d$rank == 0L) {
      sprintf_safe("SET_VECTOR_ELT(%s, %d, R_NilValue);", target, i - 1L)
    } else if (d$rank == 1L) {
      sprintf_safe("SET_VECTOR_ELT(%s, %d, ScalarInteger(%s));",
                   target, i - 1L, rewrite(d$dimnames$length))
    } else {
      c(sprintf_safe("SET_VECTOR_ELT(%s, %d, allocVector(INTSXP, %d));",
                     target, i - 1L, d$rank),
        sprintf_safe("int * %s = INTEGER(VECTOR_ELT(%s, %d));",
                     d$dimnames$length, target, i - 1L),
        sprintf_safe("%s[%d] = %s;",
                     d$dimnames$length, seq_len(d$rank) - 1L,
                     vcapply(d$dimnames$dim, rewrite, USE.NAMES = FALSE)))
    }
  }

  len_block <- function(data, target, idx) {
    len <- Map(len, seq_along(data), data, sprintf("%s_length", target))
    body <- collector()
    body$add("SEXP %s_length = PROTECT(allocVector(VECSXP, %d));",
             target, length(data))
    body$add("SEXP %s_names = PROTECT(allocVector(STRSXP, %d));",
             target, length(data))
    body$add("setAttrib(%s_length, R_NamesSymbol, %s_names);",
             target, target)
    body$add(c_flatten_eqs(len))
    body$add('SET_STRING_ELT(%s_names, %d, mkChar("%s"));',
             target, seq_along(data) - 1L, data)
    body$add("SET_VECTOR_ELT(ret, %d, %s_length);", idx, target)
    body$add("UNPROTECT(2);")
    body$get()
  }

  body <- collector()
  body$add("%s *%s = %s(%s, 1);",
          dat$meta$c$internal_t, dat$meta$internal,
          dat$meta$c$get_internal, dat$meta$c$ptr)
  body$add("SEXP ret = PROTECT(allocVector(VECSXP, 4));")
  body$add("SEXP nms = PROTECT(allocVector(STRSXP, 4));")
  body$add('SET_STRING_ELT(nms, 0, mkChar("variable_order"));')
  body$add('SET_STRING_ELT(nms, 1, mkChar("output_order"));')
  body$add('SET_STRING_ELT(nms, 2, mkChar("n_out"));')
  body$add('SET_STRING_ELT(nms, 3, mkChar("interpolate_t"));')
  body$add("setAttrib(ret, R_NamesSymbol, nms);");

  body$add(len_block(variables, "variable", 0))

  if (dat$features$has_output) {
    body$add(len_block(output, "output", 1))
    body$add("SET_VECTOR_ELT(ret, 2, ScalarInteger(%s));",
             rewrite(dat$data$output$length))
  } else {
    body$add("SET_VECTOR_ELT(ret, 1, R_NilValue);")
    body$add("SET_VECTOR_ELT(ret, 2, ScalarInteger(0));")
  }

  if (dat$features$has_interpolate) {
    ## TODO: we should generate out the the critical bits but that's
    ## another problem.  See the comments in
    ## support_check_interpolate_t
    args_min <- c_fold_call("fmax", vcapply(dat$interpolate$min, function(x)
      sprintf("%s[0]", rewrite(x))))
    if (length(dat$interpolate$max) == 0) {
      args_max <- "R_PosInf"
    } else {
      args_max <- c_fold_call("fmin", vcapply(dat$interpolate$max, function(x)
        sprintf("%s[%s - 1]", rewrite(x),
                rewrite(dat$data$elements[[x]]$dimnames$length))))
    }

    body$add("SEXP interpolate_t = PROTECT(allocVector(VECSXP, 3));")
    body$add("SEXP interpolate_t_nms = PROTECT(allocVector(STRSXP, 3));")
    body$add("setAttrib(interpolate_t, R_NamesSymbol, interpolate_t_nms);");
    body$add("SET_VECTOR_ELT(interpolate_t, 0, ScalarReal(%s));", args_min)
    body$add("SET_VECTOR_ELT(interpolate_t, 1, ScalarReal(%s));", args_max)
    body$add('SET_STRING_ELT(interpolate_t_nms, 0, mkChar("min"));')
    body$add('SET_STRING_ELT(interpolate_t_nms, 1, mkChar("max"));')
    body$add("SET_VECTOR_ELT(ret, 3, interpolate_t);")
    body$add("UNPROTECT(2);")
  }

  body$add("UNPROTECT(2);")
  body$add("return ret;")

  args <- c(SEXP = dat$meta$c$ptr)
  c_function("SEXP", dat$meta$c$metadata, args, body$get())
}


generate_c_compiled_create_user <- function(name, dat, rewrite) {
  data_info <- dat$data$elements[[name]]
  eq_info <- dat$equations[[name]]
  if (!is.null(eq_info$user$default)) {
    rhs <- rewrite(eq_info$user$default)
  } else if (data_info$rank > 0L) {
    rhs <- "NULL"
  } else if (data_info$storage_type == "double") {
    rhs <- "NA_REAL"
  } else if (data_info$storage_type == "int") {
    rhs <- "NA_INTEGER"
  }
  sprintf_safe("%s = %s;", rewrite(data_info$name), rhs)
}


generate_c_compiled_library <- function(dat, is_package) {
  lib <- read_user_c(system.file("library.c", package = "odin"))
  v <- character(0)
  if (dat$features$has_user) {
    v <- c(v, "user_get_scalar_double", "user_get_scalar_int",
           "user_check_values_double", "user_check_values_int",
           "user_check_values", "user_list_element")
  }
  if (dat$features$has_array) {
    if (any(viapply(dat$data$elements, "[[", "rank") > 1)) {
      v <- c(v, "odin_set_dim")
    }
  }
  if (dat$features$has_user && dat$features$has_array) {
    d <- dat$data$elements
    user_arrays <- any(vlapply(dat$equations, function(x)
      !is.null(x$user) && d[[x$name]]$rank > 0))
    if (user_arrays) {
      v <- c(v, "user_get_array_dim",
             "user_get_array", "user_get_array_check",
             "user_get_array_check_rank", "user_list_element")
    }
  }
  if (dat$features$has_delay && !dat$features$discrete) {
    v <- c(v, "lagvalue", "lagvalue_dde", "lagvalue_ds")
  }
  if (dat$features$has_interpolate) {
    v <- c(v, "interpolate_check_y")
  }

  used <- unique(unlist(lapply(dat$equations, function(x)
    x$depends$functions), FALSE, FALSE))
  if ("%%" %in% used) {
    v <- c(v, "fmodr")
  }
  if ("%/%" %in% used) {
    v <- c(v, "fintdiv")
  }
  if ("sum" %in% used) {
    v <- c(v, "odin_sum1")
  }

  if ("odin_sum" %in% used) {
    ## We can do better than this but it requires going through a lot
    ## of code (especially with delays) and this will always be close
    ## enough with lowish cost.
    ranks <- sort(unique(viapply(dat$data$elements, "[[", "rank")))
    ranks <- ranks[ranks > 0]

    v <- c(v, sprintf("odin_sum%d", ranks[ranks > 0]))

    if (any(ranks > 1L)) {
      extra <- lapply(ranks[ranks > 1], generate_c_support_sum)
      nms <- vcapply(extra, "[[", "name")
      extra_lib <- list(
        declarations = set_names(vcapply(extra, "[[", "declaration"), nms),
        definitions = set_names(vcapply(extra, function(x)
          paste0(x$definition, "\n", collapse = "")), nms))
      lib <- join_library(list(lib, extra_lib))
    }
  }

  v <- unique(v)
  msg <- setdiff(v, names(lib$declarations))
  if (length(msg) > 0L) {
    stop("Missing library functions [odin bug]") # nocov
  }

  if (is_package) {
    list(used = v, lib = lib)
  } else {
    list(declaration = unname(lib$declarations[v]),
         definition = c_flatten_eqs(strsplit(lib$definitions[v], "\n")))
  }
}


generate_c_compiled_include <- function(dat, is_package) {
  include <- dat$config$include
  if (is_package) {
    include
  } else {
    list(declaration = c_flatten_eqs(lapply(include, "[[", "declaration")),
         definition = c_flatten_eqs(lapply(include, "[[", "definition")))
  }
}
