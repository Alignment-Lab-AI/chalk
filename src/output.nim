import config
import osproc
import streams
import strformat
import strutils
import tables
import json
import std/uri
import nimutils
import nimutils/random
import nimaws/s3client

var outputCallbacks: Table[string, SamiOutputHandler]
let contextAsText = { OutCtxExtract : "extracting SAMIs",
                      OutCtxInjectPrev : "looking for existing SAMIs",
                      OutCtxInject : "injecting SAMIs" }.toTable

proc registerOutputHandler*(name: string, fn: SamiOutputHandler) =
  outputCallbacks[name] = fn

proc handleOutput*(content: string, context: SamiOutputContext) =
  let
    handleInfo = getOutputConfig()
    handles = case context
      of OutCtxInject:
        getInjectionOutputHandlers()
      of OutCtxInjectPrev:
        getInjectionPrevSamiOutputHandlers()
      of OutCtxExtract:
        getExtractionOutputHandlers()

  if getDryRun():
    let
      handlers = case context
                of OutCtxExtract: getExtractionOutputHandlers()
                of OutCtxInjectPrev: getInjectionPrevSamiOutputHandlers()
                of OutCtxInject: getInjectionOutputHandlers()
      ct = "When " & contextAsText[context] & ":"
      xtra = if handlers != @["stdout"]:
               "\nWould have written to handlers:\n" &
                 pretty(parseJson(content))
             else: "\n"
      output = if handlers.len() != 0:
                 fmt"{ct} without 'dry run' on, would have sent output to: " &
                   handlers.join(", ") & xtra
               else:
                 fmt"{ct} No output handlers installed, and 'dry run' on." &
                  xtra
            
    echo output
    return
    
  for handle in handles:
    if not (handle in handleInfo):
      # There's not a config blob, so we can't possibly
      # have the plugin loaded.
      continue

    let thisInfo = handleInfo[handle]

    if handle in outputCallbacks:
      # This is the standard path. If it's false, then we will check
      # below for a command in the handler.
      let fn = outputCallbacks[handle]

      # For now, we're not handling failure.  Need to think about how
      # we want to handle it.
      if not fn(content, thisInfo, contextAsText[context]):
        when not defined(release):
          stderr.writeLine(fmt"Output handler {handle} failed.")
      continue
    elif thisInfo.getOutputCommand().isSome():
      let cmd = thisInfo.getOutputCommand().get()
      try:
        let
          process = startProcess(cmd[0],
                                 args = cmd[1 .. ^1],
                                 options = {poUsePath})
          (istream, ostream) = (process.outputStream, process.inputStream)
        ostream.write(content)
        ostream.flush()
        istream.close()
        discard process.waitForExit()
      except:
        when not defined(release):
          stderr.writeLine("Output handler {handle} failed.")
          raise

proc stdoutHandler*(content: string,
                    h: SamiOutputSection,
                    ctx: string): bool =
  echo "When ", ctx, ":"
  echo pretty(parseJson(content))
  return true

proc localFileHandler*(content: string,
                       h: SamiOutputSection,
                       ctx: string): bool =
  var f: FileStream

  if not h.getOutputFilename().isSome():
    return false
  try:
    f = newFileStream(h.getOutputFileName().get(), fmWrite)
    f.write(fmt"""{{ "context": {ctx}, "SAMIs" : {content} }}""")
  except:
    return false
  finally:
    if f != nil:
      f.close()

proc getUniqueSuffix(h: SamiOutputSection): string =
  let auxId = h.getOutputAuxId().getOrElse("")
    
  result = "." & $(unixTimeInMS())
  if auxId != "": result = result & "." & auxId
  result = result & "." & $(secureRand[uint32]()) & ".json"

  
proc awsFileHandler*(content: string,
                     h: SamiOutputSection,
                     ctx: string): bool =
  if h.getOutputSecret().isNone():
    stderr.writeLine("AWS secret not configured.")
    when not defined(release):
      echo getStackTrace()
    return false
  if h.getOutputUserId().isNone():
    stderr.writeLine("AWS iam user not configured.")
    when not defined(release):
      echo getStackTrace()
    return false
  if h.getOutputDstUri().isNone():
    stderr.writeLine("AWS bucket URI not configured.")
    when not defined(release):
      echo getStackTrace()
    return false
  if not h.getOutputRegion().isSome():
    stderr.writeLine("AWS region not configured.")
    when not defined(release):
      echo getStackTrace()
    return false

  let
    secret = h.getOutputSecret().get()
    userid = h.getOutputUserId().get()
    dstUri = parseURI(h.getOutputDstUri().get())
    bucket = dstUri.hostname
    path   = dstUri.path[1 .. ^1] & getUniqueSuffix(h)
    region = h.getOutputRegion().get()
    body   = fmt"""{{ "context": {ctx}, "SAMIs" : {content} }}"""

  var
    client = newS3Client((userid, secret))

  if dstUri.scheme != "s3":
    let msg = "AWS URI must be of type s3"
    stderr.writeLine(msg)
    return false
    
  discard client.putObject(bucket, path, body)
  return true

registerOutputHandler("stdout", stdoutHandler)
registerOutputHandler("local_file", localFileHandler)
registerOutputHandler("s3", awsFileHandler)
