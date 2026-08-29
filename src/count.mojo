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
# Line counting: use language syntax (comment/string markers) to count
# total / blank / comment / code lines.
#
# Classification rules (following scc/tokei):
# - Lines   : total lines in the file
# - Blanks  : lines with no non-whitespace characters
# - Comments: non-blank lines entirely inside a comment (start with a
#             comment marker, or lie within a block comment)
# - Code    : all other non-blank lines (including mixed
#             "code + trailing comment" lines)
# - Tokens  : provided by the tokenizer module

from std.collections import List, Optional

from language import LangSpec, RAW_CPP, RAW_RUST
from util import str_starts_with


# Aggregated statistics for one language.
struct LangAgg(ImplicitlyCopyable):
    var files: UInt64
    var lines: UInt64
    var blanks: UInt64
    var comments: UInt64
    var code: UInt64
    var tokens: UInt64

    def __init__(out self):
        self.files = 0
        self.lines = 0
        self.blanks = 0
        self.comments = 0
        self.code = 0
        self.tokens = 0

    def add(mut self, o: LangAgg):
        self.files += o.files
        self.lines += o.lines
        self.blanks += o.blanks
        self.comments += o.comments
        self.code += o.code
        self.tokens += o.tokens


# Statistics for a single file.
struct FileCount(ImplicitlyCopyable):
    var lines: UInt64
    var blanks: UInt64
    var comments: UInt64
    var code: UInt64
    var tokens: UInt64

    def __init__(out self, tokens: UInt64):
        self.lines = 0
        self.blanks = 0
        self.comments = 0
        self.code = 0
        self.tokens = tokens


def is_ascii_ws(b: UInt8) -> Bool:
    return (
        b == 0x20
        or b == 0x09
        or b == 0x0A
        or b == 0x0D
        or b == 0x0C
        or b == 0x0B
    )


def list_starts_with(
    data: Span[Byte, _], pos: Int, ref pat: List[UInt8]
) -> Bool:
    if len(data) - pos < len(pat):
        return False
    var i = 0
    while i < len(pat):
        if data[pos + i] != pat[i]:
            return False
        i += 1
    return True


# Compute raw string start length (Rust: r#", C++: R"). Returns 0 when none.
# `line` is data[line_start .. line_start + line_len).
def raw_start_len(
    ref syntax: LangSpec, line: Span[Byte, _], pos: Int, line_len: Int
) -> Int:
    if syntax.raw == RAW_CPP:
        if str_starts_with(line, pos, 'R"'):
            return 2
        return 0
    if syntax.raw == RAW_RUST:
        if line[pos] != 0x72:  # 'r'
            return 0
        var i = pos + 1
        while i < pos + line_len and line[i] == 0x23:  # '#'
            i += 1
        if i < pos + line_len and line[i] == 0x22:  # '"'
            return i - pos + 1
        return 0
    return 0


# Bytes that can start a string / comment / raw marker in the normal
# state; any other byte is an ordinary character (fast path).
def interesting_mask(ref syntax: LangSpec) -> Array[Bool, 256]:
    var m = Array[Bool, 256](fill=False)
    var si = 0
    while si < len(syntax.strings):
        m[Int(syntax.strings[si].start.as_bytes()[0])] = True
        si += 1
    var ci = 0
    while ci < len(syntax.line_comments):
        m[Int(syntax.line_comments[ci].as_bytes()[0])] = True
        ci += 1
    var ci2 = 0
    while ci2 < len(syntax.line_comments_bol):
        m[Int(syntax.line_comments_bol[ci2].as_bytes()[0])] = True
        ci2 += 1
    var bi = 0
    while bi < len(syntax.block_comments):
        m[Int(syntax.block_comments[bi][0].as_bytes()[0])] = True
        bi += 1
    if syntax.raw == RAW_CPP:
        m[0x52] = True  # 'R'
    elif syntax.raw == RAW_RUST:
        m[0x72] = True  # 'r'
    return m^


