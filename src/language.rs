// tokl -- Token and Line Counter
//
// This file is part of the tokl project (tokl — Token and Line Counter).
// Copyright (C) 2026 Jia Liu and tokl contributors
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
//! Language definitions: extension / filename -> language and syntax
//! (comment and string markers).
//!
//! Notes:
//! - `.md` is used by both Markdown and GCC MD; Markdown wins by default
//!   (GCC MD is still recognized via `-e gcc-md` or language filtering).
//! - `.h` defaults to C (C/C++ header).

/// String delimiter spec.
#[derive(Debug, Clone, Copy)]
pub struct StringSpec {
    pub start: &'static str,
    pub end: &'static str,
    /// Whether it spans lines (multi-line string)
    pub multiline: bool,
    /// Escape character (e.g. '\\'); None means no backslash escaping
    pub escape: Option<char>,
}

/// Raw string (no escapes processed, may span lines) special modes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RawKind {
    None,
    /// C++ R"(...)" / R"delim(...)delim"
    Cpp,
    /// Rust r"..." / r#"..."# / r##"..."##
    Rust,
}

/// Syntax information for one language.
#[derive(Debug, Clone, Copy)]
pub struct LangSpec {
    /// Display name
    pub name: &'static str,
    /// Aliases (used by -i filtering)
    pub aliases: &'static [&'static str],
    /// Extensions (lowercase, no dot)
    pub exts: &'static [&'static str],
    /// Exact filenames (e.g. "Dockerfile", "CMakeLists.txt")
    pub filenames: &'static [&'static str],
    /// Line comment markers (any position)
    pub line_comments: &'static [&'static str],
    /// Line comment markers valid only at line start
    /// (e.g. vim's `"`, texinfo's `@c`)
    pub line_comments_bol: &'static [&'static str],
    /// Block comment markers (start, end)
    pub block_comments: &'static [&'static (&'static str, &'static str)],
    /// Whether block comments nest
    pub nestable: bool,
    /// String delimiters
    pub strings: &'static [StringSpec],
    /// Raw string mode
    pub raw: RawKind,
}

macro_rules! strings {
    ($($s:expr),* $(,)?) => {
        &[$($s),*]
    };
}

pub const DQUOTE: StringSpec =
    StringSpec { start: "\"", end: "\"", multiline: false, escape: Some('\\') };
pub const SQUOTE: StringSpec =
    StringSpec { start: "'", end: "'", multiline: false, escape: Some('\\') };
pub const TRIPLE_DQUOTE: StringSpec = StringSpec {
    start: "\"\"\"",
    end: "\"\"\"",
    multiline: true,
    escape: Some('\\'),
};
pub const TRIPLE_SQUOTE: StringSpec = StringSpec {
    start: "'''",
    end: "'''",
    multiline: true,
    escape: Some('\\'),
};
pub const BACKTICK: StringSpec =
    StringSpec { start: "`", end: "`", multiline: true, escape: None };
pub const LUA_LONG: StringSpec =
    StringSpec { start: "[[", end: "]]", multiline: true, escape: None };

