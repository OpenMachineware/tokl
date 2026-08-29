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
# Config loading: read ~/.config/tokl/user_config.toml (Linux/macOS)
# or %APPDATA%\tokl\user_config.toml (Windows).

from std.collections import List, Optional
from std.os import makedirs
from std.os.env import getenv
from std.os.path import dirname, isfile, join
from std.pathlib import Path
from std.sys import stderr

from toml import MiniToml


struct Config(Movable):
    var default_model: Optional[String]
    var default_format: Optional[String]
    var default_ignore_dirs: List[String]
    var default_ignore_langs: List[String]
    var default_exts: List[String]
    var tokenizer_dir: Optional[String]

    def __init__(out self):
        self.default_model = Optional[String]()
        self.default_format = Optional[String]()
        self.default_ignore_dirs = List[String]()
        self.default_ignore_langs = List[String]()
        self.default_exts = List[String]()
        self.tokenizer_dir = Optional[String]()


# The directory holding the config file (may not exist).
def config_dir() -> Optional[String]:
    var appdata = getenv("APPDATA", "")
    if appdata != "":
        return Optional[String](join(appdata, "tokl"))
    var xdg = getenv("XDG_CONFIG_HOME", "")
    if xdg != "":
        return Optional[String](join(xdg, "tokl"))
    var home = getenv("HOME", "")
    if home != "":
        return Optional[String](join(home, ".config", "tokl"))
    return Optional[String]()


# Resolve the config file path, whether or not the file exists yet.
def config_file_path() -> Optional[String]:
    var tokl_cfg = getenv("TOKL_CONFIG", "")
    if tokl_cfg != "":
        return Optional[String](tokl_cfg)
    var d = config_dir()
    if d is not None:
        return Optional[String](join(d.value(), "user_config.toml"))
    return Optional[String]()


# Return the config file path, if it exists.
def config_path() -> Optional[String]:
    var p = config_file_path()
    if p is not None and isfile(p.value()):
        return p
    return Optional[String]()


# Write the default config template to `path`, creating parent directories.
def write_default_config(path: String) raises:
    var parent = dirname(path)
    if parent != "" and parent != ".":
        makedirs(parent)
    Path(path).write_text(default_config_template())


# First-run bootstrap: create the default config file when missing.
def ensure_default_config() -> Optional[String]:
    var path = config_file_path()
    if path is None:
        return Optional[String]()
    if isfile(path.value()):
        return Optional[String]()
    try:
        write_default_config(path.value())
    except e:
        print(
            "[warning] cannot create default config file {}: {}".format(
                path.value(), e
            ),
            file=stderr,
        )
        return Optional[String]()
    return path


# Load config; return the default (empty) config if the file is missing.
def load() -> Config:
    var cfg = Config()
    var ensured = ensure_default_config()
    if ensured is not None:
        print(
            "generated default config file: {}".format(ensured.value()),
            file=stderr,
        )
    var path = config_path()
    if path is None:
        return cfg^
    var text: String
    try:
        text = Path(path.value()).read_text()
    except e:
        print(
            "[warning] cannot read config file: {}".format(path.value()),
            file=stderr,
        )
        return cfg^
    var toml: MiniToml
    try:
        toml = MiniToml.parse(text)
    except e:
        print(
            "[warning] failed to parse config file ({}): {}".format(
                path.value(), e
            ),
            file=stderr,
        )
        return cfg^
    var v = toml.get_str("default_model")
    if v is not None:
        cfg.default_model = v
    v = toml.get_str("default_format")
    if v is not None:
        cfg.default_format = v
    var a = toml.get_str_array("default_ignore_dirs")
    if a is not None:
        cfg.default_ignore_dirs = a.take()
    a = toml.get_str_array("default_ignore_langs")
    if a is not None:
        cfg.default_ignore_langs = a.take()
    a = toml.get_str_array("default_exts")
    if a is not None:
        cfg.default_exts = a.take()
    v = toml.get_str("tokenizer_dir")
    if v is not None:
        cfg.tokenizer_dir = v
    return cfg^


# Default config file contents (written on first run and by --init).
def default_config_template() -> String:
    return """# tokl user configuration
#
# This file is generated automatically on first run. You can edit it and
# the changes will take effect the next time tokl starts.

# Default LLM used for token counting (the -m flag takes precedence).
# A domestic LLM is the default: DeepSeek V4 (Byte-level BPE, 128K vocab).
default_model = "deepseek-v4"

# Default output format (maps to -f; supports table, json, markdown)
default_format = "table"

# Default directories to ignore (maps to -i; matched by exact directory
# name, case-insensitively). Covers common dependency/build/cache dirs:
#   JS/TS: node_modules, dist, .next, .nuxt, vendor
#   Rust:  target        Java: .gradle        Python: __pycache__,
#   .venv, venv, .mypy_cache, .pytest_cache, .ruff_cache, .tox, .nox
#   Generic: .git, .hg, .svn, build, out, coverage, .idea, .vscode,
#   .terraform, .cache, .dart_tool, Pods
# When scanning inside a git/svn/hg/bzr/fossil repository, the repository's
# ignore file (.gitignore etc.) is also applied and merged with this list.
# 当扫描路径位于 git/svn/hg/bzr/fossil 仓库内时，仓库的忽略文件
# （.gitignore 等）也会自动生效，与本列表取并集。
default_ignore_dirs = [
    "node_modules",
    "target",
    ".git",
    ".hg",
    ".svn",
    "dist",
    "build",
    "out",
    "coverage",
    "__pycache__",
    ".venv",
    "venv",
    ".idea",
    ".vscode",
    ".next",
    ".nuxt",
    "vendor",
    "Pods",
    ".gradle",
    ".terraform",
    ".cache",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".tox",
    ".nox",
    ".dart_tool",
]

# Default languages to ignore (maps to -i; filtered by extension or
# language name): svg images, lockfiles and source maps are rarely of
# interest when counting code.
default_ignore_langs = [
    "svg",
    "lock",
    "map",
]

# Default extensions to count only (maps to -e).
# Empty counts all file types; set it, e.g. ["rs", "py", "js"], if you
# usually want to restrict counting to specific languages.
default_exts = []

# Optional: tokenizer vocab directory. Put each model's vocab files here
# (tokenizer.json / tokenizer.model / *.tiktoken) to get exact token counts;
# the built-in approximate algorithm is used when unset or not found.
# tokenizer_dir = "/path/to/vocabs"
"""
