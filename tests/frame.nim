include ../src/ws
include ../src/http
include ../src/random
#import chronos, chronicles, httputils, strutils, base64, std/sha1,
#    streams, nativesockets, uri, times, chronos/timer, tables

import unittest

# TODO: Fix Test.

var maskKey: array[4, char]

suite "tests for encodeFrame()":
  test "# 7bit length":
    block: # 7bit length
      assert encodeFrame((
        fin: true,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: Opcode.Text,
        mask: false,
        data: toBytes("hi there"),
        maskKey: maskKey
      )) == toBytes("\129\8hi there")
  test "# 7bit length":
    block: # 7+16 bits length
      var data = ""
      for i in 0..32:
        data.add "How are you this is the payload!!!"
      assert encodeFrame((
        fin: true,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: Opcode.Text,
        mask: false,
        data: toBytes(data),
        maskKey: maskKey
      ))[0..32] == toBytes("\129~\4bHow are you this is the paylo")
  test "# 7+64 bits length":
    block: # 7+64 bits length
      var data = ""
      for i in 0..3200:
        data.add "How are you this is the payload!!!"
      assert encodeFrame((
        fin: true,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: Opcode.Text,
        mask: false,
        data: toBytes(data),
        maskKey: maskKey
      ))[0..32] == toBytes("\129\127\0\0\0\0\0\1\169\"How are you this is the")
  test "# masking":
    block: # masking
      let data = encodeFrame((
        fin: true,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: Opcode.Text,
        mask: true,
        data: toBytes("hi there"),
        maskKey: ['\xCF', '\xD8', '\x05', 'e']
      ))
      assert data == toBytes("\129\136\207\216\5e\167\177%\17\167\189w\0")

suite "tests for toTitleCase()":
  block:
    let val = toTitleCase("webSocket")
    assert val == "Websocket"



