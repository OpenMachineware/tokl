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
# Output formatting: table (scc style) / markdown / json.
#
# Column order: Language, Files, Tokens, Lines, Blanks, Comments, Code
# (Tokens sits between Files and Lines; no Complexity column).

from std.collections import List

from count import LangAgg
from util import thousands
from version import VERSION

comptime FMT_TABLE = 0
comptime FMT_MARKDOWN = 1
comptime FMT_JSON = 2


def format_from_str(s: String) raises -> Int:
    var t = String(s.strip()).lower()
    if t == "table":
        return FMT_TABLE
    if t == "markdown" or t == "md":
        return FMT_MARKDOWN
    if t == "json":
        return FMT_JSON
    raise Error(
        "unknown output format '{}' (supported: table | markdown | json)"
        .format(t)
    )


def headers() -> List[String]:
    return [
        "Language",
        "Files",
        "Tokens",
        "Lines",
        "Blanks",
        "Comments",
        "Code",
    ]


def cell_values(a: LangAgg) -> List[String]:
    return [
        thousands(a.files),
        thousands(a.tokens),
        thousands(a.lines),
        thousands(a.blanks),
        thousands(a.comments),
        thousands(a.code),
    ]


# Whether a codepoint is zero-width (combining marks, variation
# selectors, zero-width joiners/spaces, directional marks, BOM, ...).
def is_zero_width(cp: Int) -> Bool:
    return (
        (0x0300 <= cp <= 0x036F)
        or (0xFE00 <= cp <= 0xFE0F)
        or (0x200B <= cp <= 0x200F)
        or (0x202A <= cp <= 0x202E)
        or (0x2060 <= cp <= 0x2064)
        or cp == 0x200D
        or cp == 0xFEFF
    )


# Whether a codepoint renders double-width in a terminal (CJK, fullwidth
# forms, emoji / pictographic symbols, ...).
def is_wide(cp: Int) -> Bool:
    if (0xFF00 <= cp <= 0xFF60) or (0xFFE0 <= cp <= 0xFFE6):
        return True
    if (
        (0x1100 <= cp <= 0x115F)
        or (0x2E80 <= cp <= 0x303E)
        or (0x3041 <= cp <= 0x33FF)
        or (0x3400 <= cp <= 0x4DBF)
        or (0x4E00 <= cp <= 0x9FFF)
        or (0xA000 <= cp <= 0xA4CF)
        or (0xAC00 <= cp <= 0xD7A3)
        or (0xF900 <= cp <= 0xFAFF)
        or (0xFE30 <= cp <= 0xFE4F)
        or (0x20000 <= cp <= 0x3FFFD)
    ):
        return True
    if (
        (0x1F000 <= cp <= 0x1FAFF)
        or (0x2600 <= cp <= 0x27BF)
        or (0x2B00 <= cp <= 0x2BFF)
        or (0x1F1E6 <= cp <= 0x1F1FF)
    ):
        return True
    return False


# Terminal display width of a string, in columns. ASCII and most symbols
# count as 1, zero-width characters as 0, wide / fullwidth characters
# (CJK, emoji, ...) as 2. Padding must use this (not byte_length or char
# count) so that names containing emoji (e.g. "🔥Mojo") align with the
# other rows.
def display_width(s: String) -> Int:
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    var w: Int = 0
    while i < n:
        var c = Int(b[i])
        if c < 0x80:
            w += 1
            i += 1
            continue
        var l: Int
        var cp: Int
        if (c >> 5) == 0b110:
            l = 2
            cp = c & 0x1F
        elif (c >> 4) == 0b1110:
            l = 3
            cp = c & 0x0F
        elif (c >> 3) == 0b11110:
            l = 4
            cp = c & 0x07
        else:
            # Invalid lead byte: count as 1 column and move on.
            w += 1
            i += 1
            continue
        if i + l > n:
            l = n - i
        var k = 1
        while k < l:
            cp = (cp << 6) | Int(b[i + k] & 0x3F)
            k += 1
        i += l
        if is_zero_width(cp):
            continue
        if is_wide(cp):
            w += 2
        else:
            w += 1
    return w


def pad_right(s: String, width: Int) -> String:
    var out = String(s)
    var cur = display_width(s)
    while cur < width:
        out += " "
        cur += 1
    return out


def pad_left(s: String, width: Int) -> String:
    var pad = width - display_width(s)
    if pad < 0:
        pad = 0
    var out = String(capacity=pad + s.byte_length())
    var i = 0
    while i < pad:
        out += " "
        i += 1
    out += s
    return out


def dash_line(width: Int) -> String:
    var out = String(capacity=width * 3)
    var i = 0
    while i < width:
        out += "─"
        i += 1
    return out


# Render statistics. model is used for json metadata.
def render(
    rows: List[Tuple[String, LangAgg]],
    ref total: LangAgg,
    fmt: Int,
    model: String,
) -> String:
    if fmt == FMT_TABLE:
        return render_table(rows, total)
    if fmt == FMT_MARKDOWN:
        return render_markdown(rows, total)
    return render_json(rows, total, model)


