##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Conceptually, this is where ALL information about the configuration
## state lives.  A lot of our calls for accessing configuration state
## are auto-generated by this file though, and in c4autoconf.nim).
##
## This module does also handle loading configurations, including
## built-in ones and external ones.
##
## It also captures some environmental bits used by other modules.
## For instance, we collect some information about the build
## environment here.

import std/macros except error
import "."/[config, selfextract, con4mfuncs, plugin_load, util]

# Since these are system keys, we are the only one able to write them,
# and it's easier to do it directly here than in the system plugin.
proc stashFlags(winner: ArgResult) =
  var flagStrs: seq[string] = @[]

  for key, value in winner.stringizeFlags():
    if key == "help":
      passedHelpFlag = true
    if value == "": flagStrs.add("--" & key)
    else:           flagStrs.add("--" & key & "=" & value)

  hostInfo["_OP_CMD_FLAGS"] = pack(flagStrs)

proc installComponentParams*(params: seq[Box]) =
  let runtime = getChalkRuntime()

  for item in params:
    let
      row     = unpack[seq[Box]](item)
      attr    = unpack[bool](row[0])
      url     = unpack[string](row[1])
      sym     = unpack[string](row[2])
      c4mType = toCon4mType(unpack[string](row[3]))
      value   = row[4]
    if attr:
      runtime.setAttributeParamValue(url, sym, value, c4mType)
    else:
      runtime.setVariableParamValue(url, sym, value, c4mType)

proc loadCachedComponents(cache: OrderedTableRef[string, string]) =
  for url, src in cache:
    let component = getChalkRuntime().getComponentReference(url)
    component.cacheComponent(src)
    trace("Loaded cached version of: " & url & ".c4m")

proc getEmbeddedConfig(): string =
  result         = defaultConfig
  let extraction = getSelfExtraction()
  if extraction.isSome():
    let
      selfChalk = extraction.get()
    if selfChalk.extract != nil:
      if selfChalk.extract.contains("$CHALK_CONFIG"):
        trace("Found embedded config file in self-chalk.")
        result = unpack[string](selfChalk.extract["$CHALK_CONFIG"])
      else:
        if selfChalk.marked:
          trace("Found a chalk mark, but it did not contain a config.")
        else:
          trace("No embedded chalk mark.")
        trace("Using the default user config.  See 'chalk dump' to view.")
      # component must be loaded before parameters
      # otherwise loading params initializes the component first (if not present yet)
      # which will attempt to fetch the component from source (e.g. url)
      if selfChalk.extract.contains("$CHALK_COMPONENT_CACHE"):
        let
          componentInfo = selfChalk.extract["$CHALK_COMPONENT_CACHE"]
          unpackedInfo  = unpack[OrderedTableRef[string, string]](componentInfo)
        loadCachedComponents(unpackedInfo)
      if selfChalk.extract.contains("$CHALK_SAVED_COMPONENT_PARAMETERS"):
        let params = selfChalk.extract["$CHALK_SAVED_COMPONENT_PARAMETERS"]
        installComponentParams(unpack[seq[Box]](params))
      else:
        trace("No saved component parameters; skipping install.")
  else:
    trace("Since this binary can't be marked, using the default config.")

proc findOptionalConf(state: ConfigState): Option[string] =
  result = none(string)
  let
    path     = unpack[seq[string]](state.attrLookup("config_path").get())
    filename = unpack[string](state.attrLookup("config_filename").get())
  for dir in path:
    let fullPath = dir.joinPath(filename)
    var fname = ""
    try:
      fname = resolvePath(fullPath)
    except:
      # resolvePath can fail in some cases such as ~ might not resolve
      # if uid does not have home folder
      trace(fullPath & ": Cannot resolve configuration file path.")
      continue
    trace("Looking for config file at: " & fname)
    if fname.fileExists():
      info(fname & ": Found config file")
      try:
        return some(fname)
      except:
        error(fname & ": Could not read configuration file")
        dumpExOnDebug()
        break
    else:
        trace(fname & ": No configuration file found.")

