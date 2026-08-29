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
# File scanning: recursively walk directories, filter by language table /
# extension, and return the list of files to count.
#
# (Sequential walk; the Rust version parallelizes the traversal, but the
# result is sorted/aggregated downstream so the output is identical.)

from std.collections import Dict, List, Optional, Set
from std.os import lstat
from std.os.path import isdir, isfile, join, realpath
from std.pathlib import Path
from std.stat import S_ISDIR, S_ISLNK, S_ISREG

from language import LangSpec, RAW_NONE, dquote, squote, sl
from util import file_name_of
from vcs import (
    VcsContext,
    VcsDirState,
    abs_path,
    normalize,
    vcs_dir_state,
    vcs_descend,
    vcs_dir_ignored,
    vcs_file_ignored,
    vcs_parent_state,
)


# Scan options.
struct ScanOptions(Movable):
    var ignore_dirs: List[String]
    var ignore_langs: List[String]
    var only_exts: List[String]

    def __init__(out self):
        self.ignore_dirs = List[String]()
        self.ignore_langs = List[String]()
        self.only_exts = List[String]()


# A file to be counted. lang_idx is -1 for unknown (generic) languages.
struct ScannedFile(Movable):
    var path: String
    var lang_name: String
    var lang_idx: Int

    def __init__(out self, path: String, lang_name: String, lang_idx: Int):
        self.path = path
        self.lang_name = lang_name
        self.lang_idx = lang_idx


# Generic syntax for unknown languages: no comments, plain strings only.
def generic_syntax() -> LangSpec:
    return LangSpec(
        "Other",
        List[String](),
        List[String](),
        List[String](),
        List[String](),
        List[String](),
        List[Tuple[String, String]](),
        False,
        sl(dquote(), squote()),
        RAW_NONE,
    )


# Language registry: extension / filename -> language index.
struct Registry(Movable):
    var ext_map: Dict[String, Int]
    var filename_map: Dict[String, Int]

    def __init__(out self):
        self.ext_map = Dict[String, Int]()
        self.filename_map = Dict[String, Int]()

    @staticmethod
    def new(ref langs: List[LangSpec]) -> Registry:
        var reg = Registry()
        var i = 0
        while i < len(langs):
            var e = 0
            while e < len(langs[i].exts):
                var ext = langs[i].exts[e].lower()
                if reg.ext_map.find(ext) is None:
                    reg.ext_map[ext] = i
                e += 1
            var f = 0
            while f < len(langs[i].filenames):
                var fname = langs[i].filenames[f].lower()
                if reg.filename_map.find(fname) is None:
                    reg.filename_map[fname] = i
                f += 1
            i += 1
        return reg^

    # Match a language index for a path (filename first, then extension).
    def match_lang(self, path: String) -> Optional[Int]:
        var name = file_name_of(path)
        var lower = name.lower()
        var fi = self.filename_map.find(lower)
        if fi is not None:
            return Optional[Int](fi.value())
        var idx = name.rfind(".")
        if idx > 0 and idx < name.byte_length() - 1:
            var ext = name[byte = idx + 1 :].lower()
            var ei = self.ext_map.find(ext)
            if ei is not None:
                return Optional[Int](ei.value())
        return Optional[Int]()

    # Match a language index from an already-lowercased file name.
    def match_lang_name(self, lower_name: String) -> Optional[Int]:
        var fi = self.filename_map.find(lower_name)
        if fi is not None:
            return Optional[Int](fi.value())
        var idx = lower_name.rfind(".")
        if idx > 0 and idx < lower_name.byte_length() - 1:
            var ext = String(lower_name[byte = idx + 1 :])
            var ei = self.ext_map.find(ext)
            if ei is not None:
                return Optional[Int](ei.value())
        return Optional[Int]()

    # Whether a language matches ignore_langs (by name/alias or extension).
    def lang_ignored(
        self,
        ref langs: List[LangSpec],
        lang_idx: Optional[Int],
        ext: Optional[String],
        ref ignores: List[String],
    ) -> Bool:
        if len(ignores) == 0:
            return False
        if lang_idx is not None:
            var li = lang_idx.value()
            if contains_str(ignores, langs[li].name):
                return True
            var a = 0
            while a < len(langs[li].aliases):
                if contains_str(ignores, langs[li].aliases[a]):
                    return True
                a += 1
            var e = 0
            while e < len(langs[li].exts):
                if contains_str(ignores, langs[li].exts[e]):
                    return True
                e += 1
        if ext is not None:
            if contains_str(ignores, ext.value()):
                return True
        return False


def contains_str(ref lst: List[String], s: String) -> Bool:
    var i = 0
    while i < len(lst):
        if lst[i] == s:
            return True
        i += 1
    return False


# Make `p` canonical (resolve symlinks / . / ..); fall back to `p` on error.
def canonicalize(p: String) -> String:
    var r: String
    try:
        r = realpath(p)
    except e:
        return p
    return r


