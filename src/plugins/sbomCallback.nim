import options, tables
import nimutils/box, con4m/[eval, st], ../config, ../plugins

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

const pluginName      = "sbom_callback"
const callbackName    = "get_sboms"
const callbackTypeStr = "f(string) -> {string : string}"
let   callbackType    = callbackTypeStr.toCon4mType()

type SbomCallbackPlugin* = ref object of Plugin

method getArtifactInfo*(self: SbomCallbackPlugin,
                        sami: SamiObj): KeyInfo =

  let optInfo = sCall(getConfigState(),
                      callbackName,
                      @[pack(sami.fullpath)],
                      callbackType)
  if optInfo.isSome():
    let
      res = optinfo.get()
      dict = unpack[TableRef[string, Box]](res)

    if len(dict) != 0:
      new result
      result["SBOMS"] = res

registerPlugin(pluginName, SbomCallbackPlugin())
registerCon4mCallback(callbackName, callbackTypeStr)