# Count lines of file byte content; tokens is supplied by the caller.
def count_file(
    data: List[UInt8], ref syntax: LangSpec, tokens: UInt64
) -> FileCount:
    var fc = FileCount(tokens)
    var interesting = interesting_mask(syntax)

    # Cross-line state
    var block_depth: Int = 0
    var in_string: Int = -1  # string spec index
    var raw_end: Optional[List[UInt8]] = Optional[
        List[UInt8]
    ]()  # C++ raw end seq
    var raw_hashes: Int = 0  # number of # in Rust raw

    var n = len(data)
    var start = 0
    while start <= n:
        var idx = start
        var found_nl = False
        while idx < n:
            if data[idx] == 0x0A:
                found_nl = True
                break
            idx += 1
        var end: Int
        var is_last: Bool
        if found_nl:
            end = idx
            is_last = False
        else:
            end = n
            is_last = True

        # A trailing \n makes split yield an empty segment; ignore it
        if end == start and is_last:
            break

        fc.lines += 1

        # A line that is entirely blank still belongs to an open
        # cross-line string / raw string / block comment:
        #   - inside a string or raw string  -> counts as code
        #   - inside a block comment         -> counts as comment
        var seen_code = in_string >= 0 or raw_hashes > 0 or raw_end is not None
        var seen_comment = block_depth > 0
        var has_nonblank = seen_code or seen_comment
        var pos: Int = 0
        # The line is data[start .. end); work with offsets into `data`
        # directly instead of copying each line.
        var lend = end - start

        while pos < lend:
            # 1) String content
            if in_string >= 0:
                var spec = syntax.strings[in_string]
                if spec.escape:
                    if data[start + pos] == 0x5C:  # backslash
                        pos += 2
                        continue
                if str_starts_with(data, start + pos, spec.end):
                    in_string = -1
                    pos += spec.end.byte_length()
                    continue
                pos += 1
                seen_code = True
                has_nonblank = True
                continue
            # 2) C++ raw string content
            if raw_end is not None:
                if list_starts_with(data, start + pos, raw_end.value()):
                    var rlen = len(raw_end.value())
                    raw_end = Optional[List[UInt8]]()
                    pos += rlen
                    continue
                pos += 1
                seen_code = True
                has_nonblank = True
                continue
            # 3) Rust raw string content
            if raw_hashes > 0:
                var nh = raw_hashes
                if data[start + pos] == 0x22 and lend >= pos + 1 + nh:
                    var all_hash = True
                    var k = 0
                    while k < nh:
                        if data[start + pos + 1 + k] != 0x23:
                            all_hash = False
                            break
                        k += 1
                    if all_hash:
                        raw_hashes = 0
                        pos += 1 + nh
                        continue
                pos += 1
                seen_code = True
                has_nonblank = True
                continue
            # 4) Block comment content
            if block_depth > 0:
                seen_comment = True
                has_nonblank = True
                var matched = False
                if syntax.nestable:
                    var bi = 0
                    while bi < len(syntax.block_comments):
                        var bc = syntax.block_comments[bi]
                        if str_starts_with(data, start + pos, bc[0]):
                            block_depth += 1
                            pos += bc[0].byte_length()
                            matched = True
                            break
                        bi += 1
                    if matched:
                        continue
                var bi2 = 0
                while bi2 < len(syntax.block_comments):
                    var bc2 = syntax.block_comments[bi2]
                    if str_starts_with(data, start + pos, bc2[1]):
                        block_depth -= 1
                        pos += bc2[1].byte_length()
                        matched = True
                        break
                    bi2 += 1
                if not matched:
                    pos += 1
                continue
            # 5) Normal state
            var b = data[start + pos]

            # Fast path: the byte cannot start any marker.
            if not interesting[Int(b)]:
                if not is_ascii_ws(b):
                    seen_code = True
                    has_nonblank = True
                pos += 1
                continue

            # 5a) raw string start
            var slen = raw_start_len(syntax, data, start + pos, lend)
            if slen > 0:
                if syntax.raw == RAW_CPP:
                    # R"DELIM( ... )DELIM" - same line required
                    var after_start = pos + 2
                    var paren = -1
                    var j = after_start
                    while j < lend:
                        if data[start + j] == 0x28:  # '('
                            paren = j
                            break
                        j += 1
                    if paren >= 0:
                        var end_seq2 = List[UInt8](
                            capacity=paren - after_start + 2
                        )
                        end_seq2.append(0x29)  # ')'
                        var k2 = after_start
                        while k2 < paren:
                            end_seq2.append(data[start + k2])
                            k2 += 1
                        end_seq2.append(0x22)  # '"'
                        raw_end = Optional[List[UInt8]](end_seq2^)
                        pos += (
                            2 + (paren - after_start) + 1
                        )  # skip past R"DELIM(
                        seen_code = True
                        has_nonblank = True
                        continue
                    # Unparseable R" (may be an ordinary string);
                    # fall back to ordinary characters
                    pos += slen
                    seen_code = True
                    has_nonblank = True
                    continue
                if syntax.raw == RAW_RUST:
                    # r#"..."#
                    var hashes = 0
                    while (
                        pos + 1 + hashes < lend
                        and data[start + pos + 1 + hashes] == 0x23
                    ):
                        hashes += 1
                    if (
                        pos + 1 + hashes < lend
                        and data[start + pos + 1 + hashes] == 0x22
                    ):
                        raw_hashes = hashes
                        pos += 2 + hashes  # skip past r#"
                        seen_code = True
                        has_nonblank = True
                        continue
                    pos += 1
                    seen_code = True
                    has_nonblank = True
                    continue
                # RawKind::None
                pos += 1
                continue

            # 5b) string start (longest delimiter first)
            var best: Int = -1
            var bi3 = 0
            while bi3 < len(syntax.strings):
                var spec2 = syntax.strings[bi3]
                if str_starts_with(data, start + pos, spec2.start):
                    if (
                        best < 0
                        or syntax.strings[best].start.byte_length()
                        < spec2.start.byte_length()
                    ):
                        best = bi3
                bi3 += 1
            if best >= 0:
                var spec3 = syntax.strings[best]
                in_string = best
                seen_code = True
                has_nonblank = True
                pos += spec3.start.byte_length()
                # Immediately closed empty string "" / ''
                if spec3.start == spec3.end and str_starts_with(
                    data, start + pos, spec3.end
                ):
                    in_string = -1
                    pos += spec3.end.byte_length()
                continue

            # 5c) block comment start
            var matched2 = False
            var bi4 = 0
            while bi4 < len(syntax.block_comments):
                var bc3 = syntax.block_comments[bi4]
                if str_starts_with(data, start + pos, bc3[0]):
                    block_depth = 1
                    seen_comment = True
                    has_nonblank = True
                    pos += bc3[0].byte_length()
                    matched2 = True
                    break
                bi4 += 1
            if matched2:
                continue

            # 5d) line comment start
            var matched3 = False
            var li = 0
            while li < len(syntax.line_comments):
                if str_starts_with(data, start + pos, syntax.line_comments[li]):
                    seen_comment = True
                    has_nonblank = True
                    matched3 = True
                    break
                li += 1
            if matched3:
                break

            # 5e) comment markers valid at line start (nothing before)
            if not seen_code and not has_nonblank and not seen_comment:
                var li2 = 0
                while li2 < len(syntax.line_comments_bol):
                    if str_starts_with(
                        data, start + pos, syntax.line_comments_bol[li2]
                    ):
                        seen_comment = True
                        has_nonblank = True
                        matched3 = True
                        break
                    li2 += 1
                if matched3:
                    break

            # 5f) ordinary character
            if not is_ascii_ws(b):
                seen_code = True
                has_nonblank = True
            pos += 1

        # End of line: force-close a single-line string still open
        if in_string >= 0:
            if not syntax.strings[in_string].multiline:
                in_string = -1

        if not has_nonblank:
            fc.blanks += 1
        elif seen_code:
            fc.code += 1
        else:
            fc.comments += 1

        if is_last:
            break
        start = end + 1

    return fc


