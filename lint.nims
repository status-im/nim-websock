#!/usr/bin/env nim
import std/strutils

proc lintFile*(file: string) =
  if file.endsWith(".nim"):
    exec "nimpretty " & file

proc lintDir*(dir: string) =
  for file in listFiles(dir):
    lintFile(file)
  for subdir in listDirs(dir):
    lintDir(subdir)

lintDir(projectDir())