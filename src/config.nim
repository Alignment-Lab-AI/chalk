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
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import c4autoconf
export c4autoconf # This is conceptually part of our API.

import options, tables, strutils, algorithm, os, streams, uri
import con4m, nimutils, nimutils/logging, types, sugar
import macros except error
export logging, types, nimutils, con4m

proc commentC4mCode(s: string): string =
  let lines = s.split("\n")
  result    = ""
  for line in lines: result &= "# " & line & "\n"

  # Some string constants used in multiple places.
const
  magicUTF8*          = "dadfedabbadabbed"
  tmpFilePrefix*      = "chalk-"
  tmpFileSuffix*      = "-file.tmp"
  chalkSpecName*      = "configs/chalk.c42spec"
  getoptConfName*     = "configs/getopts.c4m"
  baseConfName*       = "configs/baseconfig.c4m"
  signConfName*       = "configs/signconfig.c4m"
  sbomConfName*       = "configs/sbomconfig.c4m"
  sastConfName*       = "configs/sastconfig.c4m"
  ioConfName*         = "configs/ioconfig.c4m"
  dockerConfName*     = "configs/dockercmd.c4m"
  defCfgFname*        = "configs/defaultconfig.c4m"  # Default embedded config.
  chalkC42Spec*       = staticRead(chalkSpecName)
  getoptConfig*       = staticRead(getoptConfName)
  baseConfig*         = staticRead(baseConfName)
  signConfig*         = staticRead(signConfName)
  sbomConfig*         = staticRead(sbomConfName)
  sastConfig*         = staticRead(sastConfName)
  ioConfig*           = staticRead(ioConfName)
  dockerConfig*       = staticRead(dockerConfName)
  defaultConfig*      = staticRead(defCfgFname) & commentC4mCode(ioConfig)
  versionStr          = staticexec("cat ../*.nimble | grep ^version")
  commitID            = staticexec("git rev-parse HEAD")
  archStr             = staticexec("uname -m")
  osStr               = staticexec("uname -o")
  #% INTERNAL
  entryPtTemplateLoc* = "configs/entrypoint.c4m"
  entryPtTemplate*    = staticRead(entryPtTemplateLoc)
  #% END

var
  con4mRuntime:       ConfigStack
  chalkConfig*:       ChalkConfig
  commandName:        string
  currentOutputCfg:   OutputConfig
  `isChalkingOp?`:    bool

template dumpExOnDebug*() =
  if chalkConfig != nil and chalkConfig.getChalkDebug():
    publish("debug", getCurrentException().getStackTrace())

proc runCallback*(cb: CallbackObj, args: seq[Box]): Option[Box] =
  return con4mRuntime.configState.sCall(cb, args)
proc runCallback*(s: string, args: seq[Box]): Option[Box] =
  return con4mRuntime.configState.scall(s, args)

macro declareChalkExeVersion(): untyped = parseStmt("const " & versionStr)
declareChalkExeVersion()

proc getChalkExeVersion*(): string   = version
proc getChalkCommitId*(): string     = commitID
proc getChalkPlatform*(): string     = osStr & " " & archStr
proc getCommandName*(): string       = commandName
proc setCommandName*(s: string) =
  ## Used when nesting operations.  For instance, when recursively
  ## chalking Zip files, we run a 'delete' over a copy of the Zip
  ## to calculate the unchalked hash.
  commandName = s
proc getChalkRuntime*(): ConfigState = con4mRuntime.configState

proc isChalkingOp*(): bool =
  once:
    `isChalkingOp?` = commandName in chalkConfig.getValidChalkCommandNames()
  return `isChalkingOp?`

proc getOutputConfig*(): OutputConfig =
  once: currentOutputCfg = chalkConfig.outputConfigs[getCommandName()]
  return currentOutputCfg

proc filterByProfile*(dict: ChalkDict, p: Profile): ChalkDict =
  result = ChalkDict()
  for k, v in dict:
    if k in p.keys and p.keys[k].report: result[k] = v

