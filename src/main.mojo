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
# tokl — Token and Line Counter.
#
# (Mojo 1.0 has no user-thread API, so the scan/count work that the Rust
#  build parallelizes is done sequentially; the output is identical.)

from std.collections import List, Optional, Set
from std.os.path import exists, getsize
from std.pathlib import Path
from std.os.env import getenv
from std.sys import argv, stderr
from std.sys.terminate import exit
from std.time import perf_counter_ns as _now

from cli import Options, parse, usage, version_info
from config import (
    config_file_path,
    config_path,
    load as config_load,
    write_default_config,
)
from count import FileCount, LangAgg, aggregate, count_file
from format import format_from_str, render
from language import languages
from scanner import Registry, ScanOptions, generic_syntax, scan
from tokenize import build, models, resolve_model
from util import looks_binary
from vcs import VCS_BZR, VCS_FOSSIL, VCS_GIT, VCS_HG, VCS_SVN, vcs_detect


def vcs_kind_name(kind: Int) -> String:
    if kind == VCS_GIT:
        return "git"
    if kind == VCS_SVN:
        return "svn"
    if kind == VCS_HG:
        return "hg"
    if kind == VCS_BZR:
        return "bzr"
    return "fossil"


# --init: generate a default config file.
def init_config():
    var path = config_file_path()
    if path is None:
        print("error: cannot determine config directory", file=stderr)
        exit(1)
    if exists(path.value()):
        print(
            "config file already exists: {}".format(path.value()), file=stderr
        )
        exit(1)
    try:
        write_default_config(path.value())
    except e:
        print("error: cannot write {}: {}".format(path.value(), e), file=stderr)
        exit(1)
    print("generated config file: {}".format(path.value()))
    exit(0)


# Read a whole file with a pre-sized buffer (stat + one read) instead of
# read_bytes(-1), which starts at 256 bytes and doubles, causing several
# read syscalls and reallocations per small file. Returns None on error.
def read_file(path: String) -> Optional[List[Byte]]:
    try:
        var size = getsize(path)
        var fh = open(path, "r")
        return Optional[List[Byte]](fh.read_bytes(size))
    except e:
        return Optional[List[Byte]]()


# Deduplicate extensions (case-insensitive, keep first occurrence).
def dedup_exts(exts: List[String]) -> List[String]:
    var seen = Set[String]()
    var out = List[String]()
    var i = 0
    while i < len(exts):
        var e = exts[i].lower()
        var ins = seen.insert(e)
        if ins is None:
            out.append(exts[i])
        i += 1
    return out^


