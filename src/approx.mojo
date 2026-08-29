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
# Approximate tokenizer: heuristic estimate when no vocab is available.
#
# BPE-style tokenizers use roughly 1 token per 4 bytes for English/code;
# CJK text is roughly 1 token per character; other multi-byte characters
# (Hangul, kana, emoji, ...) are prorated by byte count. Error is usually
# within ±20%, giving a reasonable estimate without a local vocab.

from std.collections import List
from std.math import floor


struct ApproxParams(ImplicitlyCopyable):
    var cjk_per_char: Float64
    var ascii_div: Float64

    def __init__(out self):
        self.cjk_per_char = 1.0
        self.ascii_div = 4.0


# Whether a codepoint is CJK.
def is_cjk(c: Int) -> Bool:
    return (
        (0x4E00 <= c <= 0x9FFF)
        or (0x3400 <= c <= 0x4DBF)
        or (0x20000 <= c <= 0x2A6DF)
        or (0x2A700 <= c <= 0x2B73F)
        or (0x2B740 <= c <= 0x2B81F)
        or (0xF900 <= c <= 0xFAFF)
        or c == 0x3007
    )


# Decode one UTF-8 codepoint at data[i]. Returns (codepoint, bytes_consumed),
# or (-1, 0) when the sequence is invalid.
def utf8_decode_at(data: Span[Byte, _], i: Int) -> Tuple[Int, Int]:
    var b = data[i]
    var n = len(data)
    if b < 0x80:
        return (Int(b), 1)
    var l: Int
    var cp: Int
    if (b >> 5) == 0b110:
        l = 2
        cp = Int(b & 0x1F)
    elif (b >> 4) == 0b1110:
        l = 3
        cp = Int(b & 0x0F)
    elif (b >> 3) == 0b11110:
        l = 4
        cp = Int(b & 0x07)
    else:
        return (-1, 0)
    if i + l > n:
        return (-1, 0)
    var k = 1
    while k < l:
        var c = data[i + k]
        if (c >> 6) != 0b10:
            return (-1, 0)
        cp = (cp << 6) | Int(c & 0x3F)
        k += 1
    # Reject overlong encodings, surrogates and out-of-range values.
    if l == 2 and cp < 0x80:
        return (-1, 0)
    if l == 3 and (cp < 0x800 or (0xD800 <= cp <= 0xDFFF)):
        return (-1, 0)
    if l == 4 and (cp < 0x10000 or cp > 0x10FFFF):
        return (-1, 0)
    return (cp, l)


# Approximate token count.
def count_approx(data: List[Byte], ref params: ApproxParams) -> UInt64:
    var n = len(data)
    var tokens: Float64 = 0.0
    var ascii_count: UInt64 = 0
    var ascii_tokens: Float64 = 0.0
    var i = 0
    var valid = True
    while i < n:
        var (cp, l) = utf8_decode_at(data, i)
        if l == 0:
            valid = False
            break
        if cp < 0x80:
            ascii_count += 1
            if ascii_count >= 4096:
                ascii_tokens += Float64(ascii_count) / params.ascii_div
                ascii_count = 0
        elif is_cjk(cp):
            tokens += params.cjk_per_char
        else:
            tokens += Float64(l) / 2.0
        i += l
    if not valid:
        # Not UTF-8: prorate by bytes
        var m: Float64 = 0.0
        var ascii: UInt64 = 0
        for b in data:
            if b < 0x80:
                ascii += 1
            else:
                m += 0.5
        return UInt64(floor(m + Float64(ascii) / params.ascii_div))
    ascii_tokens += Float64(ascii_count) / params.ascii_div
    tokens += ascii_tokens
    return UInt64(floor(tokens))
