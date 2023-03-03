## Defines most of the types used throughout the chalk code base,
## except the config-file related types, which are auto-generated by
## con4m, and live in configs/con4mconfig.nim (and are included
## through config.nim)
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

# At compile time, this will generate c4autoconf if the file doesn't exist,
# or if the spec file has a newer timestamp.  We do this before importing it.
static:
  discard staticexec("if test \\! c4autoconf.nim -nt configs/chalk.c42spec; " &
                     "then con4m spec configs/chalk.c42spec --language=nim " &
                     "--output-file=c4autoconf.nim; fi")

import c4autoconf, streams, tables, nimutils

type
  ChalkDict* = TableRef[string, Box]
  ## The chalk info for a single artifact.
  ChalkObj* = ref object
    fullpath*:    string      ## The path to the artifact.
    newFields*:   ChalkDict   ## What we're adding during insertion.
    extract*:     ChalkDict
    embeds*:      seq[ChalkObj]
    stream*:      FileStream  # Plugins by default use file streams; we
    startOffset*: int         # keep state fields for that to bridge between
    endOffset*:   int         # extract and write. If the plugin needs to do
                              # something else, use the cache field
                              # below, instead.
    ## PS: are we using this valid field now???
    err*:         seq[string] ## runtime logs for chalking are filtered
                              ## based on the "chalk log level". They
                              ## end up here, until the end of chalking
                              ## where, they get added to ERR_INFO, if
                              ## any.  To disable, simply set the chalk
                              ## log level to 'none'.
    cache*:       RootRef     ## Generic pointer a plugin can use to
                              ## store any state it might want to stash.

  Plugin* = ref object of RootObj
    name*:       string
    configInfo*: PluginSpec

  Codec* = ref object of Plugin
    chalks*:     seq[ChalkObj]
    magic*:      string
    searchPath*: seq[string]

proc isMarked*(chalk: ChalkObj): bool {.inline.} = return chalk.extract != nil
