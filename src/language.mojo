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
# Language definitions: extension / filename -> language and syntax
# (comment and string markers).
#
# Notes:
# - `.md` is used by both Markdown and GCC MD; Markdown wins by default
#   (GCC MD is still recognized via `-e gcc-md` or language filtering).
# - `.h` defaults to C (C/C++ header).

from std.collections import List

# Raw string modes
comptime RAW_NONE = 0
comptime RAW_CPP = 1
comptime RAW_RUST = 2


# String delimiter spec.
struct StringSpec(ImplicitlyCopyable):
    var start: String
    var end: String
    var multiline: Bool
    var escape: Bool  # backslash escaping

    def __init__(
        out self, start: String, end: String, multiline: Bool, escape: Bool
    ):
        self.start = start
        self.end = end
        self.multiline = multiline
        self.escape = escape


# Syntax information for one language.
struct LangSpec(Movable):
    var name: String
    var aliases: List[String]
    var exts: List[String]
    var filenames: List[String]
    var line_comments: List[String]
    var line_comments_bol: List[String]
    var block_comments: List[Tuple[String, String]]
    var nestable: Bool
    var strings: List[StringSpec]
    var raw: Int

    def __init__(
        out self,
        var name: String,
        var aliases: List[String],
        var exts: List[String],
        var filenames: List[String],
        var line_comments: List[String],
        var line_comments_bol: List[String],
        var block_comments: List[Tuple[String, String]],
        nestable: Bool,
        var strings: List[StringSpec],
        raw: Int,
    ):
        self.name = name^
        self.aliases = aliases^
        self.exts = exts^
        self.filenames = filenames^
        self.line_comments = line_comments^
        self.line_comments_bol = line_comments_bol^
        self.block_comments = block_comments^
        self.nestable = nestable
        self.strings = strings^
        self.raw = raw


# Common string specs.
def dquote() -> StringSpec:
    return StringSpec('"', '"', False, True)


def squote() -> StringSpec:
    return StringSpec("'", "'", False, True)


def triple_dquote() -> StringSpec:
    return StringSpec('"""', '"""', True, True)


def triple_squote() -> StringSpec:
    return StringSpec("'''", "'''", True, True)


def backtick() -> StringSpec:
    return StringSpec("`", "`", True, False)


def lua_long() -> StringSpec:
    return StringSpec("[[", "]]", True, False)


def sl(var *specs: StringSpec) -> List[StringSpec]:
    var l = List[StringSpec]()
    for s in specs:
        l.append(s)
    return l^


