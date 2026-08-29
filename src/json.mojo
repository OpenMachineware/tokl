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
# Minimal JSON parser (used to read HuggingFace tokenizer.json / vocab.json).
# Not a full standard implementation; valid input only.
#
# Values are stored in a flat arena (no recursive types): child values of an
# array/object are consecutive entries in `doc.values` starting at
# `first_child`, with `child_count` children.

from std.collections import List, Optional

from util import codepoint_to_string

# Value kinds
comptime JV_NULL = 0
comptime JV_BOOL = 1
comptime JV_NUM = 2
comptime JV_STR = 3
comptime JV_ARR = 4
comptime JV_OBJ = 5


struct JsonValue(Defaultable, ImplicitlyCopyable):
    var kind: Int
    var b: Bool
    var num: Float64
    var s: String
    var children: List[Int]  # direct child indices, in order
    var keys: List[String]  # for JV_OBJ: key of each child (in order)

    def __init__(out self):
        self.kind = JV_NULL
        self.b = False
        self.num = 0.0
        self.s = ""
        self.children = List[Int]()
        self.keys = List[String]()

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind
        self.b = copy.b
        self.num = copy.num
        self.s = copy.s
        self.children = List[Int](copy=copy.children)
        self.keys = List[String](copy=copy.keys)


struct JsonDoc(Copyable):
    var values: List[JsonValue]

    def __init__(out self):
        self.values = List[JsonValue]()

    def __init__(out self, *, copy: Self):
        self.values = List[JsonValue](copy=copy.values)

    # Index of `key` among the children of object `idx`, or None.
    def get_idx(self, idx: Int, key: String) -> Optional[Int]:
        if self.values[idx].kind != JV_OBJ:
            return Optional[Int]()
        for i, k in enumerate(self.values[idx].keys):
            if k == key:
                return Optional[Int](self.values[idx].children[i])
        return Optional[Int]()

    def as_num(self, idx: Int) -> Optional[Float64]:
        if self.values[idx].kind == JV_NUM:
            return Optional[Float64](self.values[idx].num)
        return Optional[Float64]()


def json_parse(input: String) raises -> JsonDoc:
    var p = JsonParser(doc=JsonDoc(), pos=0, text=input)
    p.skip_ws()
    var root = p.parse_value()
    p.skip_ws()
    if p.pos != p.text.byte_length():
        raise Error("trailing content after JSON (position {})".format(p.pos))
    return p.doc.copy()


