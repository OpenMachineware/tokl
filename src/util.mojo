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
# General utilities: base64 decoding, thousands separators,
# binary detection, path helpers.

from std.collections import List, Optional


# Base64 decode (standard alphabet, ignores whitespace).
def base64_decode(s: String) -> Optional[List[UInt8]]:
    var table = (
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    )
    var rev = Array[UInt8, 256](fill=255)
    var i = 0
    for b in table.as_bytes():
        rev[Int(b)] = UInt8(i)
        i += 1

    var out = List[UInt8](capacity=s.byte_length() // 4 * 3)
    var acc: UInt32 = 0
    var nbits: UInt32 = 0
    for b in s.as_bytes():
        if b == 0x20 or b == 0x09 or b == 0x0D or b == 0x0A:
            continue
        if b == 0x3D:  # '='
            break
        var v = rev[Int(b)]
        if v == 255:
            return Optional[List[UInt8]]()
        acc = (acc << 6) | UInt32(v)
        nbits += 6
        if nbits >= 8:
            nbits -= 8
            out.append(UInt8(acc >> nbits))
    return Optional[List[UInt8]](out^)


# Thousands separator: 1234567 -> "1,234,567"
def thousands(n: UInt64) -> String:
    var s = "{}".format(n)
    var digits = s.byte_length()
    var out = String(capacity=digits + digits // 3)
    var i = 0
    while i < digits:
        if i > 0 and (digits - i) % 3 == 0:
            out += ","
        out += s[byte = i : i + 1]
        i += 1
    return out


# Simple binary detection: a NUL byte in the first 8KB means binary.
def looks_binary(data: Span[Byte, _]) -> Bool:
    var limit = min(len(data), 8192)
    var i = 0
    while i < limit:
        if data[i] == 0:
            return True
        i += 1
    return False


# File extension (lowercase, no dot). Returns None when absent.
def extension_of(path: String) -> Optional[String]:
    var name = file_name_of(path)
    if name == "":
        return Optional[String]()
    var idx = name.rfind(".")
    if idx > 0 and idx < name.byte_length() - 1:
        return Optional[String](name[byte = idx + 1 :].lower())
    return Optional[String]()


# File name (without the directory).
def file_name_of(path: String) -> String:
    var idx = path.rfind("/")
    if idx < 0:
        return path
    var rest = String(unsafe_from_utf8=path.as_bytes()[idx + 1 :])
    return rest


# Whether data[pos:] starts with the byte pattern pat.
def bytes_starts_with(
    data: Span[Byte, _], pos: Int, pat: Span[Byte, _]
) -> Bool:
    if len(data) - pos < len(pat):
        return False
    var i = 0
    while i < len(pat):
        if data[pos + i] != pat[i]:
            return False
        i += 1
    return True


# Whether data[pos:] starts with the byte pattern pat (string form).
def str_starts_with(data: Span[Byte, _], pos: Int, pat: String) -> Bool:
    return bytes_starts_with(data, pos, pat.as_bytes())


# Parse a non-negative integer (usize semantics: digits only).
def parse_unsigned(s: String) -> Optional[Int]:
    if s.byte_length() == 0:
        return Optional[Int]()
    var n: Int = 0
    for b in s.as_bytes():
        if b < 0x30 or b > 0x39:
            return Optional[Int]()
        n = n * 10 + Int(b - 0x30)
    return Optional[Int](n)


# Encode a codepoint as a UTF-8 string.
def codepoint_to_string(cp: Codepoint) -> String:
    var c = Int(cp.to_u32())
    var buf = Array[Byte, 4](fill=0)
    var n: Int
    if c < 0x80:
        buf[0] = Byte(c)
        n = 1
    elif c < 0x800:
        buf[0] = Byte(0xC0 | (c >> 6))
        buf[1] = Byte(0x80 | (c & 0x3F))
        n = 2
    elif c < 0x10000:
        buf[0] = Byte(0xE0 | (c >> 12))
        buf[1] = Byte(0x80 | ((c >> 6) & 0x3F))
        buf[2] = Byte(0x80 | (c & 0x3F))
        n = 3
    else:
        buf[0] = Byte(0xF0 | (c >> 18))
        buf[1] = Byte(0x80 | ((c >> 12) & 0x3F))
        buf[2] = Byte(0x80 | ((c >> 6) & 0x3F))
        buf[3] = Byte(0x80 | (c & 0x3F))
        n = 4
    var span = Span[Byte](unsafe_ptr=buf.unsafe_ptr(), length=n)
    return String(unsafe_from_utf8=span)
