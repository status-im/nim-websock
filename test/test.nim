include ../src/ws
import chronos, chronicles, httputils, strutils, base64, std/sha1,
    streams, nativesockets, uri, times, chronos/timer, tables

# TODO: Fix Test.

block: # 7bit length
  assert encodeFrame((
    fin: true,
    rsv1: false,
    rsv2: false,
    rsv3: false,
    opcode: Opcode.Text,
    mask: false,
    data: toBytes("hi there"),
  )) == toBytes("\129\8hi there")

block: # 7+16 bits length
  var data = ""
  for i in 0..32:
    data.add "How are you this is the payload!!!"
  assert encodeFrame(
    fin: true,
    rsv1: false,
    rsv2: false,
    rsv3: false,
    opcode: Opcode.Text,
    mask: false,
    data: toBytes(data)
  )[0..32] == "\129~\4bHow are you this is the paylo"

block: # 7+64 bits length
  var data = ""
  for i in 0..3200:
    data.add "How are you this is the payload!!!"
  assert encodeFrame(
    fin: true,
    rsv1: false,
    rsv2: false,
    rsv3: false,
    opcode: Opcode.Text,
    mask: false,
    data: data
  )[0..32] == "\129\127\0\0\0\0\0\1\169\"How are you this is the"

block: # masking
  let data = encodeFrame(
    fin: true,
    rsv1: false,
    rsv2: false,
    rsv3: false,
    opcode: Opcode.Text,
    mask: true,
    data: toBytes("hi there"),
    maskKey: "aaaa"
  )
  assert data == "\129\136\207\216\5e\167\177%\17\167\189w\0"

block:
  let val = toTitleCase("webSocket", )
  assert val == "Websocket"