struct JsonParser(Movable):
    var doc: JsonDoc
    var text: String
    var pos: Int

    def __init__(out self, var doc: JsonDoc, pos: Int, var text: String):
        self.doc = doc^
        self.text = text
        self.pos = pos

    def new_value(mut self, kind: Int) -> Int:
        var v = JsonValue()
        v.kind = kind
        self.doc.values.append(v)
        return len(self.doc.values) - 1

    def skip_ws(mut self):
        while self.pos < self.text.byte_length():
            var b = self.text.as_bytes()[self.pos]
            if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D:
                self.pos += 1
            else:
                break

    def peek(self) -> Optional[UInt8]:
        if self.pos < self.text.byte_length():
            return Optional[UInt8](self.text.as_bytes()[self.pos])
        return Optional[UInt8]()

    def parse_value(mut self) raises -> Int:
        self.skip_ws()
        var pk = self.peek()
        if pk is None:
            raise Error("unexpected end of JSON")
        var c = pk.value()
        if c == 0x7B:  # {
            return self.parse_obj()
        if c == 0x5B:  # [
            return self.parse_arr()
        if c == 0x22:  # "
            var idx = self.new_value(JV_STR)
            self.doc.values[idx].s = self.parse_string()
            return idx
        if c == 0x74:  # t
            self.parse_lit("true")
            var i2 = self.new_value(JV_BOOL)
            self.doc.values[i2].b = True
            return i2
        if c == 0x66:  # f
            self.parse_lit("false")
            var i3 = self.new_value(JV_BOOL)
            self.doc.values[i3].b = False
            return i3
        if c == 0x6E:  # n
            self.parse_lit("null")
            return self.new_value(JV_NULL)
        if c == 0x2D or (c >= 0x30 and c <= 0x39):  # - or digit
            return self.parse_num()
        raise Error(
            "unexpected JSON character: {} (position {})".format(c, self.pos)
        )

    def parse_lit(mut self, lit: String) raises:
        var lb = lit.as_bytes()
        if self.text.byte_length() < self.pos + len(lb):
            raise Error(
                "unexpected JSON content (position {})".format(self.pos)
            )
        var i = 0
        while i < len(lb):
            if self.text.as_bytes()[self.pos + i] != lb[i]:
                raise Error(
                    "unexpected JSON content (position {})".format(self.pos)
                )
            i += 1
        self.pos += len(lb)

    def parse_num(mut self) raises -> Int:
        var start = self.pos
        while self.pos < self.text.byte_length():
            var b = self.text.as_bytes()[self.pos]
            if (
                (b >= 0x30 and b <= 0x39)
                or b == 0x2D
                or b == 0x2B
                or b == 0x2E
                or b == 0x65
                or b == 0x45
            ):
                self.pos += 1
            else:
                break
        var s = String(unsafe_from_utf8=self.text.as_bytes()[start : self.pos])
        var idx = self.new_value(JV_NUM)
        try:
            self.doc.values[idx].num = Float64(s)
        except e:
            raise Error("invalid number: {}".format(s))
        return idx

    def parse_string(mut self) raises -> String:
        if self.peek() is None or self.peek().value() != 0x22:
            raise Error("expected string")
        self.pos += 1
        var out = String()
        while True:
            var pk = self.peek()
            if pk is None:
                raise Error("unterminated string")
            var b = pk.value()
            if b == 0x22:  # "
                self.pos += 1
                return out
            if b == 0x5C:  # backslash
                self.pos += 1
                var ek = self.peek()
                if ek is None:
                    raise Error("incomplete escape")
                var esc = ek.value()
                self.pos += 1
                if esc == 0x22:
                    out += '"'
                elif esc == 0x5C:
                    out += "\\"
                elif esc == 0x2F:
                    out += "/"
                elif esc == 0x62:
                    out += "\b"
                elif esc == 0x66:
                    out += "\f"
                elif esc == 0x6E:
                    out += "\n"
                elif esc == 0x72:
                    out += "\r"
                elif esc == 0x74:
                    out += "\t"
                elif esc == 0x75:  # u
                    if self.pos + 4 > self.text.byte_length():
                        raise Error("incomplete \\u escape")
                    var hexs = String(
                        unsafe_from_utf8=self.text.as_bytes()[
                            self.pos : self.pos + 4
                        ]
                    )
                    var code: UInt32 = 0
                    var j = 0
                    while j < 4:
                        var hb = hexs.as_bytes()[j]
                        var d: UInt32
                        if hb >= 0x30 and hb <= 0x39:
                            d = UInt32(hb - 0x30)
                        elif hb >= 0x41 and hb <= 0x46:
                            d = UInt32(hb - 0x41 + 10)
                        elif hb >= 0x61 and hb <= 0x66:
                            d = UInt32(hb - 0x61 + 10)
                        else:
                            raise Error("invalid \\u code point")
                        code = code * 16 + d
                        j += 1
                    self.pos += 4
                    var cp = Codepoint.from_u32(code)
                    if cp is not None:
                        out += codepoint_to_string(cp.value())
                    else:
                        out += "\ufffd"
                else:
                    raise Error("invalid escape: \\{}".format(esc))
            else:
                # Advance by UTF-8 boundary
                var l = utf8_seq_len(b)
                var end = min(self.pos + l, self.text.byte_length())
                out += String(
                    unsafe_from_utf8=self.text.as_bytes()[self.pos : end]
                )
                self.pos = end

    def parse_arr(mut self) raises -> Int:
        self.pos += 1  # [
        var idx = self.new_value(JV_ARR)
        while True:
            self.skip_ws()
            var pk = self.peek()
            if pk is None:
                raise Error("unterminated array")
            var b = pk.value()
            if b == 0x5D:  # ]
                self.pos += 1
                break
            if b == 0x2C:  # ,
                self.pos += 1
                continue
            var child = self.parse_value()
            self.doc.values[idx].children.append(child)
        return idx

    def parse_obj(mut self) raises -> Int:
        self.pos += 1  # {
        var idx = self.new_value(JV_OBJ)
        while True:
            self.skip_ws()
            var pk = self.peek()
            if pk is None:
                raise Error("unterminated object")
            var b = pk.value()
            if b == 0x7D:  # }
                self.pos += 1
                break
            if b == 0x2C:  # ,
                self.pos += 1
                continue
            if b == 0x22:  # "
                var key = self.parse_string()
                self.skip_ws()
                var ck = self.peek()
                if ck is None or ck.value() != 0x3A:  # :
                    raise Error("object missing ':'")
                self.pos += 1
                var child = self.parse_value()
                self.doc.values[idx].children.append(child)
                self.doc.values[idx].keys.append(key)
            else:
                raise Error(
                    "unexpected object character: {} (position {})".format(
                        b, self.pos
                    )
                )
        return idx


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