proc filterByProfile*(host, obj: ChalkDict, p: Profile): ChalkDict =
  result = ChalkDict()
  # Let obj-level clobber host-level.
  for k, v in host:
    if k in p.keys and p.keys[k].report: result[k] = v
  for k, v in obj:
    if k in p.keys and p.keys[k].report: result[k] = v

proc lookupCollectedKey*(obj: ChalkObj, k: string): Option[Box] =
  if k in hostInfo:          return some(hostInfo[k])
  if k in obj.collectedData: return some(obj.collectedData[k])
  return none(Box)

proc orderKeys*(dict: ChalkDict, profile: Profile = nil): seq[string] =
  var tmp: seq[(int, string)] = @[]
  for k, _ in dict:
    var order = chalkConfig.keySpecs[k].normalizedOrder
    if profile != nil and k in profile.keys:
      let orderOpt = profile.keys[k].order
      if orderOpt.isSome():
        order = orderOpt.get()
    tmp.add((order, k))

  tmp.sort()
  result = @[]
  for (_, key) in tmp: result.add(key)

proc getKeySpec*(name: string): Option[KeySpec] =
  if name in chalkConfig.keyspecs: return some(chalkConfig.keyspecs[name])

proc getPluginConfig*(name: string): Option[PluginSpec] =
  if name in chalkConfig.plugins:
    return some(chalkConfig.plugins[name])

# Nim doesn't do well with recursive imports.  Our main path imports
# plugins, but some plugins need to recursively scan into a temporary
# file system (e.g., ZIP files).
#
# To enable codecs to call back into commands.nim, we set a function
# pointer here that commands.nim will set once it's imported us.
# Then, when needed, codecs can trigger a nested scan by dereferencing
# this function pointer.

var chalkSubScanFunc*: (string, string,
                       (CollectionCtx) -> void) -> CollectionCtx

proc runChalkSubScan*(loc: string, cmd: string,
                      f: (CollectionCtx) -> void = nil): CollectionCtx =
  return chalkSubScanFunc(loc, cmd, f)

import collect # Cyclical, but get chalkCon4mBuiltins here.

# Since these are system keys, we are the only one able to write them,
# and it's easier to do it directly here than in the system plugin.
proc stashFlags(winner: ArgResult) =
  var flagStrs: seq[string] = @[]

  for key, value in winner.stringizeFlags():
    if value == "": flagStrs.add("--" & key)
    else:           flagStrs.add("--" & key & "=" & value)

  hostInfo["_OP_CMD_FLAGS"] = pack(flagStrs)

# TODO: static code to validate loaded specs.

proc getEmbeddedConfig(): string =
  result         = defaultConfig
  let extraction = getSelfExtraction()
  if extraction.isSome():
    let selfChalk = extraction.get().extract
    if selfChalk != nil and selfChalk.contains("$CHALK_CONFIG"):
      trace("Found embedded config file in self-chalk.")
      return unpack[string](selfChalk["$CHALK_CONFIG"])

proc findOptionalConf(state: ConfigState): Option[(string, FileStream)] =
  result = none((string, FileStream))
  let
    path     = unpack[seq[string]](state.attrLookup("config_path").get())
    filename = unpack[string](state.attrLookup("config_filename").get())
  for dir in path:
    let fname = dir.joinPath(filename)
    if fname.fileExists():
      info(fname & ": Found config file")
      try:
        return some((fname, newFileStream(fname)))
      except:
        error(fname & ": Could not read configuration file")
        dumpExOnDebug()
        break
    else:
        trace("No configuration file found in " & dir)

var cmdSpec: CommandSpec = nil
proc getArgCmdSpec*(): CommandSpec = cmdSpec
var autoHelp: string = ""
proc getAutoHelp*(): string = autoHelp

const
  availableFilters = { "log_level"     : MsgFilter(logLevelFilter),
                       "log_prefix"    : MsgFilter(logPrefixFilter),
                       "pretty_json"   : MsgFilter(prettyJson),
                       "fix_new_line"  : MsgFilter(fixNewline),
                       "add_topic"     : MsgFilter(addTopic),
                       "wrap"          : MsgFilter(wrapToWidth)
                     }.toTable()

proc getFilterName*(filter: MsgFilter): Option[string] =
  for name, f in availableFilters:
    if f == filter: return some(name)


