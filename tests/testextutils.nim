## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import
  pkg/chronos,
  pkg/asynctest/unittest2,
  ../websock/extensions

suite "extension parser":
  test "single extension":
    var app: seq[AppExt]
    let res = parseExt("permessage-deflate", app)
    check res == true
    check app.len == 1
    if app.len == 1:
      check app[0].name == "permessage-deflate"

  test "single extension quoted bad syntax":
    var app: seq[AppExt]
    let res = parseExt("\"zip\"", app)
    check res == false

  test "basic extensions no param":
    var app: seq[AppExt]
    let res = parseExt("permessage-deflate, snappy, bzip", app)
    check res == true
    check app.len == 3
    if app.len == 3:
      check app[0].name == "permessage-deflate"
      check app[1].name == "snappy"
      check app[2].name == "bzip"

  test "basic extensions no param bad syntax":
    var app: seq[AppExt]
    let res = parseExt("permessage-deflate, ", app)
    check res == false

  test "basic extensions no param with trailing leading whitespaces":
    var app: seq[AppExt]
    let res = parseExt(" permessage-deflate, snappy, bzip ", app)
    check res == true
    check app.len == 3
    if app.len == 3:
      check app[0].name == "permessage-deflate"
      check app[1].name == "snappy"
      check app[2].name == "bzip"

  test "basic extension with params":
    var app: seq[AppExt]
    let res = parseExt("snappy; arg1noval; arg2 = 123; arg3 = \"hello\"", app)
    check res == true
    check app.len == 1
    if app.len == 1:
      check app[0].name == "snappy"
      check app[0].params[0].name == "arg1noval"
      check app[0].params[0].value == ""

      check app[0].params[1].name == "arg2"
      check app[0].params[1].value == "123"

      check app[0].params[2].name == "arg3"
      check app[0].params[2].value == "hello"

  test "basic extension with param + fallback":
    var app: seq[AppExt]
    let res = parseExt("snappy; arg = 123, snappy", app)
    check res == true
    check app.len == 2
    if app.len == 2:
      check app[0].name == "snappy"
      check app[1].name == "snappy"

      check app[0].params[0].name == "arg"
      check app[0].params[0].value == "123"

  test "extension param no value + fallback":
    var app: seq[AppExt]
    let res = parseExt("snappy; arg, snappy", app)
    check res == true
    check app.len == 2
    if app.len == 2:
      check app[0].name == "snappy"
      check app[1].name == "snappy"

      check app[0].params[0].name == "arg"
      check app[0].params[0].value == ""

  test "extension param no value + fallback bad syntax":
    var app: seq[AppExt]
    let res = parseExt("snappy; arg = , snappy", app)
    check res == false

  test "extension param no value + fallback bad syntax":
    var app: seq[AppExt]
    let res = parseExt("snappy; arg = , snappy", app)
    check res == false

  test "extensions bad syntax":
    var app: seq[AppExt]
    let res = parseExt("snappy; snappy; ", app)
    check res == false

  test "extension bad syntax":
    var app: seq[AppExt]
    let res = parseExt("snappy; ", app)
    check res == false

  test "extension param no value bad syntax":
    var app: seq[AppExt]
    let res = parseExt("snappy; arg = ", app)
    check res == false

  test "extension param no value":
    var app: seq[AppExt]
    let res = parseExt("snappy; arg", app)
    check res == true
    check app.len == 1
    if app.len == 1:
      check app[0].name == "snappy"
      check app[0].params[0].name == "arg"
      check app[0].params[0].value == ""

  test "extension param not closed quoted value":
    var app: seq[AppExt]
    let res = parseExt("snappy; arg = \"wwww", app)
    check res == false

  test "inlwithasciifilename":
    var app: seq[AppExt]
    let res = parseExt("inline; filename=\"foo.html\"", app)
    check res == true
    check app[0].params[0].value == "foo.html"

  test "inlwithfnattach":
    var app: seq[AppExt]
    let res = parseExt("inline; filename=\"Not an attachment!\"", app)
    check res == true
    check app[0].params[0].value == "Not an attachment!"

  test "attwithasciifnescapedchar":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename=\"f\\oo.html\"", app)
    check res == true
    check app[0].params[0].value == "foo.html"

  test "attwithasciifnescapedquote":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename=\"\\\"quoting\\\" tested.html\"", app)
    check res == true
    check app[0].params[0].value == "\"quoting\" tested.html"

  test "attwithquotedsemicolon":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename=\"Here's a semicolon;.html\"", app)
    check res == true
    check app[0].params[0].value == "Here's a semicolon;.html"

  test "attwithfilenameandextparamescaped":
    var app: seq[AppExt]
    let res = parseExt("attachment; foo=\"\\\"\\\\\"", app)
    check res == true
    check app[0].params[0].value == "\"\\"

  test "attwithasciifilenamenq":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename=foo.html", app)
    check res == true
    check app[0].params[0].value == "foo.html"

  test "attemptyparam":
    var app: seq[AppExt]
    let res = parseExt("attachment; ;filename=foo", app)
    check res == false

  test "attwithasciifilenamenqws":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename=foo bar.html", app)
    check res == false

  test "attwithfntokensq":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename='foo.bar'", app)
    check res == true
    check app[0].params[0].value == "'foo.bar'"

  test "attfnbrokentoken":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename=foo[1](2).html", app)
    check res == false

  test "attfnbrokentokeniso":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename=foo-ä.html", app)
    check res == false

  test "attfnbrokentokenutf":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename=foo-Ã¤.html", app)
    check res == false

  test "attmissingdisposition":
    var app: seq[AppExt]
    let res = parseExt("filename=foo.html", app)
    check res == false

  test "attmissingdisposition2":
    var app: seq[AppExt]
    let res = parseExt("x=y; filename=foo.html", app)
    check res == false

  test "attmissingdisposition3":
    var app: seq[AppExt]
    let res = parseExt("\"foo; filename=bar;baz\"; filename=qux", app)
    check res == false

  test "attmissingdisposition4":
    var app: seq[AppExt]
    let res = parseExt("filename=foo.html, filename=bar.html", app)
    check res == false

  test "emptydisposition":
    var app: seq[AppExt]
    let res = parseExt(" ; filename=foo.html", app)
    check res == false

  test "doublecolon":
    var app: seq[AppExt]
    let res = parseExt(": inline; attachment; filename=foo.html", app)
    check res == false

  test "attbrokenquotedfn":
    var app: seq[AppExt]
    let res = parseExt(" attachment; filename=\"foo.html\".txt", app)
    check res == false

  test "attbrokenquotedfn2":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename=\"bar", app)
    check res == false

  test "attbrokenquotedfn3":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename=foo\"bar;baz\"qux", app)
    check res == false

  test "attmissingdelim":
    var app: seq[AppExt]
    let res = parseExt("attachment; foo=foo filename=bar", app)
    check res == false

  test "attmissingdelim2":
    var app: seq[AppExt]
    let res = parseExt("attachment; filename=bar foo=foo", app)
    check res == false

  test "attmissingdelim3":
    var app: seq[AppExt]
    let res = parseExt("attachment filename=bar", app)
    check res == false

  test "attreversed":
    var app: seq[AppExt]
    let res = parseExt("filename=foo.html; attachment", app)
    check res == false