def push_file(
    path: String,
    name: String,
    mut files: List[ScannedFile],
    ref opts: ScanOptions,
    ref registry: Registry,
    ref langs: List[LangSpec],
    ref ignore_dirs: Set[String],
    ref only_exts: Set[String],
    only: Bool,
    ref vcs: VcsContext,
    ref state: VcsDirState,
):
    var lower = name.lower()
    if lower in ignore_dirs:
        return
    if vcs_file_ignored(vcs, state, name):
        return
    var lang_idx = registry.match_lang_name(lower)
    var ext: Optional[String] = Optional[String]()
    var dot = lower.rfind(".")
    if dot > 0 and dot < lower.byte_length() - 1:
        ext = Optional[String](String(lower[byte = dot + 1 :]))

    var ext_allowed: Bool
    if only:
        # With -e: extensions must match; extensionless files
        # (e.g. Dockerfile) fall back to the language table
        if ext is not None:
            ext_allowed = ext.value() in only_exts
        else:
            ext_allowed = False
            if lang_idx is not None:
                var li = lang_idx.value()
                var e = 0
                while e < len(langs[li].exts):
                    if langs[li].exts[e].lower() in only_exts:
                        ext_allowed = True
                        break
                    e += 1
    else:
        # Default mode: only count known languages
        ext_allowed = lang_idx is not None
    if not ext_allowed:
        return
    if registry.lang_ignored(langs, lang_idx, ext, opts.ignore_langs):
        return

    var lang_name: String
    var idx: Int
    if lang_idx is not None:
        var li = lang_idx.value()
        lang_name = langs[li].name
        idx = li
    else:
        # Unknown language (reached only when allowed by -e)
        if ext is not None:
            lang_name = ext.value().upper()
        else:
            lang_name = "Other"
        idx = -1
    files.append(ScannedFile(path, lang_name, idx))


# Recursively scan and return the list of files.
def scan(
    roots: List[String],
    ref opts: ScanOptions,
    ref registry: Registry,
    ref langs: List[LangSpec],
    ref vcs: VcsContext,
) -> List[ScannedFile]:
    var ignore_dirs = Set[String]()
    var d = 0
    while d < len(opts.ignore_dirs):
        _ = ignore_dirs.insert(opts.ignore_dirs[d].lower())
        d += 1
    var only_exts = Set[String]()
    var e = 0
    while e < len(opts.only_exts):
        _ = only_exts.insert(opts.only_exts[e].lower())
        e += 1
    var only = len(opts.only_exts) > 0

    var files = List[ScannedFile]()
    var visited = Set[String]()
    # Queue entries: (canonical path, display path, ignore-match state).
    var queue = List[Tuple[String, String, VcsDirState]]()

    var r = 0
    while r < len(roots):
        var root = roots[r]
        var root_canon = canonicalize(root)
        var ins = visited.insert(root_canon)
        if ins is None:
            if isfile(root):
                var pstate = vcs_parent_state(vcs, root)
                push_file(
                    root,
                    file_name_of(root),
                    files,
                    opts,
                    registry,
                    langs,
                    ignore_dirs,
                    only_exts,
                    only,
                    vcs,
                    pstate,
                )
            elif isdir(root):
                var st0 = vcs_dir_state(vcs, normalize(abs_path(root)))
                queue.append((root_canon, root, st0^))
        r += 1

    var qi = 0
    while qi < len(queue):
        var disp = queue[qi][1]
        var state = queue[qi][2].copy()
        qi += 1
        var entries: List[Path]
        try:
            entries = Path(disp).listdir()
        except e2:
            continue
        var subdirs = List[Tuple[String, String, VcsDirState]]()
        var k = 0
        while k < len(entries):
            var name = entries[k].name()
            var path = join(disp, name)
            # NOTE: Path.listdir() yields bare entry names (Path(name)), so
            # entries[k].is_dir()/is_file() would resolve against the
            # process CWD instead of `disp`. The type check must run on
            # the joined full path. (A missed entry here also left `k`
            # unincremented, spinning the loop forever on 3 syscalls.)
            #
            # One lstat per entry, like the Rust scanner's file_type()
            # (which does not follow symlinks): a real directory goes to
            # the dir branch; regular files and all symlinks (to files,
            # to dirs, or broken) go through push_file.
            var mode: Int = 0
            var st_ok = False
            try:
                var st = lstat(path)
                mode = st.st_mode
                st_ok = True
            except e3:
                pass
            if st_ok:
                if S_ISDIR(mode):
                    if name.lower() in ignore_dirs:
                        k += 1
                        continue
                    var cstate = vcs_descend(vcs, state, name)
                    # Prune ignored directories unless a negation rule
                    # could re-include something below them.
                    if vcs_dir_ignored(vcs, cstate) and not vcs.has_negations:
                        k += 1
                        continue
                    var canon2 = canonicalize(path)
                    var ins2 = visited.insert(canon2)
                    if ins2 is None:
                        subdirs.append((canon2, path, cstate^))
                    k += 1
                    continue
                if S_ISREG(mode) or S_ISLNK(mode):
                    push_file(
                        path,
                        name,
                        files,
                        opts,
                        registry,
                        langs,
                        ignore_dirs,
                        only_exts,
                        only,
                        vcs,
                        state,
                    )
            k += 1
        # Move the queued subdirectories into the main queue (LIFO pop
        # keeps the original DFS order and avoids copying the states).
        var s = len(subdirs) - 1
        while s >= 0:
            queue.append(subdirs.pop(s))
            s -= 1
    return files^