var availableSinkConfigs = { "log_hook"     : defaultLogHook,
                             "con4m_hook"   : defaultCon4mHook,
                     }.toTable()

when not defined(release):
  availableSinkConfigs["debug_hook"] = defaultDebugHook

proc getSinkConfigByName*(name: string): Option[SinkConfig] =
  if name in availableSinkConfigs:
    return some(availableSinkConfigs[name])

  let
    attrRoot = chalkConfig.`@@attrscope@@`
    attrs    = attrRoot.getObjectOpt("sink_config." & name).getOrElse(nil)

  if attrs == nil:
    return none(SinkConfig)

  var
    sinkName:    string
    filterNames: seq[string]
    filters:     seq[MsgFilter] = @[]
    opts                        = OrderedTableRef[string, string]()

  for k, _ in attrs.contents:
    case k
    of "enabled":
      if not get[bool](attrs, k):
        error("Sink configuration '" & name & " is disabled.")
        return none(SinkConfig)
    of "filters":                  filterNames = get[seq[string]](attrs, k)
    of "sink":                     sinkName    = get[string](attrs, k)
    else:                          opts[k]     = get[string](attrs, k)

  case sinkName
  of "":
    error("Sink config '" & name & "' does not specify a sink type.")
    dumpExOnDebug()
    return none(SinkConfig)
  of "s3":
    try:
      let dstUri = parseUri(opts["uri"])
      if dstUri.scheme != "s3":
        error("Sink config '" & name & "' requires a URI of " &
              "the form s3://bucket-name/object-path")
        return none(SinkConfig)
    except:
        error("Sink config '" & name & "' has an invalid URI.")
        dumpExOnDebug()
        return none(SinkConfig)
  else:
    discard

  let theSinkOpt = getSink(sinkName)
  if theSinkOpt.isNone():
    error("Sink '" & sinkname & "' is configured, and the config file " &
         "specs it, but there is no implementation for that sink.")
    return none(SinkConfig)

  for item in filterNames:
    if item notin availableFilters:
      error("Message filter '" & item & "' cannot be found.")
    else:
     filters.add(availableFilters[item])

  result = configSink(theSinkOpt.get(), some(opts), filters)

  if result.isSome():
    availableSinkConfigs[name] = result.get()
    info("Loaded sink config for '" & name & "'")
  else:
    error("Output sink configuration '" & name & "' failed to load.")
    return none(SinkConfig)

proc getSinkConfigs*(): Table[string, SinkConfig] = return availableSinkConfigs

proc setupDefaultLogConfigs*() =
  let
    cacheFile = chalkConfig.getReportCacheLocation()
    doCache   = chalkConfig.getUseReportCache()
    auditFile = chalkConfig.getAuditLocation()
    doAudit   = chalkConfig.getPublishAudit()

  if doAudit and auditFile != "":
    let
      f         = some(newOrderedTable({ "filename" : auditFile}))
      auditConf = configSink(getSink("rotating_log").get(), f).get()

    availableSinkConfigs["audit_file"] = auditConf
    if subscribe("audit", auditConf).isNone():
      error("Unknown error initializing audit log.")
    else:
      trace("Audit log subscription enabled")
  if doCache:
    let
      f         = some(newOrderedTable({"filename" : cacheFile}))
      cacheConf = configSink(getSink("rotating_log").get(), f).get()

    availableSinkConfigs["report_cache"] = cacheConf
    if subscribe("report", cacheConf).isNone():
      error("Unknown error initializing report cache.")
    else:
      trace("Report cache subscription enabled")

  let
    uri       = chalkConfig.getCrashOverrideUsageReportingUrl()
    workspace = chalkConfig.getCrashOverrideWorkspaceId()
    headers   = "X-Crashoverride-Workspace-Id: " & workspace & "\n" &
                "Content-Type: application/json"

    params  = some(newOrderedTable({ "uri": uri, "headers" : headers }))
    useConf = configSink(getSink("post").get(), params)

  discard subscribe("chalk_usage_stats", useConf.get())

