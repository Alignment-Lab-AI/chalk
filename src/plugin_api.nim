## This provides the base methods for plugins / codecs.
## Additionally, it provides utility functions to be used
## by plugins, as well as code for registering plugins.
##
## All of the data collection these plugins do is orchestrated in
## collect.nim
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import glob, posix, nimSHA2, config, chalkjson, util

const  ePureVirtual = "Method is not defined; it must be overridden"

proc findFirstValidChalkMark*(s:            string,
                              artifactPath: string,
                              quiet                = false):
                                (int, int, ChalkDict) =
  # We're generally going to use this when looking for existing chalk
  # marks in text files.
  #
  # The pattern will generally be, look once when scanning, and if we
  # do find it, and then are potentially replacing it, we will rescan
  # instead of trusting the cached location, just to avoid any risk of
  # the underlying file having changed out from underneath us.  Still,
  # generally the file won't have changed, so if there's any logging
  # that happens, it should only happen on the first scan, rather than
  # being duplicated.
  var
    asStream        = newStringStream(s)
    curIx           = -1

  while true:
    # The previous loop will have curIx pointing to the start of a
    # mark.  If we don't advance this by one somewhere, we'd keep
    # getting the same mark back (forever).
    curIx = s.find(magicUTF8, curIx + 1)

    if curIx == -1:
      return (-1, -1, nil)
    asStream.setPosition(curIx)
    if not asStream.findJsonStart():
      if quiet:
        continue
      error(artifactPath & ": At byte " & $(curIx) &
            ", chalk mark is present, but was not embedded in valid " &
            "chalk JSON. Searching for another mark.")
    try:
      let
        # The stream pointer is backed up from curIx, but we don't
        # want to change curIx in case we need to search for the next
        # mark.  If this mark *is* valid, then we actually will want
        # to return this position, which represents the true start of
        # the mark, being the start of the JSON.  That's what we're
        # expected to be returning, not the location of the magic value.
        curPos   = asStream.getPosition()
        contents = asStream.extractOneChalkJson(artifactPath)
      let endPos = asStream.getPosition()
      asStream.close()
      return (curPos, endPos, contents)
    except:
      if quiet:
        continue
      error(artifactPath & ": Invalid JSON: " & getCurrentExceptionMsg())
      dumpExOnDebug()

proc findFirstValidChalkMark*(s:            Stream,
                              artifactPath: string,
                              quiet                = false):
                                (int, int, ChalkDict) =
  s.setPosition(0)
  return s.readAll().findFirstValidChalkMark(artifactPath, quiet)

const basePrefixLen = 2 # size of the prefix w/o the comment char(s)

