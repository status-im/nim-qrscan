import std/os

switch("mm", "orc")
switch("threads", "on")
switch("path", thisDir())
for d in [".deps/nim-seaqt", ".deps/nimqml-seaqt/src", ".deps/nim-results"]:
  if dirExists(thisDir() / d):
    switch("path", thisDir() / d)
