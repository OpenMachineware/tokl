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
# Version-control integration: detect whether the scan roots live inside
# a git / svn / hg / bzr / fossil repository and apply the repository's
# ignore rules (`.gitignore` etc.) on top of the `-i` / config ignores.
#
# Matching follows the gitignore specification (a superset used by most
# tools): blank lines and `#` comments are skipped, `!` negates, a
# trailing `/` restricts to directories, patterns containing `/` are
# anchored to the ignore file's directory, and `*` / `?` / `[...]` /
# `**` globs are supported. Mercurial's `.hgignore` defaults to regular
# expressions, which are not implemented; only its `syntax: glob` rules
# are honored.
#
# Performance notes (vs. the naive per-file re-evaluation):
# - Glob units are compiled once per pattern at load time.
# - Literal patterns (no wildcards) match by plain string equality.
# - The match state of a directory (which patterns matched it or an
#   ancestor) is derived incrementally while the scanner walks down, so
#   a file only has to be checked against patterns that come *after*
#   the last one that already matched an ancestor.

from std.collections import List, Optional
from std.os.path import exists, is_absolute, isfile, join
from std.pathlib import Path, cwd as cwd_path
from util import codepoint_to_string

# VCS kinds
comptime VCS_GIT = 0
comptime VCS_SVN = 1
comptime VCS_HG = 2
comptime VCS_BZR = 3
comptime VCS_FOSSIL = 4


def vcs_markers(kind: Int) -> List[String]:
    if kind == VCS_GIT:
        return [".git"]
    if kind == VCS_SVN:
        return [".svn"]
    if kind == VCS_HG:
        return [".hg"]
    if kind == VCS_BZR:
        return [".bzr"]
    return [".fslckout", ".fossil-settings"]


def vcs_ignore_files(kind: Int) -> List[String]:
    if kind == VCS_GIT:
        return [".gitignore"]
    if kind == VCS_SVN:
        return [".svnignore"]
    if kind == VCS_HG:
        return [".hgignore"]
    if kind == VCS_BZR:
        return [".bzrignore"]
    return [".ignore"]


# Glob units
comptime UNIT_LIT = 0
comptime UNIT_ANY = 1
comptime UNIT_STAR = 2
comptime UNIT_CLASS = 3


struct Unit(Copyable):
    var kind: Int
    var c: UInt8
    var neg: Bool
    var ranges: List[Tuple[UInt8, UInt8]]

    def __init__(out self, kind: Int, c: UInt8, neg: Bool):
        self.kind = kind
        self.c = c
        self.neg = neg
        self.ranges = List[Tuple[UInt8, UInt8]]()

    def __init__(
        out self,
        kind: Int,
        c: UInt8,
        neg: Bool,
        var ranges: List[Tuple[UInt8, UInt8]],
    ):
        self.kind = kind
        self.c = c
        self.neg = neg
        self.ranges = ranges^

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind
        self.c = copy.c
        self.neg = copy.neg
        self.ranges = List[Tuple[UInt8, UInt8]](copy=copy.ranges)


def parse_units(pat: String) -> List[Unit]:
    var b = pat.as_bytes()
    var units = List[Unit]()
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == 0x2A:  # *
            units.append(Unit(UNIT_STAR, 0, False))
            i += 1
        elif c == 0x3F:  # ?
            units.append(Unit(UNIT_ANY, 0, False))
            i += 1
        elif c == 0x5B:  # [
            var j = i + 1
            var neg = False
            if j < len(b) and (b[j] == 0x21 or b[j] == 0x5E):
                neg = True
                j += 1
            var ranges = List[Tuple[UInt8, UInt8]]()
            var first = True
            while j < len(b):
                if b[j] == 0x5D and not first:
                    break
                first = False
                if j + 2 < len(b) and b[j + 1] == 0x2D and b[j + 2] != 0x5D:
                    ranges.append((b[j], b[j + 2]))
                    j += 3
                else:
                    ranges.append((b[j], b[j]))
                    j += 1
            if j < len(b) and b[j] == 0x5D:
                units.append(Unit(UNIT_CLASS, 0, neg, ranges^))
                i = j + 1
            else:
                units.append(Unit(UNIT_LIT, 0x5B, False))
                i += 1
        else:
            units.append(Unit(UNIT_LIT, c, False))
            i += 1
    return units^


