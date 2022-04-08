## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import
  std/strutils,
  pkg/httputils,
  ../types

type
  AppExt* = object
    name*  : string
    params*: seq[ExtParam]

  TokenKind = enum
    tkError
    tkSemCol
    tkComma
    tkEqual
    tkName
    tkQuoted
    tkEof

  Lexer = object
    pos: int
    token: string
    tok: TokenKind

const
  WHITES = {' ', '\t'}
  LCHAR  = {'a'..'z', 'A'..'Z', '-', '_', '0'..'9','.','\''}
  SEPARATORS = {'`','~','!','@','#','$','%','^','&','*','(',')','+','=',
                '[','{',']','}', ';',':','\'',',','<','.','>','/','?','|'}
  QCHAR = WHITES + LCHAR + SEPARATORS

proc parseName[T: BChar](lex: var Lexer, data: openArray[T]) =
  while lex.pos < data.len:
    let cc = data[lex.pos]
    if cc notin LCHAR:
      break
    lex.token.add cc
    inc lex.pos

proc parseQuoted[T: BChar](lex: var Lexer, data: openArray[T]) =
  while lex.pos < data.len:
    let cc = data[lex.pos]
    case cc:
    of QCHAR:
      lex.token.add cc
      inc lex.pos
    of '\\':
      inc lex.pos
      if lex.pos >= data.len:
        lex.tok = tkError
        return
      lex.token.add data[lex.pos]
      inc lex.pos
    of '\"':
      inc lex.pos
      lex.tok = tkQuoted
      return
    else:
      lex.tok = tkError
      return

  lex.tok = tkError

proc next[T: BChar](lex: var Lexer, data: openArray[T]) =
  while lex.pos < data.len:
    if data[lex.pos] notin WHITES:
      break
    inc lex.pos
  lex.token.setLen(0)

  if lex.pos >= data.len:
    lex.tok = tkEof
    return

  let c = data[lex.pos]
  case c
  of ';':
    inc lex.pos
    lex.tok = tkSemCol
    return
  of ',':
    inc lex.pos
    lex.tok = tkComma
    return
  of '=':
    inc lex.pos
    lex.tok = tkEqual
    return
  of LCHAR:
    lex.parseName(data)
    lex.tok = tkName
    return
  of '\"':
    inc lex.pos
    lex.parseQuoted(data)
    return
  else:
    lex.tok = tkError
    return

proc parseExt*[T: BChar](data: openArray[T], output: var seq[AppExt]): bool =
  var lex: Lexer
  var ext: AppExt
  lex.next(data)

  while lex.tok notin {tkEof, tkError}:
    if lex.tok != tkName:
      return false
    ext.name = system.move(lex.token)

    lex.next(data)
    var param: ExtParam
    while lex.tok == tkSemCol:
      lex.next(data)
      if lex.tok in {tkEof, tkError}:
        return false
      if lex.tok != tkName:
        return false
      param.name = system.move(lex.token)
      lex.next(data)
      if lex.tok == tkEqual:
        lex.next(data)
        if lex.tok notin {tkName, tkQuoted}:
          return false
        param.value = system.move(lex.token)
        lex.next(data)
      ext.params.setLen(ext.params.len + 1)
      ext.params[^1].name  = system.move(param.name)
      ext.params[^1].value = system.move(param.value)

      if lex.tok notin {tkSemcol, tkComma, tkEof}:
        return false

    output.setLen(output.len + 1)
    output[^1].name   = toLowerAscii(ext.name)
    output[^1].params = system.move(ext.params)

    if lex.tok == tkEof:
      return true

    if lex.tok == tkComma:
      lex.next(data)
      if lex.tok != tkName:
        return false
      continue

  lex.tok != tkError
