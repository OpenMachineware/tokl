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
//! Line counting: use language syntax (comment/string markers) to count
//! total / blank / comment / code lines.
//!
//! Classification rules (following scc/tokei):
//! - Lines   : total lines in the file
//! - Blanks  : lines with no non-whitespace characters
//! - Comments: non-blank lines entirely inside a comment (start with a
//!             comment marker, or lie within a block comment)
//! - Code    : all other non-blank lines (including mixed
//!             "code + trailing comment" lines)
//! - Tokens  : provided by the tokenizer module

use std::collections::BTreeMap;

use crate::language::{LangSpec, RawKind, StringSpec};

/// Aggregated statistics for one language.
#[derive(Debug, Clone, Copy, Default)]
pub struct LangAgg {
    pub files: u64,
    pub lines: u64,
    pub blanks: u64,
    pub comments: u64,
    pub code: u64,
    pub tokens: u64,
}

impl LangAgg {
    pub fn add(&mut self, o: &LangAgg) {
        self.files += o.files;
        self.lines += o.lines;
        self.blanks += o.blanks;
        self.comments += o.comments;
        self.code += o.code;
        self.tokens += o.tokens;
    }
}

/// Statistics for a single file.
#[derive(Debug, Clone, Copy, Default)]
pub struct FileCount {
    pub lines: u64,
    pub blanks: u64,
    pub comments: u64,
    pub code: u64,
    pub tokens: u64,
}