# Whether precompiled units match `text` (a single path segment, no `/`).
# Fast paths cover the common gitignore shapes: all-literal, `*suffix`,
# and `prefix*`; anything else falls back to the DP matcher.
def units_match(ref units: List[Unit], text: String) -> Bool:
    var t = text.as_bytes()
    var tl = len(t)
    var n = len(units)
    # Fast path: all literal units -> byte equality.
    var i = 0
    while i < n:
        if units[i].kind != UNIT_LIT:
            break
        i += 1
    if i == n:
        if tl != n:
            return False
        var j = 0
        while j < tl:
            if t[j] != units[j].c:
                return False
            j += 1
        return True
    # Fast path: "*suffix" (leading star, then literals only).
    if units[0].kind == UNIT_STAR:
        var k = 1
        while k < n and units[k].kind == UNIT_LIT:
            k += 1
        if k == n:
            if tl < n - 1:
                return False
            var j2 = 0
            while j2 < n - 1:
                if t[tl - (n - 1) + j2] != units[1 + j2].c:
                    return False
                j2 += 1
            return True
    # Fast path: "prefix*" (literals only, then trailing star).
    if units[n - 1].kind == UNIT_STAR:
        var k2 = n - 2
        while k2 >= 0 and units[k2].kind == UNIT_LIT:
            k2 -= 1
        if k2 < 0:
            var j3 = 0
            while j3 < n - 1:
                if t[j3] != units[j3].c:
                    return False
                j3 += 1
            return True
    # General DP over the units.
    var prev = List[Bool](length=tl + 1, fill=False)
    prev[0] = True
    var ui = 0
    while ui < n:
        var cur = List[Bool](length=tl + 1, fill=False)
        if units[ui].kind == UNIT_STAR:
            cur[0] = prev[0]
            var j4 = 1
            while j4 <= tl:
                cur[j4] = prev[j4] or cur[j4 - 1]
                j4 += 1
        elif units[ui].kind == UNIT_ANY:
            var j5 = 1
            while j5 <= tl:
                cur[j5] = prev[j5 - 1]
                j5 += 1
        elif units[ui].kind == UNIT_LIT:
            var j6 = 1
            while j6 <= tl:
                cur[j6] = prev[j6 - 1] and t[j6 - 1] == units[ui].c
                j6 += 1
        else:  # UNIT_CLASS
            var j7 = 1
            while j7 <= tl:
                var c = t[j7 - 1]
                var hit = False
                var ri = 0
                while ri < len(units[ui].ranges):
                    if (
                        c >= units[ui].ranges[ri][0]
                        and c <= units[ui].ranges[ri][1]
                    ):
                        hit = True
                        break
                    ri += 1
                cur[j7] = prev[j7 - 1] and (hit != units[ui].neg)
                j7 += 1
        prev = cur^
        ui += 1
    return prev[tl]


# Whether pattern segment `seg_idx` matches `text` (single segment).
def seg_match(ref pat: IgnorePattern, seg_idx: Int, text: String) -> Bool:
    if text.find("/") >= 0:
        return False
    if pat.is_literal:
        return pat.segs[seg_idx] == text
    return units_match(pat.seg_units[seg_idx], text)


# Whether an anchored pattern matches rel[0..=end] (inclusive); every
# segment of the prefix is matched by its own glob.
def anchored_match_prefix(
    ref pat: IgnorePattern, ref rel: List[String], end: Int
) -> Bool:
    var n = len(pat.segs)
    var m = end + 1
    if n == 0:
        return m == 0
    # Without `**` the segment counts must be equal.
    if not pat.has_starstar and n != m:
        return False
    var w = m + 1
    var dp = List[Bool](length=(n + 1) * w, fill=False)
    dp[0] = True
    var i = 1
    while i <= n:
        var j = 0
        while j <= m:
            if pat.segs[i - 1] == "**":
                dp[i * w + j] = dp[(i - 1) * w + j] or (
                    j > 0 and dp[i * w + j - 1]
                )
            elif j > 0:
                dp[i * w + j] = dp[(i - 1) * w + j - 1] and seg_match(
                    pat, i - 1, rel[j - 1]
                )
            j += 1
        i += 1
    return dp[n * w + m]