proc loadLocalStructs*(state: ConfigState) =
  chalkConfig = state.attrs.loadChalkConfig()
  if getOpt[bool](chalkConfig, "color").isSome(): setShowColor(get[bool](chalkConfig, "color"))
  setLogLevel(get[string](chalkConfig, "log_level"))
  var configPath: seq[string] = @[]
  for path in get[seq[string]](chalkConfig, "config_path"):
    try:
      configPath.add(path.resolvePath())
    except:
      # resolvePath can fail in some cases such as ~ might not resolve
      # if uid does not have home folder
      # no log as this function is called multiple times
      # and any logs are very verbose
      continue
  doAssert state.attrSet("config_path", pack(configPath)).code == errOk
  var c4errLevel =  if get[bool](chalkConfig, "con4m_pinpoint"): c4vShowLoc else: c4vBasic

  if get[bool](chalkConfig, "chalk_debug"):
    c4errLevel = if c4errLevel == c4vBasic: c4vTrace else: c4vMax

  setCon4mVerbosity(c4errLevel)

proc handleCon4mErrors(err, tb: string): bool =
  if tb != "" and chalkConfig == nil or get[bool](chalkConfig, "chalk_debug"):
     echo formatCompilerError(err, nil, tb, default(InstInfo))
  else:
    error(err)
  return true

proc handleOtherErrors(err, tb: string): bool =
  error(getMyAppPath().splitPath().tail & ": " & err)
  quit(1)

template cmdlineStashTry() =
  if cmdSpec == nil:
    if stack.getOptOptions.len() > 1:
      commandName = "not_supplied"
    elif not resFound:
      res         = getArgResult(stack)
      commandName = res.command
      cmdSpec     = res.parseCtx.finalCmd
      autoHelp    = res.getHelpStr()
      setArgs(res.args[commandName])
      res.stashFlags()
      resFound = true

template doRun() =
  try:
    discard run(stack)
    cmdlineStashTry()
  except:
    error("Could not load configuration files. exiting.")
    dumpExOnDebug()
    quit(1)

proc loadAllConfigs*() =
  var
    params:   seq[string] = commandLineParams()
    res:      ArgResult # Used across macros above.
    resFound: bool

  let
    toStream = newStringStream
    stack    = newConfigStack()
    exeName  = getMyAppPath().splitPath().tail

  case exeName
  of "docker":
    params = @[exeName] & params
  else: discard

  con4mRuntime = stack

  stack.
    addSystemBuiltins().
    addCustomBuiltins(chalkCon4mBuiltins).
    setErrorHandler(handleCon4mErrors).
    addGetoptSpecLoad().
    addSpecLoad(chalkSpecName,  toStream(chalkC42Spec), notEvenDefaults).
    addConfLoad(baseConfName,   toStream(baseConfig),   checkNone).
    addCallback(loadLocalStructs).
    addConfLoad(getoptConfName, toStream(getoptConfig), checkNone).
    setErrorHandler(handleOtherErrors).
    addStartGetOpts(printAutoHelp = false, args=params).
    addCallback(loadLocalStructs).
    setErrorHandler(handleCon4mErrors)
  doRun()

  stack.
    addConfLoad(ioConfName,        toStream(ioConfig),        notEvenDefaults).
    addConfLoad(attestConfName,    toStream(attestConfig),    checkNone).
    addConfLoad(sbomConfName,      toStream(sbomConfig),      checkNone).
    addConfLoad(sastConfName,      toStream(sastConfig),      checkNone).
    addConfLoad(techStackConfName, toStream(techStackConfig), checkNone).
    addConfLoad(linguistConfName,  toStream(linguistConfig),  checkNone).
    addConfLoad(coConfName,        toStream(coConfig),        checkNone)

  stack.addCallback(loadLocalStructs)
  doRun()

  # We need Codecs to load before we can get a self-extraction.
  loadAllPlugins()

  # Next, do self extraction, and get the embedded config.
  # The embedded config has already been validated.
  let configFile = getEmbeddedConfig()

  if get[bool](chalkConfig, "load_embedded_config"):
    stack.addConfLoad(embeddedConfName, toStream(configFile)).
          addCallback(loadLocalStructs)
    doRun()

  if get[bool](chalkConfig, "load_external_config"):
    let optConf = stack.configState.findOptionalConf()
    if optConf.isSome():
      let fName = optConf.get()
      withFileStream(fname, mode = fmRead, strict = true):
        stack.
          addConfLoad(fName, stream).
          addCallback(loadLocalStructs)
        doRun()
      hostInfo["_OP_CONFIG"] = pack(configFile)

  if commandName == "not_supplied" and getOpt[string](chalkConfig, "default_command").isSome():
    setErrorHandler(stack, handleOtherErrors)
    addFinalizeGetOpts(stack, printAutoHelp = false)
    addCallback(stack, loadLocalStructs)
    doRun()
