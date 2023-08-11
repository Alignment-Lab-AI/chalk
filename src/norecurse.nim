## Make sure multiple chalk exes don't invoke each other in a
## recursive loop.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import config

const recursionEnvVar = "__CHALK_INVOCATIONS__"
const recursionLimit  = 3

proc recursionCheck*() =
  if not existsEnv(recursionEnvVar):
    putEnv(recursionEnvVar, "1")
    return

  let cur = getEnv(recursionEnvVar)

  try:
    let
      num   = parseInt(cur)
      limit = 3
    if num >= limit:
      error("""
Chalk is calling chalk recursively. This should only happen in specific
circumstances, and should never reach a recursion depth greater than 2.

If the environment variable __CHALK_INVOCATIONS__ wasn't maliciously
set, then there's probably a bug.
""")
      quit(-1)
    else:
      putEnv(recursionEnvVar, $(num + 1))
  except:
    putEnv(recursionEnvVar, "1")