def row_before(a: Tuple[String, LangAgg], b: Tuple[String, LangAgg]) -> Bool:
    if a[1].code != b[1].code:
        return a[1].code > b[1].code
    if a[1].files != b[1].files:
        return a[1].files > b[1].files
    return a[0] < b[0]


# Aggregate per-file counts, sorted by code lines descending
# (largest first), then by file count descending, then by language name.
def aggregate(
    files: List[Tuple[String, FileCount]]
) -> List[Tuple[String, LangAgg]]:
    # Group by language name (insertion-ordered map via parallel lists).
    var names = List[String]()
    var aggs = List[LangAgg]()
    var i = 0
    while i < len(files):
        var lang = files[i][0]
        var fc = files[i][1]
        var found = -1
        var j = 0
        while j < len(names):
            if names[j] == lang:
                found = j
                break
            j += 1
        if found < 0:
            var a = LangAgg()
            a.files = 1
            a.lines = fc.lines
            a.blanks = fc.blanks
            a.comments = fc.comments
            a.code = fc.code
            a.tokens = fc.tokens
            names.append(lang)
            aggs.append(a)
        else:
            var a2 = aggs[found]
            a2.files += 1
            a2.lines += fc.lines
            a2.blanks += fc.blanks
            a2.comments += fc.comments
            a2.code += fc.code
            a2.tokens += fc.tokens
            aggs[found] = a2
        i += 1

    var rows = List[Tuple[String, LangAgg]]()
    var r = 0
    while r < len(names):
        rows.append((names[r], aggs[r]))
        r += 1

    # Insertion sort by (code desc, files desc, name asc)
    var n = len(rows)
    var s = 1
    while s < n:
        var key = rows[s]
        var t = s - 1
        while t >= 0 and row_before(key, rows[t]):
            rows[t + 1] = rows[t]
            t -= 1
        rows[t + 1] = key
        s += 1
    return rows^