/// Count lines of file byte content; tokens is supplied by the caller.
pub fn count_file(data: &[u8], syntax: &LangSpec, tokens: u64) -> FileCount {
    let mut fc = FileCount { tokens, ..Default::default() };

    // Cross-line state
    let mut block_depth: u32 = 0;
    let mut in_string: Option<usize> = None; // string spec index
    let mut raw_end: Option<Vec<u8>> = None; // C++ raw end sequence
    let mut raw_hashes: usize = 0; // number of # in Rust raw

    // A trailing \n makes split yield an empty segment; ignore it
    let mut segments = data.split(|&b| b == b'\n').peekable();
    while let Some(line) = segments.next() {
        if line.is_empty() && segments.peek().is_none() {
            continue;
        }
        fc.lines += 1;

        // A line that is entirely blank still belongs to an open
        // cross-line string / raw string / block comment:
        //   - inside a string or raw string  -> counts as code
        //   - inside a block comment         -> counts as comment
        let mut seen_code =
            in_string.is_some() || raw_hashes > 0 || raw_end.is_some();
        let mut seen_comment = block_depth > 0;
        let mut has_nonblank = seen_code || seen_comment;
        let mut pos = 0usize;

        while pos < line.len() {
            // 1) String content
            if let Some(spec_idx) = in_string {
                let spec = &syntax.strings[spec_idx];
                if let Some(esc) = spec.escape {
                    if line[pos] as char == esc {
                        pos += 2;
                        continue;
                    }
                }
                if line[pos..].starts_with(spec.end.as_bytes()) {
                    in_string = None;
                    pos += spec.end.len();
                    continue;
                }
                pos += 1;
                seen_code = true;
                has_nonblank = true;
                continue;
            }
            // 2) C++ raw string content
            if let Some(end_seq) = &raw_end {
                if line[pos..].starts_with(end_seq.as_slice()) {
                    let end_len = end_seq.len();
                    raw_end = None;
                    pos += end_len;
                    continue;
                }
                pos += 1;
                seen_code = true;
                has_nonblank = true;
                continue;
            }
            // 3) Rust raw string content
            if raw_hashes > 0 {
                let n = raw_hashes;
                if line[pos] == b'"'
                    && line.len() >= pos + 1 + n
                    && line[pos + 1..pos + 1 + n].iter().all(|&x| x == b'#')
                {
                    raw_hashes = 0;
                    pos += 1 + n;
                    continue;
                }
                pos += 1;
                seen_code = true;
                has_nonblank = true;
                continue;
            }
            // 4) Block comment content
            if block_depth > 0 {
                seen_comment = true;
                has_nonblank = true;
                let mut matched = false;
                if syntax.nestable {
                    for (start, _) in syntax.block_comments {
                        if line[pos..].starts_with(start.as_bytes()) {
                            block_depth += 1;
                            pos += start.len();
                            matched = true;
                            break;
                        }
                    }
                    if matched {
                        continue;
                    }
                }
                for (_, end) in syntax.block_comments {
                    if line[pos..].starts_with(end.as_bytes()) {
                        block_depth -= 1;
                        pos += end.len();
                        matched = true;
                        break;
                    }
                }
                if !matched {
                    pos += 1;
                }
                continue;
            }
            // 5) Normal state
            let b = line[pos];

            // 5a) raw string start
            if let Some(start_len) = raw_start_len(syntax, line, pos) {
                match syntax.raw {
                    RawKind::Cpp => {
                        // R"DELIM( ... )DELIM" - same line required
                        let after = &line[pos + 2..];
                        if let Some(paren) =
                            after.iter().position(|&c| c == b'(')
                        {
                            let delim = &after[..paren];
                            let mut end_seq =
                                Vec::with_capacity(delim.len() + 2);
                            end_seq.push(b')');
                            end_seq.extend_from_slice(delim);
                            end_seq.push(b'"');
                            raw_end = Some(end_seq);
                            pos += 2 + paren + 1; // skip past R"DELIM(
                            seen_code = true;
                            has_nonblank = true;
                            continue;
                        }
                        // Unparseable R" (may be an ordinary string);
                        // fall back to ordinary characters
                        pos += start_len;
                        seen_code = true;
                        has_nonblank = true;
                        continue;
                    }
                    RawKind::Rust => {
                        // r#"..."#
                        let mut hashes = 0usize;
                        while pos + 1 + hashes < line.len()
                            && line[pos + 1 + hashes] == b'#'
                        {
                            hashes += 1;
                        }
                        if pos + 1 + hashes < line.len()
                            && line[pos + 1 + hashes] == b'"'
                        {
                            raw_hashes = hashes;
                            pos += 2 + hashes; // skip past r#"
                            seen_code = true;
                            has_nonblank = true;
                            continue;
                        }
                        pos += 1;
                        seen_code = true;
                        has_nonblank = true;
                        continue;
                    }
                    RawKind::None => {
                        pos += 1;
                        continue;
                    }
                }
            }

            // 5b) string start (longest delimiter first)
            let mut best: Option<(usize, &StringSpec)> = None;
            for (i, spec) in syntax.strings.iter().enumerate() {
                if line[pos..].starts_with(spec.start.as_bytes()) {
                    match best {
                        Some((_, cur))
                            if cur.start.len() < spec.start.len() =>
                        {
                            best = Some((i, spec))
                        }
                        None => best = Some((i, spec)),
                        _ => {}
                    }
                }
            }
            if let Some((i, spec)) = best {
                in_string = Some(i);
                seen_code = true;
                has_nonblank = true;
                pos += spec.start.len();
                // Immediately closed empty string "" / ''
                if spec.end == spec.start
                    && line[pos..].starts_with(spec.end.as_bytes())
                {
                    in_string = None;
                    pos += spec.end.len();
                }
                continue;
            }

            // 5c) block comment start
            let mut matched = false;
            for (start, _) in syntax.block_comments {
                if line[pos..].starts_with(start.as_bytes()) {
                    block_depth = 1;
                    seen_comment = true;
                    has_nonblank = true;
                    pos += start.len();
                    matched = true;
                    break;
                }
            }
            if matched {
                continue;
            }

            // 5d) line comment start
            let mut matched = false;
            for &mark in syntax.line_comments {
                if line[pos..].starts_with(mark.as_bytes()) {
                    seen_comment = true;
                    has_nonblank = true;
                    matched = true;
                    break;
                }
            }
            if matched {
                break;
            }

            // 5e) comment markers valid at line start (nothing before)
            if !seen_code && !has_nonblank && !seen_comment {
                for &mark in syntax.line_comments_bol {
                    if line[pos..].starts_with(mark.as_bytes()) {
                        seen_comment = true;
                        has_nonblank = true;
                        matched = true;
                        break;
                    }
                }
                if matched {
                    break;
                }
            }

            // 5f) ordinary character
            if !b.is_ascii_whitespace() {
                seen_code = true;
                has_nonblank = true;
            }
            pos += 1;
        }

        // End of line: force-close a single-line string still open
        if let Some(i) = in_string {
            if !syntax.strings[i].multiline {
                in_string = None;
            }
        }

        if !has_nonblank {
            fc.blanks += 1;
        } else if seen_code {
            fc.code += 1;
        } else {
            fc.comments += 1;
        }
    }

    fc
}

/// Compute raw string start length (Rust: r#", C++: R").
fn raw_start_len(syntax: &LangSpec, line: &[u8], pos: usize) -> Option<usize> {
    match syntax.raw {
        RawKind::Cpp => {
            if line[pos..].starts_with(b"R\"") {
                Some(2)
            } else {
                None
            }
        }
        RawKind::Rust => {
            if line[pos] == b'r' {
                let mut i = pos + 1;
                while i < line.len() && line[i] == b'#' {
                    i += 1;
                }
                if i < line.len() && line[i] == b'"' {
                    Some(i - pos + 1)
                } else {
                    None
                }
            } else {
                None
            }
        }
        RawKind::None => None,
    }
}