proc getUnmarkedScriptContent*(current: string,
                               chalk:   ChalkObj,
                               quiet            = false,
                               commentIndicator = "#"): (string, ChalkDict) =
  ## This function is intended to be used from plugins for artifacts
  ## where we have text files that are marked by adding one-line
  ## comments.
  ##
  ## Specifically, this function gets used in two scenarios:
  ##
  ## a) When we first scan the file.  In that scenario, we need the
  ## hash of the as-unmarked artifact and the extracted info, if any.
  ##
  ## b) When we remove a chalk mark, and want to write out the new
  ## content.
  ##
  ## To support those use cases, we return the contents of the file
  ## (it can then be either hashed or written), along with the dict
  ## extracted from Json, which the delete operation will just be
  ## ignoring.
  ##
  ## Note that to avoid re-writing unchanged files, this function's
  ## string return value is set to "" if the unmarked output is the
  ## same as the input.  In such a case, the ChalkDict will also be
  ## nil.
  ##
  ## Generally, we expect this to get called 2x on a delete operation.
  ## We *could* cache contents, or a location in the file stream, but
  ## there are some cases where we might want to NOT cache and might
  ## possibly have underlying file changes (specifically, ZIP files
  ## and any other nested content will have their objects stick around
  ## until the outmost object is done processing).
  ##
  ## The protocol here for removing chalk marks that aren't on a
  ## comment boundary exactly as we would have added them is that we
  ## replace the mark's JSON with: { "MAGIC" : "dadfedabbadabbed" }
  ##
  ## We call this the "chalk placeholder".
  ##
  ## If the user hand-added it before we replaced the mark, we might not
  ## get the spacing quite the same as what the user had before hand,
  ## because we make no move to perserve that.
  ##
  ## To ensure consistency of the hashes we use to generate CHALK IDs,
  ## when using the placeholder, the hash we use for the purposes of
  ## chalking should be based on the placeholder with spacing as above,
  ## instead of the user's spacing.  That means, the hash we use as the
  ## 'pre-chalk' hash might be different than the on-file-system hash,
  ## were you to run sha256 on the as-is-file.
  ##
  ## Seems like a decent enough trade-off, and we have already made a
  ## similar one in ZIP files.

  var (cs, r, extract) = current.findFirstValidChalkMark(chalk.fsRef, quiet)

  if cs == -1:
    # There was no mark to find, so the input is the output, which we
    # indicate with "" to help prevent unnecessary I/O.
    return ("", nil)

    # If we are on a comment line by ourselves, in the format that we
    # would have written, then we will delete the entire line.
    # Otherwise, we replace the mark with the constant `emptyMark`.
    #
    # For us to delete the comment line, we require the following
    # conditions to be true:
    #
    # 1. Before the mark, we must see EXACTLY a newline, the comment
    #    sequence (usually just #) and then a single space.
    #
    # 2. After the mark ends, we must see EITHER a newline or EOF.
    #
    # In any other case, we treat the mark location as above where we
    # insert `emptyMark` instead of removing the whole line.
    #
    # We do it this way because, if we don't see `emptyMark` in an
    # unmarked file, this is the way we will add the mark, full stop.
    # If there's a marked file with extra spaces on the comment line,
    # either it was tampered with after marking (which the unchalked
    # hash would then be able to determine), *or* the user wanted the
    # comment line to look the way it does, and indicated such by
    # adding `emptyMark`.
    #
    # Below, we call the string that is either emptyMark or ""
    # 'remnant' because I can't come up with a better name.
  let
    ourEnding    = "\n" & commentIndicator & " "
    preMark      = current[0 ..< cs]
    addEmptyMark = if not preMark.endsWith(ourEnding):            true
                   elif r != len(current) and current[r] != '\n': true
                   else:                                         false
    remnant      = if addEmptyMark: emptyMark else: ""

  # If we're not adding empty mark, we need to excise the prefix,
  # which includes the newline, the comment marker and a space.
  if not addEmptyMark:
    cs -= (basePrefixLen + len(commentIndicator))

  # If r is positioned at the end of the string we don't want to get
  # an array indexing error.
  if r == len(current):
    return (current[0 ..< cs] & remnant, extract)
  else:
    return (current[0 ..< cs] & remnant & current[r .. ^1], extract)

proc getNewScriptContents*(fileContents: string,
                           chalk:        ChalkObj,
                           markContents: string,
                           commentIndicator       = "#"): string =
  ## This helper function can be used for script plugins to calculate
  ## their new output.  It assumes you've either cached the input
  ## (which isn't a great idea if chalking large zip files or other
  ## artifacts that lead to recursive chalking) or, more likely,
  ## re-read the contents when it came time to write.
  ##
  ## We look again for a valid chalk mark (if we saved the state we
  ## could jump straight there, of coure).  If there's a mark found,
  ## we replace it.
  ##
  ## If there's no mark found, we shove it at the end of the output,
  ## with our comment prelude added beforehand.
  var (cs, r, ignore) = fileContents.findFirstValidChalkMark(chalk.fsRef,
                                                             true)

  if cs == -1:
    # If the file had a trailing newline, we preserve it, adding a new
    # newline at the end, to indicate that there was a newline before
    # the mark when the file was unmarked.
    #
    # When the file ended w/o a newline, we need to add a newline
    # before the mark (the comment should start a new line!).
    # But in that case, we *don't* add the newline to the end, indicating
    # that there wasn't one there before.

    if len(fileContents) != 0 and fileContents[^1] == '\n':
      return fileContents & commentIndicator & " " & markContents & "\n"
    else:
      return fileContents & "\n" & commentIndicator & " " & markContents

  # At this point, we don't care about the newline situation; we are
  # just going to replace an *existing* chalk mark (which may be the
  # placeholder mark referenced above).
  #
  # The only 'gotcha' is that r *might* be pointing at EOF and not
  # safe to read.
  if r == len(fileContents):
    return fileContents[0 ..< cs] & markContents
  else:
    return fileContents[0 ..< cs] & markContents & fileContents[r .. ^1]

