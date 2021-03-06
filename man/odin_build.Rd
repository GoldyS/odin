% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/odin_build.R
\name{odin_build}
\alias{odin_build}
\title{Build an odin model generator from its IR}
\usage{
odin_build(x, options = NULL)
}
\arguments{
\item{x}{An odin ir (json) object or output from
\code{\link{odin_validate}}.}

\item{options}{Options to pass to the build stage (see
\code{\link{odin_options}}}
}
\description{
Build an odin model generator from its intermediate
representation, as generated by \code{\link{odin_parse}}.  This
function is for advanced use.
}
\details{
In applications that want to inspect the intermediate
representation rather before compiling, rather than directly using
\code{\link{odin}}, use either \code{\link{odin_parse}} or
\code{\link{odin_validate}} and then pass the result to
\code{odin_build}.
}
