## nim-websock
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/[asynctest, stew/byteutils]

include ../websock/frame
include ../websock/utils

# TODO: Fix Test.

var maskKey: array[4, char]

suite "Test data frames":
  test "# 7bit length text":
    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes("hi there")
    ).encode()) == toBytes("\1\8hi there")

  test "# 7bit length text fin bit":
    check (await Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes("hi there"),
      maskKey: maskKey
    ).encode()) == toBytes("\129\8hi there")

  test "# 7bit length binary":
    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes("hi there"),
      maskKey: maskKey
    ).encode()) == toBytes("\2\8hi there")

  test "# 7bit length binary fin bit":
    check (await Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes("hi there"),
      maskKey: maskKey
    ).encode()) == toBytes("\130\8hi there")

  test "# 7bit length continuation":
    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Cont,
      mask: false,
      data: toBytes("hi there"),
      maskKey: maskKey
    ).encode()) == toBytes("\0\8hi there")

  test "# 7+16 length text":
    var data = ""
    for i in 0..32:
      data.add "How are you this is the payload!!!"

    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    ).encode()) == toBytes("\1\126\4\98" & data)

  test "# 7+16 length text fin bit":
    var data = ""
    for i in 0..32:
      data.add "How are you this is the payload!!!"

    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    ).encode()) == toBytes("\1\126\4\98" & data)

  test "# 7+16 length binary":
    var data = ""
    for i in 0..32:
      data.add "How are you this is the payload!!!"

    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    ).encode()) == toBytes("\2\126\4\98" & data)

  test "# 7+16 length binary fin bit":
    var data = ""
    for i in 0..32:
      data.add "How are you this is the payload!!!"

    check (await Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    ).encode()) == toBytes("\130\126\4\98" & data)

  test "# 7+16 length continuation":
    var data = ""
    for i in 0..32:
      data.add "How are you this is the payload!!!"

    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Cont,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    ).encode()) == toBytes("\0\126\4\98" & data)

  test "# 7+64 length text":
    var data = ""
    for i in 0..3200:
      data.add "How are you this is the payload!!!"

    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    ).encode()) == toBytes("\1\127\0\0\0\0\0\1\169\34" & data)

  test "# 7+64 length fin bit":
    var data = ""
    for i in 0..3200:
      data.add "How are you this is the payload!!!"

    check (await Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    ).encode()) == toBytes("\129\127\0\0\0\0\0\1\169\34" & data)

  test "# 7+64 length binary":
    var data = ""
    for i in 0..3200:
      data.add "How are you this is the payload!!!"

    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    ).encode()) == toBytes("\2\127\0\0\0\0\0\1\169\34" & data)

  test "# 7+64 length binary fin bit":
    var data = ""
    for i in 0..3200:
      data.add "How are you this is the payload!!!"

    check (await Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    ).encode()) == toBytes("\130\127\0\0\0\0\0\1\169\34" & data)

  test "# 7+64 length binary":
    var data = ""
    for i in 0..3200:
      data.add "How are you this is the payload!!!"

    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Cont,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    ).encode()) == toBytes("\0\127\0\0\0\0\0\1\169\34" & data)

  test "# masking":
    let data = (await Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: true,
      data: toBytes("hi there"),
      maskKey: ['\xCF', '\xD8', '\x05', 'e']
    ).encode())

    check data == toBytes("\129\136\207\216\5e\167\177%\17\167\189w\0")

suite "Test control frames":

  test "Close":
    check (await Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Close,
      mask: false,
      data: @[3'u8, 232'u8] & toBytes("hi there"),
      maskKey: maskKey
    ).encode()) == toBytes("\136\10\3\232hi there")

  test "Ping":
    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Ping,
      mask: false,
      maskKey: maskKey
    ).encode()) == toBytes("\9\0")

  test "Pong":
    check (await Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Pong,
      mask: false,
      maskKey: maskKey
    ).encode()) == toBytes("\10\0")