/// Aggregate per-file counts, sorted by code lines descending
/// (largest first), then by file count descending, then by language name.
pub fn aggregate(
    files: impl IntoIterator<Item = (String, FileCount)>,
) -> Vec<(String, LangAgg)> {
    let mut map: BTreeMap<String, LangAgg> = BTreeMap::new();
    for (lang, fc) in files {
        let agg = map.entry(lang).or_default();
        agg.files += 1;
        agg.lines += fc.lines;
        agg.blanks += fc.blanks;
        agg.comments += fc.comments;
        agg.code += fc.code;
        agg.tokens += fc.tokens;
    }
    let mut rows: Vec<(String, LangAgg)> = map.into_iter().collect();
    rows.sort_by(|a, b| {
        b.1.code
            .cmp(&a.1.code)
            .then_with(|| b.1.files.cmp(&a.1.files))
            .then_with(|| a.0.cmp(&b.0))
    });
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::LANGUAGES;

    fn find_lang(name: &str) -> LangSpec {
        *LANGUAGES
            .iter()
            .find(|l| l.name == name || l.aliases.contains(&name))
            .expect("lang not found")
    }

    #[test]
    fn test_c_code() {
        let code = b"/* header */\nint main() {\n    // comment\n\
                     return 0; // trailing\n}\n\n";
        let fc = count_file(code, &find_lang("c"), 0);
        assert_eq!(fc.lines, 6);
        assert_eq!(fc.blanks, 1);
        assert_eq!(fc.comments, 2);
        assert_eq!(fc.code, 3);
        // File without a trailing newline
        let fc2 = count_file(
            b"/* header */\nint main() {\n    // comment\n\
             return 0; // trailing\n}",
            &find_lang("c"),
            0,
        );
        assert_eq!(fc2.lines, 5);
        assert_eq!(fc2.blanks, 0);
        assert_eq!(fc2.comments, 2);
        assert_eq!(fc2.code, 3);
    }

    #[test]
    fn test_multiline_block() {
        let code = b"/* line1\nline2 */\nint x;\n";
        let fc = count_file(code, &find_lang("c"), 0);
        assert_eq!(fc.comments, 2);
        assert_eq!(fc.code, 1);
        assert_eq!(fc.lines, 3);
    }

    #[test]
    fn test_string_not_comment() {
        let code = b"const char* s = \"// not comment\";\nint y;\n";
        let fc = count_file(code, &find_lang("c"), 0);
        assert_eq!(fc.comments, 0);
        assert_eq!(fc.code, 2);
    }

    #[test]
    fn test_python() {
        let code = b"# comment\ns = '''multi\nline'''\n";
        let fc = count_file(code, &find_lang("python"), 0);
        assert_eq!(fc.comments, 1);
        assert_eq!(fc.code, 2);
        assert_eq!(fc.lines, 3);
    }

    #[test]
    fn test_rust_raw() {
        let code = b"let s = r#\"\n// not a comment\nraw\"#;\n";
        let fc = count_file(code, &find_lang("rust"), 0);
        assert_eq!(fc.comments, 0);
        assert_eq!(fc.code, 3);
    }

    #[test]
    fn test_cpp_raw() {
        let code = b"auto s = R\"(\n// not comment\n)\";\n";
        let fc = count_file(code, &find_lang("cpp"), 0);
        assert_eq!(fc.comments, 0);
        assert_eq!(fc.code, 3);
    }

    #[test]
    fn test_blank_line_inside_strings() {
        // Rust raw string: blank lines inside count as code, not blank
        let code = b"let s = r#\"\n\n\n\"#;\n";
        let fc = count_file(code, &find_lang("rust"), 0);
        assert_eq!(fc.lines, 4);
        assert_eq!(fc.blanks, 0);
        assert_eq!(fc.comments, 0);
        assert_eq!(fc.code, 4);
        // Python triple-quoted string: blank lines inside count as code
        let code = b"s = \"\"\"\n\nx\n\"\"\"\n";
        let fc = count_file(code, &find_lang("python"), 0);
        assert_eq!(fc.lines, 4);
        assert_eq!(fc.blanks, 0);
        assert_eq!(fc.comments, 0);
        assert_eq!(fc.code, 4);
    }

    #[test]
    fn test_blank_line_inside_block_comment() {
        // Blank lines inside a block comment count as comments
        let code = b"/* a\n\nb */\n";
        let fc = count_file(code, &find_lang("c"), 0);
        assert_eq!(fc.lines, 3);
        assert_eq!(fc.blanks, 0);
        assert_eq!(fc.comments, 3);
        assert_eq!(fc.code, 0);
    }

    #[test]
    fn test_nested_swift() {
        let code = b"/* outer /* inner */ still */\nlet x = 1\n";
        let fc = count_file(code, &find_lang("swift"), 0);
        assert_eq!(fc.comments, 1);
        assert_eq!(fc.code, 1);
    }
}
