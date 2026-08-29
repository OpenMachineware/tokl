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
# Command-line argument parsing.
#
# Usage:
#   tokl [OPTIONS] <PATH...>

from std.collections import List, Optional


struct Options(Movable):
    var verbose: Bool
    var model: Optional[String]
    var format: Optional[String]
    var jobs: Optional[Int]
    var ignore: List[String]
    var exts: List[String]
    var paths: List[String]
    var show_help: Bool
    var show_version: Bool
    var init_config: Bool

    def __init__(out self):
        self.verbose = False
        self.model = Optional[String]()
        self.format = Optional[String]()
        self.jobs = Optional[Int]()
        self.ignore = List[String]()
        self.exts = List[String]()
        self.paths = List[String]()
        self.show_help = False
        self.show_version = False
        self.init_config = False


# Parse a jobs value; raises with the Rust-compatible message.
def parse_jobs(v: String) raises -> Int:
    var n: Int
    try:
        n = Int(v)
    except e:
        raise Error("invalid thread count: {}".format(v))
    if n < 0:
        raise Error("invalid thread count: {}".format(v))
    if n == 0:
        raise Error("thread count must be >= 1")
    return n


def parse(args: List[String]) raises -> Options:
    var opts = Options()
    var no_more_opts = False
    var i = 0
    var n = len(args)
    while i < n:
        var arg = args[i]
        if no_more_opts or arg.find("-") != 0 or arg == "-":
            opts.paths.append(arg)
            i += 1
            continue
        if arg == "--":
            no_more_opts = True
        elif arg == "-h" or arg == "--help":
            opts.show_help = True
        elif arg == "--version" or arg == "-V":
            opts.show_version = True
        elif arg == "-v" or arg == "--verbose":
            opts.verbose = True
        elif arg == "--init":
            opts.init_config = True
        elif arg == "-m" or arg == "--model":
            if i + 1 >= n:
                raise Error("option {} requires an argument".format(arg))
            opts.model = Optional[String](args[i + 1])
            i += 1
        elif arg == "-f" or arg == "--format":
            if i + 1 >= n:
                raise Error("option {} requires an argument".format(arg))
            opts.format = Optional[String](args[i + 1])
            i += 1
        elif arg == "-i" or arg == "--ignore":
            if i + 1 >= n:
                raise Error("option {} requires an argument".format(arg))
            opts.ignore.append(args[i + 1])
            i += 1
        elif arg == "-e" or arg == "--ext":
            if i + 1 >= n:
                raise Error("option {} requires an argument".format(arg))
            opts.exts.append(args[i + 1])
            i += 1
        elif arg == "-j" or arg == "--jobs":
            if i + 1 >= n:
                raise Error("option {} requires an argument".format(arg))
            var jn = parse_jobs(args[i + 1])
            opts.jobs = Optional[Int](jn)
            i += 1
        else:
            # Support the --model=value form
            var eq = arg.find("=")
            if eq > 0:
                var key = String(arg[byte=0:eq])
                var val = String(arg[byte = eq + 1 :])
                if key == "-m" or key == "--model":
                    opts.model = Optional[String](val)
                elif key == "-f" or key == "--format":
                    opts.format = Optional[String](val)
                elif key == "-i" or key == "--ignore":
                    opts.ignore.append(val)
                elif key == "-e" or key == "--ext":
                    opts.exts.append(val)
                elif key == "-j" or key == "--jobs":
                    var jn2 = parse_jobs(val)
                    opts.jobs = Optional[Int](jn2)
                else:
                    raise Error("unknown option: {}".format(arg))
            else:
                raise Error("unknown option: {}".format(arg))
        i += 1

    if opts.show_help or opts.show_version or opts.init_config:
        return opts^
    if len(opts.paths) == 0:
        raise Error("missing path argument <PATH> (use -h for help)")
    return opts^


def usage() -> String:
    return """tokl - count code lines and tokens

Usage:
    tokl [OPTIONS] <PATH...>

Options:
    -h, --help               Print help
    --version                Print version and copyright info
    -v, --verbose            Verbose output
    -m, --model <MODEL>      Model, one of:
                              chatgpt claude gemini grok deepseek glm kimi
                              qwen seed yuanbao llama mistral
                              (aliases allowed, e.g. gpt-5.6 / deepseek-v4)
    -f, --format <FMT>       Output format: json | table | markdown
    -i, --ignore <PATTERN>   Ignore dirs/languages/extensions
                              (repeatable; merged with config)
    -e, --ext <EXT>          Count only given extensions, e.g. -e ui
                              (repeatable; merged with config)
    -j, --jobs <N>           Number of counting threads
                              (default: number of CPU cores)
    --init                   Write default user_config.toml to config dir
                              (created automatically on first run)
    <PATH>                   Paths to scan (multiple allowed, recursive)

Configuration:
    Default config file: ~/.config/tokl/user_config.toml
    (%APPDATA%\\tokl\\user_config.toml on Windows). It is generated
    automatically on first run (defaults: deepseek-v4, table output,
    common build/dependency dirs ignored). Keys: default_model /
    default_format / default_ignore_dirs / default_ignore_langs /
    default_exts / tokenizer_dir.

Version control:
    When scanning inside a git/svn/hg/bzr/fossil repository, ignore rules
    from the repository's ignore file (.gitignore / .svnignore /
    .hgignore / .bzrignore / .ignore) are applied automatically and merged
    with the -i ignores. Supports *, ?, [...], ** globs and ! negation.

Examples:
    tokl .
    tokl -m deepseek-v4 -f markdown src tests
    tokl -i node_modules -i target -e rs -e py .
    tokl -m qwen --verbose ~/projects/myapp
"""


def version_info() -> String:
    return """tokl 0.1.3
Token and Lines Counter
License: GPL-3.0
Copyright (C) 2026 Jia Liu & tokl contributors"""