def main() raises:
    # Collect arguments (skip argv[0])
    var av = argv()
    var args = List[String]()
    var i = 1
    while i < len(av):
        args.append(String(av[i]))
        i += 1

    var _t0 = _now()
    var opts = Options()
    var parse_ok = True
    var parse_err = ""
    try:
        opts = parse(args)
    except e:
        parse_ok = False
        parse_err = String(e)
    if not parse_ok:
        print("error: {}".format(parse_err), file=stderr)
        print("", file=stderr)
        print(usage(), file=stderr)
        exit(2)

    if opts.show_help:
        print(usage())
        exit(0)
    if opts.show_version:
        print(version_info())
        exit(0)
    if opts.init_config:
        init_config()
        exit(0)

    # Load config (CLI flags take precedence)
    var cfg = config_load()
    if opts.verbose:
        var cp = config_path()
        if cp is not None:
            print("[verbose] config file: {}".format(cp.value()), file=stderr)
        else:
            print(
                "[verbose] no config file found (use --init to create one)",
                file=stderr,
            )

    # Extract config fields (copy the Optionals and the lists)
    var cfg_model = cfg.default_model
    var cfg_format = cfg.default_format
    var cfg_tokenizer_dir = cfg.tokenizer_dir
    var ignore_dirs = List[String](copy=cfg.default_ignore_dirs)
    var ignore_langs = List[String](copy=cfg.default_ignore_langs)
    var exts = List[String](copy=cfg.default_exts)

    # Merge defaults with CLI arguments
    var model_name: String
    if opts.model is not None:
        model_name = opts.model.value()
    elif cfg_model is not None:
        model_name = cfg_model.value()
    else:
        model_name = "deepseek-v4"

    var mod = models()
    var model_idx = resolve_model(mod, model_name)
    if model_idx is None:
        print(
            "error: unknown model '{}' (use -h to list supported models)"
            .format(model_name),
            file=stderr,
        )
        exit(2)

    var format_name: String
    if opts.format is not None:
        format_name = opts.format.value()
    elif cfg_format is not None:
        format_name = cfg_format.value()
    else:
        format_name = "table"
    var fmt: Int = 0
    var fmt_ok = True
    var fmt_err = ""
    try:
        fmt = format_from_str(format_name)
    except e:
        fmt_ok = False
        fmt_err = String(e)
    if not fmt_ok:
        print("error: {}".format(fmt_err), file=stderr)
        exit(2)

    # Merge -i with ignore_dirs / ignore_langs from config
    var ig = 0
    while ig < len(opts.ignore):
        ignore_dirs.append(opts.ignore[ig])
        ig += 1
    var ig2 = 0
    while ig2 < len(opts.ignore):
        ignore_langs.append(opts.ignore[ig2])
        ig2 += 1

    # Merge -e with default_exts from config
    var ex = 0
    while ex < len(opts.exts):
        exts.append(opts.exts[ex])
        ex += 1
    var deduped = dedup_exts(exts)

    # Detect version control (git/svn/hg/...) and load repository ignore rules
    var vcs = vcs_detect(opts.paths)
    if opts.verbose:
        if len(vcs.kinds) == 0:
            print(
                "[verbose] no version-control repository detected", file=stderr
            )
        else:
            var r = 0
            while r < len(vcs.repos):
                print(
                    "[verbose] vcs: {} repository at {}".format(
                        vcs_kind_name(vcs.repos[r][0]), vcs.repos[r][1]
                    ),
                    file=stderr,
                )
                r += 1
            if vcs.rule_count > 0:
                print(
                    "[verbose] vcs: applying {} ignore rule(s) from repo ignore"
                    " files".format(vcs.rule_count),
                    file=stderr,
                )

    var scan_opts = ScanOptions()
    scan_opts.ignore_dirs = ignore_dirs^
    scan_opts.ignore_langs = ignore_langs^
    scan_opts.only_exts = deduped^

    # Build the tokenizer
    var loaded_from = Optional[String]()
    var tokenizer = build(
        mod[model_idx.value()], cfg_tokenizer_dir, loaded_from
    )
    if opts.verbose:
        if loaded_from is not None:
            print(
                "[verbose] model {}: using exact tokenizer ({})".format(
                    mod[model_idx.value()].name, loaded_from.value()
                ),
                file=stderr,
            )
        else:
            print(
                "[verbose] model {}: no local vocab found, using approximate"
                " tokenizer (set tokenizer_dir in config)".format(
                    mod[model_idx.value()].name
                ),
                file=stderr,
            )

    # Scan
    var _t1 = _now()
    var langs = languages()
    var registry = Registry.new(langs)
    var files = scan(opts.paths, scan_opts, registry, langs, vcs)
    var _t2 = _now()
    if len(files) == 0:
        print("info: no countable files found", file=stderr)
        exit(0)

    # Count files (sequential)
    var generic = generic_syntax()
    var file_counts = List[Tuple[String, FileCount]]()
    var binary_skipped: UInt64 = 0
    var fi = 0
    while fi < len(files):
        var fpath = files[fi].path
        var flang = files[fi].lang_name
        var fidx = files[fi].lang_idx
        var data_opt = read_file(fpath)
        if data_opt is None:
            fi += 1
            continue
        var data = data_opt.take()
        if looks_binary(data):
            binary_skipped += 1
            if opts.verbose:
                print(
                    "[verbose] skipped binary file: {}".format(fpath),
                    file=stderr,
                )
            fi += 1
            continue
        var tokens = tokenizer.count(data)
        var fc: FileCount
        if fidx >= 0:
            fc = count_file(data, langs[fidx], tokens)
        else:
            fc = count_file(data, generic, tokens)
        file_counts.append((flang, fc))
        fi += 1

    if opts.verbose:
        print(
            "[verbose] counted {} files (skipped {} binary files)".format(
                len(file_counts), binary_skipped
            ),
            file=stderr,
        )

    var _t3 = _now()
    # Aggregate
    var rows = aggregate(file_counts)
    var total = LangAgg()
    var tr = 0
    while tr < len(rows):
        total.add(rows[tr][1])
        tr += 1

    # Output
    var out = render(rows, total, fmt, mod[model_idx.value()].name)
    print(out, end="")
    var _t4 = _now()
    if getenv("TOKL_PROFILE", "") != "":
        print(
            "[profile] setup={}ms scan={}ms count={}ms agg+out={}ms".format(
                Float64(_t1 - _t0) / 1e6,
                Float64(_t2 - _t1) / 1e6,
                Float64(_t3 - _t2) / 1e6,
                Float64(_t4 - _t3) / 1e6,
            ),
            file=stderr,
        )
    exit(0)
