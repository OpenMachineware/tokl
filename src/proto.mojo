# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2025 Jia Liu <proljc@gmail.com>
# SPDX-FileCopyrightText: 2025 tokl contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# Minimal protobuf wire parser - only used to read SentencePiece's
# tokenizer.model.
#
# ModelProto structure (relevant parts):
#   repeated SentencePiece pieces = 1;
#   SentencePiece { string piece = 1; float score = 2;
#     enum Type { NORMAL=1; UNKNOWN=2; CONTROL=3; USER_DEFINED=4;
#                 UNUSED=5; BYTE=6; } type = 3; }

from std.collections import List

comptime SP_NORMAL = 1
comptime SP_UNKNOWN = 2
comptime SP_BYTE = 6


# A single SentencePiece.
struct SentencePiece(Movable):
    var piece: List[Byte]
    var score: Float32
    var typ: UInt32

    def __init__(out self):
        self.piece = List[Byte]()
        self.score = 0.0
        self.typ = SP_NORMAL

    def __init__(out self, var piece: List[Byte], score: Float32, typ: UInt32):
        self.piece = piece^
        self.score = score
        self.typ = typ


# Reinterpret IEEE-754 single-precision bits as a Float32 value.
def f32_from_bits(bits: UInt32) -> Float32:
    var sign_neg = bits >= 0x80000000
    var e = Int((bits >> 23) & 0xFF)
    var m = Int(bits & 0x7FFFFF)
    var f: Float64
    if e == 0:
        f = Float64(m) * pow2(-149)
    elif e == 255:
        f = 1.0e300
    else:
        f = Float64(0x800000 | m) * pow2(Int(e) - 150)
    if sign_neg:
        f = -f
    return Float32(f)


# 2.0 ** k for an integer exponent (k in [-150, 150] in practice).
def pow2(k: Int) -> Float64:
    var r: Float64 = 1.0
    var i = 0
    if k >= 0:
        while i < k:
            r *= 2.0
            i += 1
    else:
        while i > k:
            r /= 2.0
            i -= 1
    return r


# Read a base-128 varint. Returns (value, new_pos).
def read_varint(data: Span[Byte, _], pos: Int) raises -> Tuple[UInt64, Int]:
    var result: UInt64 = 0
    var shift: Int = 0
    var p = pos
    while True:
        if p >= len(data):
            raise Error("truncated varint")
        var b = data[p]
        p += 1
        result |= UInt64(b & 0x7F) << UInt64(shift)
        if b & 0x80 == 0:
            return (result, p)
        shift += 7
        if shift >= 64:
            raise Error("varint too long")


def parse_sentence_piece(data: Span[Byte, _]) raises -> SentencePiece:
    var piece = List[Byte]()
    var score: Float32 = 0.0
    var typ: UInt32 = SP_NORMAL
    var pos = 0
    var n = len(data)
    while pos < n:
        var (tag, np) = read_varint(data, pos)
        pos = np
        var field = Int(tag >> 3)
        var wire = Int(tag & 0x7)
        if field == 1 and wire == 2:
            var (ln, np2) = read_varint(data, pos)
            pos = np2
            var end = pos + Int(ln)
            if end > n:
                raise Error("truncated piece")
            var k = pos
            while k < end:
                piece.append(data[k])
                k += 1
            pos = end
        elif field == 2 and wire == 5:
            if pos + 4 > n:
                raise Error("truncated score")
            var bits = (
                UInt32(data[pos])
                | (UInt32(data[pos + 1]) << 8)
                | (UInt32(data[pos + 2]) << 16)
                | (UInt32(data[pos + 3]) << 24)
            )
            score = f32_from_bits(bits)
            pos += 4
        elif field == 3 and wire == 0:
            var (v, np3) = read_varint(data, pos)
            pos = np3
            typ = UInt32(v)
        elif wire == 0:
            var (_, np4) = read_varint(data, pos)
            pos = np4
        elif wire == 1:
            pos += 8
        elif wire == 5:
            pos += 4
        elif wire == 2:
            var (ln2, np5) = read_varint(data, pos)
            pos = np5 + Int(ln2)
        else:
            raise Error("unsupported field in piece: wire={}".format(wire))
    return SentencePiece(piece^, score, typ)


# Parse ModelProto and return all pieces.
def parse_model(data: Span[Byte, _]) raises -> List[SentencePiece]:
    var pieces = List[SentencePiece]()
    var pos = 0
    var n = len(data)
    while pos < n:
        var (tag, np) = read_varint(data, pos)
        pos = np
        var field = Int(tag >> 3)
        var wire = Int(tag & 0x7)
        if wire == 0:
            var (_, np2) = read_varint(data, pos)
            pos = np2
        elif wire == 1:
            pos += 8
            if pos > n:
                raise Error("truncated protobuf (fixed64)")
        elif wire == 2:
            var (ln, np3) = read_varint(data, pos)
            pos = np3
            var end = pos + Int(ln)
            if end > n:
                raise Error("truncated protobuf (len-delimited)")
            if field == 1:
                pieces.append(parse_sentence_piece(data[pos:end]))
            pos = end
        elif wire == 5:
            pos += 4
            if pos > n:
                raise Error("truncated protobuf (fixed32)")
        else:
            raise Error("unsupported wire type: {}".format(wire))
    return pieces^
