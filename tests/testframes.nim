import unittest

include ../src/ws
include ../src/http
include ../src/random

# TODO: Fix Test.

var maskKey: array[4, char]

suite "Test data frames":
  test "# 7bit length text":
    check encodeFrame(Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes("hi there"),
      maskKey: maskKey
    )) == toBytes("\1\8hi there")

  test "# 7bit length text fin bit":
    check encodeFrame(Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes("hi there"),
      maskKey: maskKey
    )) == toBytes("\129\8hi there")

  test "# 7bit length binary":
    check encodeFrame(Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes("hi there"),
      maskKey: maskKey
    )) == toBytes("\2\8hi there")

  test "# 7bit length binary fin bit":
    check encodeFrame(Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes("hi there"),
      maskKey: maskKey
    )) == toBytes("\130\8hi there")

  test "# 7bit length continuation":
    check encodeFrame(Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Cont,
      mask: false,
      data: toBytes("hi there"),
      maskKey: maskKey
    )) == toBytes("\0\8hi there")

  test "# 7+16 length text":
    var data = ""
    for i in 0..32:
      data.add "How are you this is the payload!!!"

    check encodeFrame(Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    )) == toBytes("\1\126\4\98" & data)

  test "# 7+16 length text fin bit":
    var data = ""
    for i in 0..32:
      data.add "How are you this is the payload!!!"

    check encodeFrame(Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    )) == toBytes("\1\126\4\98" & data)

  test "# 7+16 length binary":
    var data = ""
    for i in 0..32:
      data.add "How are you this is the payload!!!"

    check encodeFrame(Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    )) == toBytes("\2\126\4\98" & data)

  test "# 7+16 length binary fin bit":
    var data = ""
    for i in 0..32:
      data.add "How are you this is the payload!!!"

    check encodeFrame(Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    )) == toBytes("\130\126\4\98" & data)

  test "# 7+16 length continuation":
    var data = ""
    for i in 0..32:
      data.add "How are you this is the payload!!!"

    check encodeFrame(Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Cont,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    )) == toBytes("\0\126\4\98" & data)

  test "# 7+64 length text":
    var data = ""
    for i in 0..3200:
      data.add "How are you this is the payload!!!"

    check encodeFrame(Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    )) == toBytes("\1\127\0\0\0\0\0\1\169\34" & data)

  test "# 7+64 length fin bit":
    var data = ""
    for i in 0..3200:
      data.add "How are you this is the payload!!!"

    check encodeFrame(Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    )) == toBytes("\129\127\0\0\0\0\0\1\169\34" & data)

  test "# 7+64 length binary":
    var data = ""
    for i in 0..3200:
      data.add "How are you this is the payload!!!"

    check encodeFrame(Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    )) == toBytes("\2\127\0\0\0\0\0\1\169\34" & data)

  test "# 7+64 length binary fin bit":
    var data = ""
    for i in 0..3200:
      data.add "How are you this is the payload!!!"

    check encodeFrame(Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Binary,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    )) == toBytes("\130\127\0\0\0\0\0\1\169\34" & data)

  test "# 7+64 length binary":
    var data = ""
    for i in 0..3200:
      data.add "How are you this is the payload!!!"

    check encodeFrame(Frame(
      fin: false,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Cont,
      mask: false,
      data: toBytes(data),
      maskKey: maskKey
    )) == toBytes("\0\127\0\0\0\0\0\1\169\34" & data)

  test "# masking":
    let data = encodeFrame(Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Text,
      mask: true,
      data: toBytes("hi there"),
      maskKey: ['\xCF', '\xD8', '\x05', 'e']
    ))

    check data == toBytes("\129\136\207\216\5e\167\177%\17\167\189w\0")

suite "Test control frames":

  test "Close":
    check encodeFrame(Frame(
      fin: true,
      rsv1: false,
      rsv2: false,
      rsv3: false,
      opcode: Opcode.Close,
      mask: false,
      data: toBytes("hi there"),
      maskKey: maskKey
    )) == toBytes("\8\8hi there")
