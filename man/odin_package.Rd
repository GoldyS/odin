% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/odin_package.R
\name{odin_package}
\alias{odin_package}
\title{Create odin model in a package}
\usage{
odin_package(path_package)
}
\arguments{
\item{path_package}{Path to the package root (the directory that
contains \code{DESCRIPTION})}
}
\description{
Create an odin model within an existing package.
}
\details{
I am resisiting the urge to actually create the package here.
There are better options than I can come up with; for example
\code{devtools::create}, \code{pkgkitten::kitten},
\code{mason::mason}, or creating \code{DESCRIPTION} files using
\code{desc}.  What is required here is that your package:

\itemize{
\item{Lists \code{odin} in \code{Imports:}}
\item{Includes \code{useDynLib{<your package name>}} in
  \code{NAMESPACE} (possibly via a roxygen comment \code{@useDynLib
  <your package name>}}
\item{To avoid a NOTE in \code{R CMD check}, import something from
  \code{odin} in your namespace (e.g., \code{importFrom("odin", "odin")}
  or roxygen \code{@importFrom(odin, odin)}}
}

Point this function at the package root (the directory containing
\code{DESCRIPTION} and it will write out files \code{src/odin.c}
and \code{odin.R}.  These files will be overwritten without
warning by running this again.
}