# One compiled ignore pattern (a single line of an ignore file).
struct IgnorePattern(Copyable):
    var negated: Bool
    var dir_only: Bool
    var anchored: Bool
    var segs: List[String]
    var seg_units: List[List[Unit]]
    var is_literal: Bool
    var has_starstar: Bool

    def __init__(
        out self,
        negated: Bool,
        dir_only: Bool,
        anchored: Bool,
        var segs: List[String],
    ):
        self.negated = negated
        self.dir_only = dir_only
        self.anchored = anchored
        self.segs = segs^
        self.seg_units = List[List[Unit]]()
        self.is_literal = True
        self.has_starstar = False
        var si = 0
        while si < len(self.segs):
            var s = self.segs[si]
            if s == "**":
                self.has_starstar = True
                self.is_literal = False
            elif s.find("*") >= 0 or s.find("?") >= 0 or s.find("[") >= 0:
                self.is_literal = False
            self.seg_units.append(parse_units(s))
            si += 1

    def __init__(out self, *, copy: Self):
        self.negated = copy.negated
        self.dir_only = copy.dir_only
        self.anchored = copy.anchored
        self.segs = List[String](copy=copy.segs)
        self.seg_units = List[List[Unit]](copy=copy.seg_units)
        self.is_literal = copy.is_literal
        self.has_starstar = copy.has_starstar


# Parse one ignore line into a pattern (None when not a pattern).
def parse_pattern(line: String) -> Optional[IgnorePattern]:
    var text = unescape(line)
    if text == "" or text.find("#") == 0:
        return Optional[IgnorePattern]()
    var negated = False
    var rest = text
    if text.find("!") == 0:
        negated = True
        var tsl = text[byte=1:]
        rest = String(tsl)
    var dir_only = False
    if rest.rfind("/") == rest.byte_length() - 1:
        dir_only = True
        var rsl = rest[byte = 0 : rest.byte_length() - 1]
        var tmp_rest = String(rsl)
        rest = tmp_rest
    if rest == "":
        return Optional[IgnorePattern]()
    var leading_slash = rest.find("/") == 0
    var pat = rest
    while pat.find("/") == 0:
        var psl = pat[byte=1:]
        var tmp_pat = String(psl)
        pat = tmp_pat
    if pat == "":
        return Optional[IgnorePattern]()
    var anchored = leading_slash or pat.find("/") >= 0
    var segs = List[String]()
    var parts = pat.split("/")
    for p in parts:
        segs.append(String(p))
    return Optional[IgnorePattern](
        IgnorePattern(negated, dir_only, anchored, segs^)
    )


# Ignore rules loaded from one ignore file.
struct IgnoreFile(Copyable):
    var base: List[String]
    var patterns: List[IgnorePattern]
    var non_anchored_idx: List[Int]
    var anchored_idx: List[Int]

    def __init__(
        out self, var base: List[String], var patterns: List[IgnorePattern]
    ):
        self.base = base^
        self.patterns = patterns^
        self.non_anchored_idx = List[Int]()
        self.anchored_idx = List[Int]()
        var pi = 0
        while pi < len(self.patterns):
            if self.patterns[pi].anchored:
                self.anchored_idx.append(pi)
            else:
                self.non_anchored_idx.append(pi)
            pi += 1

    def __init__(out self, *, copy: Self):
        self.base = List[String](copy=copy.base)
        self.patterns = List[IgnorePattern](copy=copy.patterns)
        self.non_anchored_idx = List[Int](copy=copy.non_anchored_idx)
        self.anchored_idx = List[Int](copy=copy.anchored_idx)


# Version-control context discovered for the scan roots.
struct VcsContext(Movable):
    var repos: List[Tuple[Int, String]]
    var kinds: List[Int]
    var has_negations: Bool
    var rule_count: Int
    var files: List[IgnoreFile]

    def __init__(out self):
        self.repos = List[Tuple[Int, String]]()
        self.kinds = List[Int]()
        self.has_negations = False
        self.rule_count = 0
        self.files = List[IgnoreFile]()