proc scriptLoadMark*(codec:  Codec,
                     stream: FileStream,
                     path:   string,
                     comment = "#"): Option[ChalkObj] =
  ## Instead of having a big, fragile inheritance hierarchy, we
  ## provide this helper function that we expect will work for MOST
  ## codecs for scripting languages and similar, after checking
  ## conditions to figure out if you want to handle the thing.  But
  ## you don't have to use it, if it's not appropriate!

  stream.setPosition(0)
  let
    contents       = stream.readAll()
    chalk          = newChalk(name         = path,
                              fsRef        = path,
                              codec        = codec,
                              stream       = stream,
                              resourceType = {ResourceFile})
    (toHash, dict) = contents.getUnmarkedScriptContent(chalk, false, comment)

  result = some(chalk)

  stream.setPosition(0)

  if toHash == "" and dict == nil:
    chalk.cachedPreHash = hashFmt($(contents.computeSHA256()))
  else:
    chalk.cachedPreHash = hashFmt($(toHash.computeSHA256()))
  if dict != nil and len(dict) != 1:
    # When len(dict) == 1, that's the 'placeholder chalk mark', which
    # we consider to be not a chalk mark for script files.
    chalk.marked  = true
    chalk.extract = dict


proc scriptHandleWrite*(chalk:   ChalkObj,
                        encoded: Option[string],
                        comment = "#") =
  ## Same as above, default option for a handleWrite implementation
  ## that should work for most scripting languages.
  discard chalk.acquireFileStream()
  chalk.stream.setPosition(0)
  let contents = chalk.stream.readAll()
  chalk.closeFileStream()

  if encoded.isNone():
    if not chalk.marked:  # Unmarked, so nothing to do.
      return
    let (toWrite, ignore) = contents.getUnmarkedScriptContent(chalk, true,
                                                              comment)
    if not chalk.replaceFileContents(toWrite):
      chalk.opFailed = true
      return

    chalk.cachedHash = chalk.cachedPreHash
  else:
    let toWrite = contents.getNewScriptContents(chalk, encoded.get(), comment)
    if not chalk.replaceFileContents(toWrite):
      chalk.opFailed = true
    else:
      chalk.cachedHash = hashFmt($(toWrite.computeSHA256()))

proc loadChalkFromFStream*(codec:  Codec,
                           stream: FileStream,
                           loc:    string): ChalkObj =
  ## A helper function for codecs that use file streams to load
  ## an existing chalk mark.  The stream must be positioned over
  ## the start of the Chalk magic before you call this function.

  result = newChalk(name         = loc,
                    fsRef        = loc,
                    codec        = codec,
                    stream       = stream,
                    resourceType = {ResourceFile})

  trace(result.name & ": chalk mark magic @ " & $(stream.getPosition()))

  if not stream.findJsonStart():
    error(loc & ": Invalid JSON: found magic but no JSON start")
    return

  try:
    result.startOffset   = result.stream.getPosition()
    result.extract       = result.stream.extractOneChalkJson(result.name)
    result.endOffset     = result.stream.getPosition()
  except:
    error(loc & ": Invalid JSON: " & getCurrentExceptionMsg())
    dumpExOnDebug()