proc loadLocalStructs*(state: ConfigState) =
  chalkConfig = state.attrs.loadChalkConfig()
  if chalkConfig.color.isSome(): setShowColors(chalkConfig.color.get())
  setLogLevel(chalkConfig.logLevel)
  for i in 0 ..< len(chalkConfig.configPath):
    chalkConfig.configPath[i] = chalkConfig.configPath[i].resolvePath()
  var c4errLevel =  if chalkConfig.con4mPinpoint: c4vShowLoc else: c4vBasic

  if chalkConfig.chalkDebug:
    c4errLevel = if c4errLevel == c4vBasic: c4vTrace else: c4vMax

  setCon4mVerbosity(c4errLevel)

proc handleCon4mErrors(err, tb: string): bool =
  if chalkConfig == nil or chalkConfig.chalkDebug or true:
    error(err & "\n" & tb)
  else:
    error(err)
  return true

proc handleOtherErrors(err, tb: string): bool =
  error(getAppFilename().splitPath().tail & ": " & err)
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

import builtins

proc loadAllConfigs*() =
  var
    params:   seq[string] = commandLineParams()
    res:      ArgResult # Used across macros above.
    resFound: bool


  let
    toStream = newStringStream
    stack    = newConfigStack()

  case getAppFileName().splitPath().tail
  of "docker":
    if "docker" notin params: params = @["docker"] & params
  else: discard

  con4mRuntime = stack

  stack.addSystemBuiltins().
      addCustomBuiltins(chalkCon4mBuiltins).
      setErrorHandler(handleCon4mErrors).
      addGetoptSpecLoad().
      addSpecLoad(chalkSpecName, toStream(chalkC42Spec), notEvenDefaults).
      addConfLoad(baseConfName, toStream(baseConfig), checkNone).
      addCallback(loadLocalStructs).
      addConfLoad(getoptConfName, toStream(getoptConfig), checkNone).
      setErrorHandler(handleOtherErrors).
      addStartGetOpts(printAutoHelp = false, args=params).
      addCallback(loadLocalStructs).
      setErrorHandler(handleCon4mErrors)
  doRun()

  stack.addConfLoad(ioConfName, toStream(ioConfig), notEvenDefaults).
      addConfLoad(dockerConfName, toStream(dockerConfig), checkNone)

  if chalkConfig.getLoadDefaultSigning():
    stack.addConfLoad(signConfName, toStream(signConfig), checkNone)

  let chalkOps = chalkConfig.getValidChalkCommandNames()
  if commandName in chalkOps or (commandName == "not_supplied" and
    chalkConfig.defaultCommand.getOrElse("") in chalkOps):
    stack.addConfLoad(sbomConfName, toStream(sbomConfig), checkNone)
    stack.addConfLoad(sastConfName, toStream(sastConfig), checkNone)

  stack.addCallback(loadLocalStructs)
  doRun()

  # Next, do self extraction, and get the embedded config.
  # The embedded config has already been validated.
  let configFile = getEmbeddedConfig()

  if chalkConfig.getLoadEmbeddedConfig():
    stack.addConfLoad("<<embedded config>>", toStream(configFile)).
          addCallback(loadLocalStructs)
    doRun()

  if chalkConfig.getLoadExternalConfig():
    let optConf = stack.configState.findOptionalConf()
    if optConf.isSome():
      let (fName, stream) = optConf.get()
      var embed = stream.readAll()
      stack.addConfLoad(fName, toStream(embed)).addCallback(loadLocalStructs)
      doRun()
      hostInfo["_OP_CONFIG"] = pack(configFile)

  if commandName == "not_supplied" and chalkConfig.defaultCommand.isSome():
    setErrorHandler(stack, handleOtherErrors)
    addFinalizeGetOpts(stack, printAutoHelp = false)
    addCallback(stack, loadLocalStructs)
    doRun()

template parseDockerCmdline*(): (string, seq[string],
                             OrderedTable[string, FlagSpec])  =
  con4mRuntime.addStartGetopts("docker.getopts", args = getArgs()).run()
  (con4mRuntime.getCommand(), con4mRuntime.getArgs(), con4mRuntime.getFlags())