# Make `p` absolute (relative paths resolve against the current dir).
def abs_path(p: String) -> String:
    if is_absolute(p):
        return p
    var cwd_str: String = "."
    try:
        cwd_str = cwd_path().path
    except e:
        pass
    return join(cwd_str, p)


def is_root_comp(s: String) -> Bool:
    return s == "/" or (
        s.rfind(":") == s.byte_length() - 1 and s.byte_length() <= 3
    )


# Split a path into normalized components, resolving `.` and `..` so that
# paths built from different relative roots compare consistently.
def normalize(path: String) -> List[String]:
    var stack = List[String]()
    var parts = path.split("/")
    var first = True
    for p0 in parts:
        var p = String(p0)
        if p == "":
            if first:
                # RootDir
                stack.clear()
                stack.append("/")
        elif p == ".":
            pass
        elif p == "..":
            if len(stack) == 0:
                stack.append("..")
            else:
                var last = stack[len(stack) - 1]
                if is_root_comp(last):
                    pass
                elif last == "..":
                    stack.append("..")
                else:
                    stack.shrink(len(stack) - 1)
        else:
            stack.append(p)
        first = False
    return stack^


# Reverse `\X` escapes and drop unescaped trailing whitespace.
def unescape(line: String) -> String:
    var b = line.as_bytes()
    var end = len(b)
    while end > 0:
        var ch = b[end - 1]
        if ch == 0x20 or ch == 0x09:
            if end >= 2 and b[end - 2] == 0x5C:
                break
            end -= 1
        else:
            break
    var out = String(capacity=end)
    var i = 0
    while i < end:
        if b[i] == 0x5C and i + 1 < end:
            out += codepoint_to_string(Codepoint(b[i + 1]))
            i += 2
        else:
            out += codepoint_to_string(Codepoint(b[i]))
            i += 1
    return out


# Parse an ignore file into patterns. `.hgignore` only honors `syntax:
# glob` rules (its default regexp syntax is not implemented).
def parse_ignore_file(kind: Int, text: String) -> List[IgnorePattern]:
    var patterns = List[IgnorePattern]()
    if kind == VCS_HG:
        var glob = False
        var lines = text.split("\n")
        for raw0 in lines:
            var line = String(raw0)
            if (
                line.byte_length() > 0
                and line.rfind("\r") == line.byte_length() - 1
            ):
                var lsl = line[byte = 0 : line.byte_length() - 1]
                var tmp_line = String(lsl)
                line = tmp_line
            var t = String(line.strip())
            if t.find("syntax:") == 0:
                glob = t == "syntax: glob"
                continue
            if not glob or t == "" or t.find("#") == 0:
                continue
            var p = parse_pattern(t)
            if p is not None:
                patterns.append(p.take())
    else:
        var lines2 = text.split("\n")
        for raw1 in lines2:
            var line2 = String(raw1)
            if (
                line2.byte_length() > 0
                and line2.rfind("\r") == line2.byte_length() - 1
            ):
                var lsl2 = line2[byte = 0 : line2.byte_length() - 1]
                var tmp_line2 = String(lsl2)
                line2 = tmp_line2
            var p2 = parse_pattern(line2)
            if p2 is not None:
                patterns.append(p2.take())
    return patterns^


# Detect repositories containing any of `scan_roots` and load their
# ignore files. Returns an empty context when nothing is found.
def vcs_detect(scan_roots: List[String]) -> VcsContext:
    var ctx = VcsContext()
    var repos = List[Tuple[Int, String]]()
    var all_kinds = [VCS_GIT, VCS_HG, VCS_SVN, VCS_BZR, VCS_FOSSIL]
    for root in scan_roots:
        var dir = abs_path(root)
        if isfile(dir):
            var d = dir
            dir = String(d[byte = 0 : d.rfind("/") + 1])
            if dir == "":
                dir = "/"
        while True:
            var ki = 0
            while ki < len(all_kinds):
                var kind = all_kinds[ki]
                var hit = False
                for m in vcs_markers(kind):
                    if exists(join(dir, m)):
                        hit = True
                        break
                var known = False
                for r in repos:
                    if r[0] == kind and r[1] == dir:
                        known = True
                        break
                if hit and not known:
                    repos.append((kind, dir))
                ki += 1
            # pop()
            var di = dir.rfind("/")
            if di <= 0:
                break
            var dsl = dir[byte=0:di]
            var tmp_dir = String(dsl)
            dir = tmp_dir
            if dir == "":
                break
    for r in repos:
        var kind = r[0]
        var root = r[1]
        var in_kinds = False
        for k in ctx.kinds:
            if k == kind:
                in_kinds = True
                break
        if not in_kinds:
            ctx.kinds.append(kind)
        for fname in vcs_ignore_files(kind):
            var path = join(root, fname)
            if isfile(path):
                var text: String = ""
                var ok = False
                try:
                    text = Path(path).read_text()
                    ok = True
                except e:
                    pass
                if ok:
                    var patterns = parse_ignore_file(kind, text)
                    ctx.rule_count += len(patterns)
                    ctx.files.append(
                        IgnoreFile(normalize(abs_path(root)), patterns^)
                    )
    for f in ctx.files:
        for p in f.patterns:
            if p.negated:
                ctx.has_negations = True
                break
        if ctx.has_negations:
            break
    return ctx^