# These are the base methods for all plugins.  They don't have to
# implement them; we only try to call these methods if the config for
# the plugin specifies that it returns keys from one of these
# particular calls.
method getChalkTimeArtifactInfo*(self: Plugin, chalk: ChalkObj):
       ChalkDict {.base.} =
  raise newException(Exception, "In plugin: " & self.name & ": " & ePureVirtual)
method getRunTimeArtifactInfo*(self: Plugin, chalk: ChalkObj, ins: bool):
       ChalkDict {.base.} =
  raise newException(Exception, "In plugin: " & self.name & ": " & ePureVirtual)
method getChalkTimeHostInfo*(self: Plugin): ChalkDict {.base.} =
  raise newException(Exception, "In plugin: " & self.name & ": " & ePureVirtual)
method getRunTimeHostInfo*(self: Plugin, objs: seq[ChalkObj]):
       ChalkDict {.base.} =
  raise newException(Exception, "In plugin: " & self.name & ": " & ePureVirtual)

# Base methods for codecs, including default implementations for things
# using file streams.

method usesFStream*(self: Codec): bool {.base.} = true

method scan*(self:   Codec,
             stream: FileStream,
             loc:    string): Option[ChalkObj] {.base.} =
  raise newException(Exception, "In plugin: " & self.name & ": " & ePureVirtual)

method keepScanningOnSuccess*(self: Codec): bool {.base.} = true

proc scanLocation(self: Codec, loc: string, state: ArtifactIterationInfo):
                 Option[ChalkObj] =
  # Helper function for scanArtifactLocations below.
  var stream = newFileStream(loc, fmRead)
  if stream == nil:
    error(loc & ": could not open file.")
    return
  else:
    trace(loc & ": File stream opened")
  result = self.scan(stream, loc)
  if result.isNone():
    stream.close()
    return
  state.fileExclusions.add(loc)
  var chalk = result.get()

  if bumpFdCount():
    chalk.stream = stream
  else:
    stream.close()
    trace(loc & ": File stream closed")

proc mustIgnore(path: string, globs: seq[glob.Glob]): bool {.inline.} =
  for item in globs:
    if path.matches(item): return true
  return false

proc scanArtifactLocations*(self: Codec, state: ArtifactIterationInfo):
                        seq[ChalkObj] =
  # This will call scan() with a file stream, and you pass back a
  # Chalk object if chalk is there.
  result = @[]

  for path in state.filePaths:
    trace("Codec " & self.name & ": beginning scan of " & path)
    var info: FileInfo
    try:
      info = getFileInfo(path)
    except:
      continue

    if info.kind == pcFile:
      if path in state.fileExclusions: continue
      if path.mustIgnore(state.skips): continue
      trace(path & ": scanning file")
      let opt = self.scanLocation(path, state)
      if opt.isSome():
        result.add(opt.get())
        opt.get().yieldFileStream()
    elif info.kind == pcLinkToFile:
      discard # We ignore symbolic links for now.
    elif state.recurse:
      dirWalk(true):
        if item in state.fileExclusions:     continue
        if item.mustIgnore(state.skips):     continue
        if getFileInfo(item).kind != pcFile: continue
        trace(item & ": scanning file")
        let opt = self.scanLocation(item, state)
        if opt.isSome():
          result.add(opt.get())
          opt.get().yieldFileStream()
    else:
      dirWalk(false):
        if item in state.fileExclusions:     continue
        if item.mustIgnore(state.skips):     continue
        if getFileInfo(item).kind != pcFile: continue
        trace("Non-recursive dir walk examining: " & item)
        let opt = self.scanLocation(item, state)
        if opt.isSome():
          result.add(opt.get())
          opt.get().yieldFileStream()

proc simpleHash(self: Codec, chalk: ChalkObj): Option[string] =
  var s: Stream

  if self.usesFStream():
    s = chalk.acquireFileStream().getOrElse(nil)

  if s == nil:
    return none(string)

  s.setPosition(0)
  let txt = $(s.readAll().computeSHA256())
  chalk.yieldFileStream()

  result = some(hashFmt(txt))