# Build the language table. Order is priority: earlier languages win conflicts.
def languages() -> List[LangSpec]:
    var L = List[LangSpec]()

    # ---- C family ----
    L.append(
        LangSpec(
            "C",
            ["c"],
            ["c", "h"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "C++",
            ["cpp", "cxx", "cc"],
            ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ipp"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote(), squote()),
            RAW_CPP,
        )
    )
    # ---- Assembly ----
    L.append(
        LangSpec(
            "Assembly",
            ["asm", "assembly", "s"],
            ["asm", "s", "S", "inc"],
            [],
            [";", "#"],
            ["@"],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    # ---- JVM family ----
    L.append(
        LangSpec(
            "Java",
            ["java"],
            ["java"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Kotlin",
            ["kotlin", "kt"],
            ["kt", "kts"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Scala",
            ["scala", "sc"],
            ["scala", "sc"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            True,
            sl(dquote()),
            RAW_NONE,
        )
    )
    # ---- D ----
    L.append(
        LangSpec(
            "D",
            ["d"],
            ["d"],
            [],
            ["//"],
            [],
            [("/*", "*/"), ("/+", "+/")],
            True,
            sl(dquote(), squote(), backtick()),
            RAW_NONE,
        )
    )
    # ---- Scripting languages ----
    L.append(
        LangSpec(
            "Vim Script",
            ["vim", "vimscript"],
            ["vim"],
            [],
            [],
            ['"'],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Bash",
            ["bash", "sh", "shell"],
            ["sh", "bash"],
            ["bashrc", "bash_profile", "profile"],
            ["#"],
            [],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Zsh",
            ["zsh"],
            ["zsh"],
            ["zshrc", "zprofile", "zlogin", "zshenv"],
            ["#"],
            [],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Fish",
            ["fish"],
            ["fish"],
            [],
            ["#"],
            [],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Perl",
            ["perl", "pl"],
            ["pl", "pm", "t"],
            [],
            ["#"],
            [],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Python",
            ["python", "py"],
            ["py", "pyw", "pyi"],
            [],
            ["#"],
            [],
            [],
            False,
            sl(dquote(), squote(), triple_dquote(), triple_squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "🔥Mojo",
            ["mojo", "🔥"],
            ["mojo", "🔥"],
            [],
            ["#"],
            [],
            [],
            False,
            sl(dquote(), squote(), triple_dquote(), triple_squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Tcl",
            ["tcl", "tk"],
            ["tcl", "tk"],
            [],
            ["#"],
            [],
            [],
            False,
            sl(dquote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Lua",
            ["lua"],
            ["lua"],
            [],
            ["--"],
            [],
            [("--[[]", "]]")],
            False,
            sl(dquote(), squote(), lua_long()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "PHP",
            ["php"],
            ["php", "php3", "php4", "php5", "phtml"],
            [],
            ["//", "#"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Ruby",
            ["ruby", "rb"],
            ["rb", "rake", "gemspec"],
            ["Gemfile", "Rakefile", "Guardfile"],
            ["#"],
            [],
            [("=begin", "=end")],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    # ---- SQL ----
    L.append(
        LangSpec(
            "SQL",
            ["sql"],
            ["sql"],
            [],
            ["--"],
            [],
            [("/*", "*/")],
            False,
            sl(squote(), dquote()),
            RAW_NONE,
        )
    )
    # ---- Markup / data ----
    L.append(
        LangSpec(
            "JSON",
            ["json"],
            ["json", "jsonc"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "XML",
            ["xml"],
            ["xml", "xsd", "xsl", "xslt", "svg", "qrc", "plist", "pom"],
            [],
            [],
            [],
            [("<!--", "-->")],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "XHTML",
            ["xhtml"],
            ["xhtml"],
            [],
            [],
            [],
            [("<!--", "-->")],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "HTML",
            ["html", "htm"],
            ["html", "htm"],
            [],
            [],
            [],
            [("<!--", "-->")],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "CSS",
            ["css"],
            ["css", "scss", "sass", "less"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    # ---- JS/TS ----
    L.append(
        LangSpec(
            "JavaScript",
            ["js", "javascript"],
            ["js", "mjs", "cjs"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote(), squote(), backtick()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "JSX",
            ["jsx", "react"],
            ["jsx"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote(), squote(), backtick()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "TypeScript",
            ["ts", "typescript"],
            ["ts", "mts", "cts"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote(), squote(), backtick()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "TSX",
            ["tsx"],
            ["tsx"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote(), squote(), backtick()),
            RAW_NONE,
        )
    )
    # ---- Config ----
    L.append(
        LangSpec(
            "TOML",
            ["toml"],
            ["toml"],
            [],
            ["#"],
            [],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "YAML",
            ["yaml", "yml"],
            ["yaml", "yml"],
            [],
            ["#"],
            [],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "INI",
            ["ini", "cfg", "conf"],
            ["ini", "cfg", "conf", "properties"],
            [],
            [";", "#"],
            [],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Dockerfile",
            ["dockerfile", "containerfile"],
            ["dockerfile", "containerfile"],
            ["Dockerfile", "Containerfile"],
            ["#"],
            [],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Makefile",
            ["make", "makefile", "mk"],
            ["mk", "mak"],
            ["Makefile", "makefile", "GNUmakefile"],
            ["#"],
            [],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Ninja",
            ["ninja", "ninja.build"],
            ["ninja"],
            ["build.ninja", "rules.ninja", "toolchain.ninja"],
            ["#"],
            [],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "CMake",
            ["cmake", "cmakelists"],
            ["cmake"],
            ["CMakeLists.txt"],
            ["#"],
            [],
            [("#[[]", "]]")],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    # ---- Documentation ----
    L.append(
        LangSpec(
            "Markdown",
            ["markdown", "md"],
            ["md", "markdown", "mdown"],
            [],
            [],
            [],
            [],
            False,
            [],
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "LaTeX",
            ["latex", "tex"],
            ["tex", "sty", "cls", "bib"],
            [],
            ["%"],
            [],
            [],
            False,
            [],
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Texinfo",
            ["texinfo", "texi"],
            ["texi", "texinfo", "txi"],
            [],
            [],
            ["@c", "@comment"],
            [],
            False,
            [],
            RAW_NONE,
        )
    )
    # GCC machine description (.md, lower priority than Markdown)
    L.append(
        LangSpec(
            "GCC MD",
            ["gccmd", "gcc-md", "gcc_md"],
            [],
            [],
            [";;"],
            [],
            [],
            False,
            sl(dquote()),
            RAW_NONE,
        )
    )
    # ---- Modern languages ----
    L.append(
        LangSpec(
            "Rust",
            ["rust", "rs"],
            ["rs"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote()),
            RAW_RUST,
        )
    )
    L.append(
        LangSpec(
            "Go",
            ["go", "golang"],
            ["go"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote(), backtick()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "Swift",
            ["swift"],
            ["swift"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            True,
            sl(dquote()),
            RAW_NONE,
        )
    )
    # ---- Hardware description ----
    L.append(
        LangSpec(
            "Verilog",
            ["verilog", "v"],
            ["v"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "SystemVerilog",
            ["systemverilog", "sv"],
            ["sv", "svh"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote()),
            RAW_NONE,
        )
    )
    L.append(
        LangSpec(
            "VHDL",
            ["vhdl", "vhd"],
            ["vhd", "vhdl"],
            [],
            ["--"],
            [],
            [],
            False,
            sl(dquote(), squote()),
            RAW_NONE,
        )
    )
    # ---- LLVM TableGen ----
    L.append(
        LangSpec(
            "TableGen",
            ["tablegen", "td", "llvm"],
            ["td"],
            [],
            ["//"],
            [],
            [("/*", "*/")],
            False,
            sl(dquote()),
            RAW_NONE,
        )
    )

    return L^