def render_table(
    rows: List[Tuple[String, LangAgg]], ref total: LangAgg
) -> String:
    var hs = headers()
    var widths = List[Int](length=7, fill=0)
    var i = 0
    while i < 7:
        widths[i] = display_width(hs[i])
        i += 1
    var r = 0
    while r < len(rows):
        var lang = rows[r][0]
        var a = rows[r][1]
        var lw = display_width(lang)
        if lw > widths[0]:
            widths[0] = lw
        var cells = cell_values(a)
        var c = 0
        while c < 6:
            if display_width(cells[c]) > widths[c + 1]:
                widths[c + 1] = display_width(cells[c])
            c += 1
        r += 1
    var tcells = cell_values(total)
    var c2 = 0
    while c2 < 6:
        if display_width(tcells[c2]) > widths[c2 + 1]:
            widths[c2 + 1] = display_width(tcells[c2])
        c2 += 1

    # Column gap of 3 spaces
    var sep_width = 0
    var w = 0
    while w < 7:
        sep_width += widths[w]
        w += 1
    sep_width += 6 * 3
    var sep = dash_line(sep_width)

    var out = String()
    # Header
    var line = pad_right(hs[0], widths[0])
    var i2 = 1
    while i2 < 7:
        line += "   "
        line += pad_left(hs[i2], widths[i2])
        i2 += 1
    out += trim_right(line)
    out += "\n"
    out += sep
    out += "\n"

    var r2 = 0
    while r2 < len(rows):
        var lang2 = rows[r2][0]
        var a2 = rows[r2][1]
        var line2 = pad_right(lang2, widths[0])
        var cells2 = cell_values(a2)
        var c3 = 0
        while c3 < 6:
            line2 += "   "
            line2 += pad_left(cells2[c3], widths[c3 + 1])
            c3 += 1
        out += trim_right(line2)
        out += "\n"
        r2 += 1

    out += sep
    out += "\n"
    var line3 = pad_right("Total", widths[0])
    var cells3 = cell_values(total)
    var c4 = 0
    while c4 < 6:
        line3 += "   "
        line3 += pad_left(cells3[c4], widths[c4 + 1])
        c4 += 1
    out += trim_right(line3)
    out += "\n"
    out += sep
    out += "\n"
    return out


def trim_right(s: String) -> String:
    var b = s.as_bytes()
    var end = len(b)
    while end > 0 and b[end - 1] == 0x20:
        end -= 1
    return String(unsafe_from_utf8=b[0:end])


def render_markdown(
    rows: List[Tuple[String, LangAgg]], ref total: LangAgg
) -> String:
    var hs = headers()
    var out = String()
    var h = 0
    out += "|"
    while h < 7:
        out += " "
        out += hs[h]
        out += " |"
        h += 1
    out += "\n"
    out += "|"
    var h2 = 0
    while h2 < 7:
        out += " --- |"
        h2 += 1
    out += "\n"
    var r = 0
    while r < len(rows):
        var lang = rows[r][0]
        var a = rows[r][1]
        out += "|"
        out += " "
        out += lang
        out += " |"
        var cells = cell_values(a)
        var c = 0
        while c < 6:
            out += " "
            out += cells[c]
            out += " |"
            c += 1
        out += "\n"
        r += 1
    out += "|"
    out += " **Total** |"
    var tcells = cell_values(total)
    var c2 = 0
    while c2 < 6:
        out += " "
        out += tcells[c2]
        out += " |"
        c2 += 1
    out += "\n"
    return out


def render_json(
    rows: List[Tuple[String, LangAgg]], ref total: LangAgg, model: String
) -> String:
    var out = String()
    out += "{\n"
    out += '  "tool": "tokl",\n'
    out += '  "version": {},\n'.format(json_str(VERSION))
    out += '  "model": {},\n'.format(json_str(model))
    out += '  "languages": [\n'
    var r = 0
    while r < len(rows):
        var lang = rows[r][0]
        var a = rows[r][1]
        out += "    {\n"
        out += '      "language": {},\n'.format(json_str(lang))
        out += '      "files": {},\n'.format(a.files)
        out += '      "tokens": {},\n'.format(a.tokens)
        out += '      "lines": {},\n'.format(a.lines)
        out += '      "blanks": {},\n'.format(a.blanks)
        out += '      "comments": {},\n'.format(a.comments)
        out += '      "code": {}\n'.format(a.code)
        out += "    }"
        if r + 1 < len(rows):
            out += ","
        out += "\n"
        r += 1
    out += "  ],\n"
    out += '  "total": {\n'
    out += '    "files": {},\n'.format(total.files)
    out += '    "tokens": {},\n'.format(total.tokens)
    out += '    "lines": {},\n'.format(total.lines)
    out += '    "blanks": {},\n'.format(total.blanks)
    out += '    "comments": {},\n'.format(total.comments)
    out += '    "code": {}\n'.format(total.code)
    out += "  }\n"
    out += "}\n"
    return out


# Render a JSON string literal (with escaping).
def json_str(s: String) -> String:
    var b = s.as_bytes()
    var out = String(capacity=s.byte_length() + 2)
    out += '"'
    var i = 0
    var n = len(b)
    while i < n:
        var c = b[i]
        if c == 0x22:  # "
            out += '\\"'
        elif c == 0x5C:  # backslash
            out += "\\\\"
        elif c == 0x0A:  # \n
            out += "\\n"
        elif c == 0x09:  # \t
            out += "\\t"
        elif c == 0x0D:  # \r
            out += "\\r"
        elif c < 0x20:
            out += "\\u"
            out += hex4(Int(c))
        else:
            # Advance by UTF-8 boundary
            var l = utf8_len(c)
            var end = i + l
            if end > n:
                end = n
            out += String(unsafe_from_utf8=b[i:end])
            i = end
            continue
        i += 1
    out += '"'
    return out


# 4-digit lowercase hex (for \uXXXX escapes).
def hex4(v: Int) -> String:
    var digits = "0123456789abcdef"
    var out = String(capacity=4)
    var i = 0
    while i < 4:
        var d = (v >> Int(12 - i * 4)) & 0xF
        out += digits[byte = d : d + 1]
        i += 1
    return out


def utf8_len(b: Byte) -> Int:
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
