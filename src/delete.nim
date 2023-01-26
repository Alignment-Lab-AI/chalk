import options, streams, strformat, os, std/tempfiles
import nimutils, config, plugins, extract

const
  eDeleteFailed = "{item.fullpath}: deletion failed"

proc doDelete*() =
  trace("Identifying artifacts with existing SAMIs")

  var codecs           = getCodecsByPriority()
  let pendingDeletions = doExtraction()

  if pendingDeletions.isSome():
    publish("delete", pendingDeletions.get())

  for codec in codecs:
    let
      extracts = codec.getSamis()

    if len(extracts) == 0: continue

    for item in extracts:
      if not item.primary.present:
        continue # It's markable, but not marked.

      let
        `stream?`  = item.acquireFileStream()
      # acquireFileStream will have reported the error.
      if not `stream?`.isSome(): continue

      var
        stream     = `stream?`.get()

      stream.setPosition(0)

      let
        outputPtrs = getOutputPointers()
        point      = item.primary
        pre        = stream.readStr(point.startOffset)

      dryRun(fmt"{item.fullPath}: removing sami")
      if getDryRun():
        item.yieldFileStream()
        continue

      if point.endOffset > point.startOffset:
        stream.setPosition(point.endOffset)

      let
        post = stream.readAll()

      item.yieldFileStream()

      var
        f:    File
        path: string
        ctx:  FileStream

      try:
        (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
        ctx       = newFileStream(f)
        codec.handleWrite(ctx, pre, none(string), post)
        close(f)
        info(fmt"{item.fullPath}: SAMI removed")
      except:
        error(eDeleteFailed.fmt())
        removeFile(path)
      finally:
        if ctx != nil:
          ctx.close()
          try:
            moveFile(path, item.fullPath)
          except:
            removeFile(path)
            error(fmt"{item.fullPath}: Could not write (no permission)")
