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
# Minimal TOML parser - only the subset used by tokl config files:
# top-level key-value pairs: `key = "string"`, `key = ["a", "b", ...]`,
# `key = true/false`, `key = 123`. Supports `#` comments, blank lines and
# multi-line arrays (each item on its own line). No inline / nested tables.

from std.collections import List, Optional

# Value kinds
comptime TOML_STR = 0
comptime TOML_BOOL = 1
comptime TOML_INT = 2
comptime TOML_STR_ARRAY = 3


struct TomlValue(Copyable, Defaultable):
    var kind: Int
    var s: String
    var b: Bool
    var i: Int
    var arr: List[String]

    def __init__(out self):
        self.kind = TOML_STR
        self.s = ""
        self.b = False
        self.i = 0
        self.arr = List[String]()

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind
        self.s = copy.s
        self.b = copy.b
        self.i = copy.i
        self.arr = List[String](copy=copy.arr)


struct MiniToml(Movable):
    var entries: List[Tuple[String, TomlValue]]

    def __init__(out self):
        self.entries = List[Tuple[String, TomlValue]]()

    # Parse TOML text into top-level entries.
    @staticmethod
    def parse(text: String) raises -> MiniToml:
        var toml = MiniToml()
        # A multi-line array still being collected: (key, accumulated text).
        var pending_key: Optional[String] = Optional[String]()
        var pending_acc: String = ""

        var lines = text.split("\n")
        var lineno = 0
        for raw0 in lines:
            # Rust str::lines also strips a trailing \r (CRLF)
            var rawbs = raw0.as_bytes()
            var rawlen = len(rawbs)
            if rawlen > 0 and rawbs[rawlen - 1] == 0x0D:
                rawlen -= 1
            var raw = String(unsafe_from_utf8=rawbs[0:rawlen])
            var line = String(strip_comment(raw).strip())
            if pending_key is not None:
                if line != "":
                    pending_acc += "\n"
                    pending_acc += line
                if array_is_closed(pending_acc):
                    var key = pending_key.value()
                    var value = parse_value(pending_acc, lineno + 1)
                    toml.entries.append((key, value^))
                    pending_key = Optional[String]()
                    pending_acc = ""
                lineno += 1
                continue
            if line == "":
                lineno += 1
                continue
            var eq = line.find("=")
            if eq < 0:
                raise Error(
                    "line {}: missing '=': {}".format(
                        lineno + 1, String(raw.strip())
                    )
                )
            var key = String(line[byte=0:eq].strip())
            var val = String(line[byte = eq + 1 :].strip())
            if key == "" or val == "":
                raise Error("line {}: missing key or value".format(lineno + 1))
            if val.find("[") == 0 and not array_is_closed(val):
                # Start of a multi-line array; keep collecting following lines.
                pending_key = Optional[String](key)
                pending_acc = val
                lineno += 1
                continue
            var value2 = parse_value(val, lineno + 1)
            toml.entries.append((key, value2^))
            lineno += 1
        if pending_key is not None:
            raise Error(
                "array for key '{}' is missing ']'".format(pending_key.value())
            )
        return toml^

    def get_str(self, key: String) -> Optional[String]:
        for e in self.entries:
            if e[0] == key:
                if e[1].kind == TOML_STR:
                    return Optional[String](e[1].s)
                return Optional[String]()
        return Optional[String]()

    def get_str_array(self, key: String) -> Optional[List[String]]:
        for e in self.entries:
            if e[0] == key:
                if e[1].kind == TOML_STR_ARRAY:
                    return Optional[List[String]](e[1].arr.copy())
                return Optional[List[String]]()
        return Optional[List[String]]()


# Strip only '#' outside strings.
def strip_comment(line: String) -> String:
    var in_str = False
    var escape = False
    var i = 0
    var n = line.byte_length()
    while i < n:
        var b = line.as_bytes()[i]
        if in_str:
            if escape:
                escape = False
            elif b == 0x5C:  # backslash
                escape = True
            elif b == 0x22:  # '"'
                in_str = False
        elif b == 0x22:
            in_str = True
        elif b == 0x23:  # '#'
            return String(line[byte=0:i])
        i += 1
    return line


# Return true when the text contains a closing ']' outside of a quoted string.
def array_is_closed(s: String) -> Bool:
    var in_str = False
    var escape = False
    for b in s.as_bytes():
        if in_str:
            if escape:
                escape = False
            elif b == 0x5C:
                escape = True
            elif b == 0x22:
                in_str = False
        elif b == 0x22:
            in_str = True
        elif b == 0x5D:  # ']'
            return True
    return False


def parse_value(raw0: String, lineno: Int) raises -> TomlValue:
    var raw = String(raw0.strip())
    if raw.find("[") == 0:
        if raw.rfind("]") != raw.byte_length() - 1:
            raise Error("line {}: array missing ']'".format(lineno))
        var inner = String(raw[byte = 1 : raw.byte_length() - 1])
        var arr = List[String]()
        var items = inner.split(",")
        for item0 in items:
            var item = String(item0.strip())
            if item == "":
                continue
            if item.find('"') != 0 or item.rfind('"') != item.byte_length() - 1:
                raise Error(
                    "line {}: array items must be strings: {}".format(
                        lineno, item
                    )
                )
            var s = String(item[byte = 1 : item.byte_length() - 1])
            arr.append(unquote(s))
        var v = TomlValue()
        v.kind = TOML_STR_ARRAY
        v.arr = arr^
        return v^
    if raw.find('"') == 0:
        if raw.rfind('"') != raw.byte_length() - 1:
            raise Error("line {}: string missing closing quote".format(lineno))
        var v2 = TomlValue()
        v2.kind = TOML_STR
        v2.s = unquote(String(raw[byte = 1 : raw.byte_length() - 1]))
        return v2^
    if raw == "true":
        var v3 = TomlValue()
        v3.kind = TOML_BOOL
        v3.b = True
        return v3^
    if raw == "false":
        var v4 = TomlValue()
        v4.kind = TOML_BOOL
        v4.b = False
        return v4^
    try:
        var i = Int(raw)
        var v5 = TomlValue()
        v5.kind = TOML_INT
        v5.i = i
        return v5^
    except e:
        pass
    raise Error("line {}: unrecognized value: {}".format(lineno, raw))


# Handle \n \t \" \\ escapes.
def unquote(s: String) -> String:
    var out = String(capacity=s.byte_length())
    var bs = s.as_bytes()
    var i = 0
    var n = len(bs)
    while i < n:
        var b = bs[i]
        if b == 0x5C and i + 1 < n:
            var c = bs[i + 1]
            if c == 0x6E:  # n
                out += "\n"
            elif c == 0x74:  # t
                out += "\t"
            elif c == 0x22:  # "
                out += '"'
            elif c == 0x5C:  # backslash
                out += "\\"
            else:
                out += "\\"
                out += String(unsafe_from_utf8=bs[i + 1 : i + 2])
            i += 2
        else:
            # Advance by UTF-8 boundary
            var l = utf8_seq_len(b)
            var end = min(i + l, n)
            out += String(unsafe_from_utf8=bs[i:end])
            i = end
    return out


def utf8_seq_len(b: UInt8) -> Int:
    if b < 0x80:
        return 1
    elif (b >> 5) == 0b110:
        return 2
    elif (b >> 4) == 0b1110:
        return 3
    elif (b >> 3) == 0b11110:
        return 4
    else:
        return 1