/// Language table. Order is priority: earlier languages win conflicts.
pub static LANGUAGES: &[LangSpec] = &[
    // ---- C family ----
    LangSpec {
        name: "C",
        aliases: &["c"],
        exts: &["c", "h"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "C++",
        aliases: &["cpp", "cxx", "cc"],
        exts: &["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ipp"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::Cpp,
    },
    // ---- Assembly ----
    LangSpec {
        name: "Assembly",
        aliases: &["asm", "assembly", "s"],
        exts: &["asm", "s", "S", "inc"],
        filenames: &[],
        line_comments: &[";", "#"],
        line_comments_bol: &["@"],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    // ---- JVM family ----
    LangSpec {
        name: "Java",
        aliases: &["java"],
        exts: &["java"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Kotlin",
        aliases: &["kotlin", "kt"],
        exts: &["kt", "kts"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Scala",
        aliases: &["scala", "sc"],
        exts: &["scala", "sc"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: true,
        strings: strings!(DQUOTE),
        raw: RawKind::None,
    },
    // ---- D ----
    LangSpec {
        name: "D",
        aliases: &["d"],
        exts: &["d"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/"), &("/+", "+/")],
        nestable: true,
        strings: strings!(DQUOTE, SQUOTE, BACKTICK),
        raw: RawKind::None,
    },
    // ---- Scripting languages ----
    LangSpec {
        name: "Vim Script",
        aliases: &["vim", "vimscript"],
        exts: &["vim"],
        filenames: &[],
        line_comments: &[],
        line_comments_bol: &["\""],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Bash",
        aliases: &["bash", "sh", "shell"],
        exts: &["sh", "bash"],
        filenames: &["bashrc", "bash_profile", "profile"],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Zsh",
        aliases: &["zsh"],
        exts: &["zsh"],
        filenames: &["zshrc", "zprofile", "zlogin", "zshenv"],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Fish",
        aliases: &["fish"],
        exts: &["fish"],
        filenames: &[],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Perl",
        aliases: &["perl", "pl"],
        exts: &["pl", "pm", "t"],
        filenames: &[],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Python",
        aliases: &["python", "py"],
        exts: &["py", "pyw", "pyi"],
        filenames: &[],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE, TRIPLE_DQUOTE, TRIPLE_SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Tcl",
        aliases: &["tcl", "tk"],
        exts: &["tcl", "tk"],
        filenames: &[],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Lua",
        aliases: &["lua"],
        exts: &["lua"],
        filenames: &[],
        line_comments: &["--"],
        line_comments_bol: &[],
        block_comments: &[&("--[[", "]]")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE, LUA_LONG),
        raw: RawKind::None,
    },
    LangSpec {
        name: "PHP",
        aliases: &["php"],
        exts: &["php", "php3", "php4", "php5", "phtml"],
        filenames: &[],
        line_comments: &["//", "#"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Ruby",
        aliases: &["ruby", "rb"],
        exts: &["rb", "rake", "gemspec"],
        filenames: &["Gemfile", "Rakefile", "Guardfile"],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[&("=begin", "=end")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    // ---- SQL ----
    LangSpec {
        name: "SQL",
        aliases: &["sql"],
        exts: &["sql"],
        filenames: &[],
        line_comments: &["--"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(SQUOTE, DQUOTE),
        raw: RawKind::None,
    },
    // ---- Markup / data ----
    LangSpec {
        name: "JSON",
        aliases: &["json"],
        exts: &["json", "jsonc"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "XML",
        aliases: &["xml"],
        exts: &["xml", "xsd", "xsl", "xslt", "svg", "qrc", "plist", "pom"],
        filenames: &[],
        line_comments: &[],
        line_comments_bol: &[],
        block_comments: &[&("<!--", "-->")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "XHTML",
        aliases: &["xhtml"],
        exts: &["xhtml"],
        filenames: &[],
        line_comments: &[],
        line_comments_bol: &[],
        block_comments: &[&("<!--", "-->")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "HTML",
        aliases: &["html", "htm"],
        exts: &["html", "htm"],
        filenames: &[],
        line_comments: &[],
        line_comments_bol: &[],
        block_comments: &[&("<!--", "-->")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "CSS",
        aliases: &["css"],
        exts: &["css", "scss", "sass", "less"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    // ---- JS/TS ----
    LangSpec {
        name: "JavaScript",
        aliases: &["js", "javascript"],
        exts: &["js", "mjs", "cjs"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE, BACKTICK),
        raw: RawKind::None,
    },
    LangSpec {
        name: "JSX",
        aliases: &["jsx", "react"],
        exts: &["jsx"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE, BACKTICK),
        raw: RawKind::None,
    },
    LangSpec {
        name: "TypeScript",
        aliases: &["ts", "typescript"],
        exts: &["ts", "mts", "cts"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE, BACKTICK),
        raw: RawKind::None,
    },
    LangSpec {
        name: "TSX",
        aliases: &["tsx"],
        exts: &["tsx"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE, BACKTICK),
        raw: RawKind::None,
    },
    // ---- Config ----
    LangSpec {
        name: "TOML",
        aliases: &["toml"],
        exts: &["toml"],
        filenames: &[],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "YAML",
        aliases: &["yaml", "yml"],
        exts: &["yaml", "yml"],
        filenames: &[],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "INI",
        aliases: &["ini", "cfg", "conf"],
        exts: &["ini", "cfg", "conf", "properties"],
        filenames: &[],
        line_comments: &[";", "#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Dockerfile",
        aliases: &["dockerfile", "containerfile"],
        exts: &["dockerfile", "containerfile"],
        filenames: &["Dockerfile", "Containerfile"],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Makefile",
        aliases: &["make", "makefile", "mk"],
        exts: &["mk", "mak"],
        filenames: &["Makefile", "makefile", "GNUmakefile"],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Ninja",
        aliases: &["ninja", "ninja.build"],
        exts: &["ninja"],
        filenames: &["build.ninja", "rules.ninja", "toolchain.ninja"],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "CMake",
        aliases: &["cmake", "cmakelists"],
        exts: &["cmake"],
        filenames: &["CMakeLists.txt"],
        line_comments: &["#"],
        line_comments_bol: &[],
        block_comments: &[&("#[[", "]]")],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    // ---- Documentation ----
    LangSpec {
        name: "Markdown",
        aliases: &["markdown", "md"],
        exts: &["md", "markdown", "mdown"],
        filenames: &[],
        line_comments: &[],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: &[],
        raw: RawKind::None,
    },
    LangSpec {
        name: "LaTeX",
        aliases: &["latex", "tex"],
        exts: &["tex", "sty", "cls", "bib"],
        filenames: &[],
        line_comments: &["%"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: &[],
        raw: RawKind::None,
    },
    LangSpec {
        name: "Texinfo",
        aliases: &["texinfo", "texi"],
        exts: &["texi", "texinfo", "txi"],
        filenames: &[],
        line_comments: &[],
        line_comments_bol: &["@c", "@comment"],
        block_comments: &[],
        nestable: false,
        strings: &[],
        raw: RawKind::None,
    },
    // GCC machine description (.md, lower priority than Markdown)
    LangSpec {
        name: "GCC MD",
        aliases: &["gccmd", "gcc-md", "gcc_md"],
        exts: &[],
        filenames: &[],
        line_comments: &[";;"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE),
        raw: RawKind::None,
    },
    // ---- Modern languages ----
    LangSpec {
        name: "Rust",
        aliases: &["rust", "rs"],
        exts: &["rs"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE),
        raw: RawKind::Rust,
    },
    LangSpec {
        name: "Go",
        aliases: &["go", "golang"],
        exts: &["go"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE, BACKTICK),
        raw: RawKind::None,
    },
    LangSpec {
        name: "Swift",
        aliases: &["swift"],
        exts: &["swift"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: true,
        strings: strings!(DQUOTE),
        raw: RawKind::None,
    },
    // ---- Hardware description ----
    LangSpec {
        name: "Verilog",
        aliases: &["verilog", "v"],
        exts: &["v"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "SystemVerilog",
        aliases: &["systemverilog", "sv"],
        exts: &["sv", "svh"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE),
        raw: RawKind::None,
    },
    LangSpec {
        name: "VHDL",
        aliases: &["vhdl", "vhd"],
        exts: &["vhd", "vhdl"],
        filenames: &[],
        line_comments: &["--"],
        line_comments_bol: &[],
        block_comments: &[],
        nestable: false,
        strings: strings!(DQUOTE, SQUOTE),
        raw: RawKind::None,
    },
    // ---- LLVM TableGen ----
    LangSpec {
        name: "TableGen",
        aliases: &["tablegen", "td", "llvm"],
        exts: &["td"],
        filenames: &[],
        line_comments: &["//"],
        line_comments_bol: &[],
        block_comments: &[&("/*", "*/")],
        nestable: false,
        strings: strings!(DQUOTE),
        raw: RawKind::None,
    },
];