method getUnchalkedHash*(self: Codec, obj: ChalkObj): Option[string] {.base.} =
  ## This is called in computing the CHALK_ID. If the artifact already
  ## hash chalk marks they need to be removed.
  ##
  ## The default assumes that this was cached during scan, and if the
  ## hash isn't cached, it doesn't exist.

  if obj.cachedPreHash != "": return some(obj.cachedPreHash)
  return none(string)

method getEndingHash*(self: Codec, chalk: ChalkObj): Option[string] {.base.} =
  ## This is called after chalking is done.  We check the cache first.
  if chalk.cachedHash != "": return some(chalk.cachedHash)
  return simpleHash(self, chalk)

method getChalkId*(self: Codec, chalk: ChalkObj): string {.base.} =
  let hashOpt = self.getUnchalkedHash(chalk)
  if not hashOpt.isNone():
    return hashOpt.get().idFormat()
  else:
    warn(chalk.name & ": In plugin '" & self.name &
      "', no hash for chalk ID; using a random value.")
    var
      b      = secureRand[array[32, char]]()
      preRes = newStringOfCap(32)
    for ch in b: preRes.add(ch)
    return preRes.idFormat()

method getChalkTimeArtifactInfo*(self: Codec, chalk: ChalkObj): ChalkDict =
  discard

method getRunTimeArtifactInfo*(self: Codec, chalk: ChalkObj, ins: bool):
       ChalkDict =
  result = ChalkDict()

  let postHashOpt = self.getEndingHash(chalk)

  if postHashOpt.isSome():
    result["_CURRENT_HASH"] = pack(postHashOpt.get())

## Codecs override this if they're for a binary format and can self-inject.
method getNativeObjPlatforms*(s: Codec): seq[string] {.base.} = @[]

method handleWrite*(s:       Codec,
                    chalk:   ChalkObj,
                    enc:     Option[string]) {.base.} =
  var pre, post: string
  chalk.stream.setPosition(0)
  pre = chalk.stream.readStr(chalk.startOffset)
  if chalk.endOffset > chalk.startOffset:
    chalk.stream.setPosition(chalk.endOffset)
    post = chalk.stream.readAll()
  chalk.closeFileStream()
  let contents = pre & enc.getOrElse("") & post
  if not chalk.replaceFileContents(contents):
    chalk.opFailed = true

# This is docker specific stuff that shouldn't be here, but am dealing
# with some cyclic dependencies.
const
  hostDefault = "host_report_other_base"
  artDefault  = "artifact_report_extract_base"

proc profileToString(name: string): string =
  if name in ["", hostDefault, artDefault]: return ""

  result      = "profile " & name & " {\n"
  let profile = chalkConfig.profiles[name]

  for k, obj in profile.keys:
    let
      scope  = obj.getAttrScope()
      report = get[bool](scope, "report")
      order  = getOpt[int](scope, "order")

    result &= "  key." & k & ".report = " & $(report) & "\n"
    if order.isSome():
      result &= "  key." & k & ".order = " & $(order.get()) & "\n"

  result &= "}\n\n"

proc sinkConfToString(name: string): string =
  result     = "sink_config " & name & " {\n  filters: ["
  var frepr  = seq[string](@[])
  let
    config   = chalkConfig.sinkConfs[name]
    scope    = config.getAttrScope()

  for item in config.filters: frepr.add("\"" & item & "\"")

  result &= frepr.join(", ") & "]\n"
  result &= "  sink: \"" & config.sink & "\"\n"

  # copy out the config-specific variables.
  for k, v in scope.contents:
    if k in ["enabled", "filters", "loaded", "sink"]: continue
    if v.isA(AttrScope): continue
    let val = getOpt[string](scope, k).getOrElse("")
    result &= "  " & k & ": \"" & val & "\"\n"

  result &= "}\n\n"