# ---------------------------------------------------------------------------
# Incremental match state
# ---------------------------------------------------------------------------
#
# While the scanner walks down a directory tree, the ignore-match state of
# each directory is derived from its parent's, so per-file checks never
# re-evaluate the ancestor prefixes.
#
# For one ignore file, a directory's state is:
#   - `under`: the directory is the ignore file's base or below it
#   - `rel`:   components relative to the base (empty at the base itself)
#   - `last`:  index of the latest pattern that matched this directory or
#              any of its ancestor prefixes (-1 when none matched); every
#              matched prefix is a directory
#
# A file directly below the directory is then decided by `last` plus the
# patterns with a higher index that match the file's own segment only.


struct VcsFileState(Copyable):
    var under: Bool
    var rel: List[String]
    var last: Int

    def __init__(out self):
        self.under = False
        self.rel = List[String]()
        self.last = -1

    def __init__(out self, *, copy: Self):
        self.under = copy.under
        self.rel = List[String](copy=copy.rel)
        self.last = copy.last


# Match state for a directory: one entry per loaded ignore file.
struct VcsDirState(Copyable):
    var per: List[VcsFileState]

    def __init__(out self):
        self.per = List[VcsFileState]()

    def __init__(out self, *, copy: Self):
        self.per = List[VcsFileState](copy=copy.per)


# Whether a pattern matches any prefix of rel, treating every prefix as a
# directory (the state of a directory being scanned).
def pattern_matches_dir_prefixes(
    ref p: IgnorePattern, ref rel: List[String]
) -> Bool:
    if p.anchored:
        var i = 0
        while i < len(rel):
            if anchored_match_prefix(p, rel, i):
                return True
            i += 1
        return False
    # Non-anchored: matches the basename at any depth.
    var i2 = 0
    while i2 < len(rel):
        if seg_match(p, 0, rel[i2]):
            return True
        i2 += 1
    return False


# State of one ignore file for a directory, from its normalized absolute
# components (used for scan roots; descendants derive incrementally).
def file_state_root(ref f: IgnoreFile, ref comps: List[String]) -> VcsFileState:
    var fs = VcsFileState()
    if len(comps) >= len(f.base):
        var prefix_ok = True
        var i = 0
        while i < len(f.base):
            if comps[i] != f.base[i]:
                prefix_ok = False
                break
            i += 1
        if prefix_ok:
            fs.under = True
            var j = len(f.base)
            while j < len(comps):
                fs.rel.append(comps[j])
                j += 1
            var pi = 0
            while pi < len(f.patterns):
                if pattern_matches_dir_prefixes(f.patterns[pi], fs.rel):
                    fs.last = pi
                pi += 1
    return fs^


