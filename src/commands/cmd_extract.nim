import ../config, ../collect, ../reporting

proc runCmdExtract*(path: seq[string]) =
  initCollection()

  var numExtracts = 0
  for item in artifacts(path):
    numExtracts += 1

  if numExtracts == 0: warn("No chalk marks extracted")
  doReporting()