# State of one ignore file for a child directory (segment `name`),
# derived from its parent's state.
def file_state_descend(
    ref f: IgnoreFile, ref ps: VcsFileState, name: String
) -> VcsFileState:
    var fs = VcsFileState()
    if ps.under:
        fs.under = True
        var ri = 0
        while ri < len(ps.rel):
            fs.rel.append(ps.rel[ri])
            ri += 1
        fs.rel.append(name)
        var last = ps.last
        # Only patterns after `last` can change the outcome; the rest are
        # overridden by the pattern that set `last`.
        var pi = 0
        var na = len(f.non_anchored_idx)
        while pi < na:
            var idx = f.non_anchored_idx[pi]
            if idx > last and seg_match(f.patterns[idx], 0, name):
                last = idx
            pi += 1
        var an = len(f.anchored_idx)
        var ai = 0
        while ai < an:
            var idx2 = f.anchored_idx[ai]
            if idx2 > last and anchored_match_prefix(
                f.patterns[idx2], fs.rel, len(fs.rel) - 1
            ):
                last = idx2
            ai += 1
        fs.last = last
    return fs^


# Build the match state of a directory from its normalized absolute
# components (used for scan roots; descendants derive incrementally).
def vcs_dir_state(ref ctx: VcsContext, ref comps: List[String]) -> VcsDirState:
    var st = VcsDirState()
    var fi = 0
    while fi < len(ctx.files):
        st.per.append(file_state_root(ctx.files[fi], comps))
        fi += 1
    return st^


# Derive the state of a child directory (segment `name`) from its parent's.
def vcs_descend(
    ref ctx: VcsContext, ref parent: VcsDirState, name: String
) -> VcsDirState:
    var st = VcsDirState()
    var fi = 0
    while fi < len(ctx.files):
        st.per.append(file_state_descend(ctx.files[fi], parent.per[fi], name))
        fi += 1
    return st^


# State for the parent directory of a root file, so the file check sees
# the same ancestor context as a file found during the walk.
def vcs_parent_state(ref ctx: VcsContext, root: String) -> VcsDirState:
    var comps = normalize(abs_path(root))
    if len(comps) > 0:
        comps.shrink(len(comps) - 1)
    return vcs_dir_state(ctx, comps)


# Whether a directory with state `st` is ignored by the loaded rules.
def vcs_dir_ignored(ref ctx: VcsContext, ref st: VcsDirState) -> Bool:
    var fi = 0
    while fi < len(ctx.files):
        if (
            st.per[fi].under
            and st.per[fi].last >= 0
            and not ctx.files[fi].patterns[st.per[fi].last].negated
        ):
            return True
        fi += 1
    return False


# Whether a file (basename `name`) below a directory with state `st` is
# ignored by the loaded rules. The last matching pattern (over the file or
# any ancestor) decides, so a later negation can re-include the file.
def vcs_file_ignored(
    ref ctx: VcsContext, ref st: VcsDirState, name: String
) -> Bool:
    var fi = 0
    while fi < len(ctx.files):
        if st.per[fi].under:
            var last = st.per[fi].last
            # Non-anchored patterns: check the file's own segment.
            # (dir_only patterns cannot match a file; ancestor matches
            # are already reflected in `last`.)
            var na = len(ctx.files[fi].non_anchored_idx)
            var pi = 0
            while pi < na:
                var idx = ctx.files[fi].non_anchored_idx[pi]
                if (
                    idx > last
                    and not ctx.files[fi].patterns[idx].dir_only
                    and seg_match(ctx.files[fi].patterns[idx], 0, name)
                ):
                    last = idx
                pi += 1
            # Anchored patterns: check the full rel (dir rel + name).
            var an = len(ctx.files[fi].anchored_idx)
            if an > 0:
                var has_after = False
                var ai = 0
                while ai < an:
                    if ctx.files[fi].anchored_idx[ai] > last:
                        has_after = True
                        break
                    ai += 1
                if has_after:
                    var fullrel = List[String](capacity=len(st.per[fi].rel) + 1)
                    var ri = 0
                    while ri < len(st.per[fi].rel):
                        fullrel.append(st.per[fi].rel[ri])
                        ri += 1
                    fullrel.append(name)
                    var ai2 = 0
                    while ai2 < an:
                        var idx2 = ctx.files[fi].anchored_idx[ai2]
                        if (
                            idx2 > last
                            and not ctx.files[fi].patterns[idx2].dir_only
                            and anchored_match_prefix(
                                ctx.files[fi].patterns[idx2],
                                fullrel,
                                len(fullrel) - 1,
                            )
                        ):
                            last = idx2
                        ai2 += 1
            if last >= 0 and not ctx.files[fi].patterns[last].negated:
                return True
        fi += 1
    return False
