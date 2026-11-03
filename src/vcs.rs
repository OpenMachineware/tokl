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
//! Version-control integration: detect whether the scan roots live inside
//! a git / svn / hg / bzr / fossil repository and apply the repository's
//! ignore rules (`.gitignore` etc.) on top of the `-i` / config ignores.
//!
//! Matching follows the gitignore specification (a superset used by most
//! tools): blank lines and `#` comments are skipped, `!` negates, a
//! trailing `/` restricts to directories, patterns containing `/` are
//! anchored to the ignore file's directory, and `*` / `?` / `[...]` /
//! `**` globs are supported. Mercurial's `.hgignore` defaults to regular
//! expressions, which are not implemented; only its `syntax: glob` rules
//! are honored.

use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};

/// Version-control systems we can detect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VcsKind {
    Git,
    Svn,
    Hg,
    Bzr,
    Fossil,
}

const ALL_KINDS: [VcsKind; 5] =
    [VcsKind::Git, VcsKind::Hg, VcsKind::Svn, VcsKind::Bzr, VcsKind::Fossil];

impl VcsKind {
    pub fn name(self) -> &'static str {
        match self {
            VcsKind::Git => "git",
            VcsKind::Svn => "svn",
            VcsKind::Hg => "hg",
            VcsKind::Bzr => "bzr",
            VcsKind::Fossil => "fossil",
        }
    }

    /// Entries that identify a repository root (a `.git` entry may be a
    /// file for worktrees/submodules, hence `exists` rather than `is_dir`).
    fn markers(self) -> &'static [&'static str] {
        match self {
            VcsKind::Git => &[".git"],
            VcsKind::Svn => &[".svn"],
            VcsKind::Hg => &[".hg"],
            VcsKind::Bzr => &[".bzr"],
            VcsKind::Fossil => &[".fslckout", ".fossil-settings"],
        }
    }

    /// Ignore files to read from the repository root.
    fn ignore_files(self) -> &'static [&'static str] {
        match self {
            VcsKind::Git => &[".gitignore"],
            VcsKind::Svn => &[".svnignore"],
            VcsKind::Hg => &[".hgignore"],
            VcsKind::Bzr => &[".bzrignore"],
            VcsKind::Fossil => &[".ignore"],
        }
    }
}

/// One compiled ignore pattern (a single line of an ignore file).
#[derive(Debug, Clone)]
struct IgnorePattern {
    negated: bool,
    dir_only: bool,
    anchored: bool,
    segs: Vec<String>,
}

impl IgnorePattern {
    fn parse(line: &str) -> Option<IgnorePattern> {
        let text = unescape(line);
        if text.is_empty() || text.starts_with('#') {
            return None;
        }
        let (negated, rest) = match text.strip_prefix('!') {
            Some(r) => (true, r),
            None => (false, text.as_str()),
        };
        let (dir_only, rest) = match rest.strip_suffix('/') {
            Some(r) => (true, r),
            None => (false, rest),
        };
        if rest.is_empty() {
            return None;
        }
        let leading_slash = rest.starts_with('/');
        let pat = rest.trim_start_matches('/');
        if pat.is_empty() {
            return None;
        }
        let anchored = leading_slash || pat.contains('/');
        let segs: Vec<String> = pat.split('/').map(|s| s.to_string()).collect();
        Some(IgnorePattern { negated, dir_only, anchored, segs })
    }

    /// Whether this pattern matches `rel` (path relative to the ignore
    /// file's directory), which is a directory when `is_dir`.
    fn matches(&self, rel: &[&str], is_dir: bool) -> bool {
        if self.dir_only && !is_dir {
            return false;
        }
        if self.anchored {
            path_match(&self.segs, rel)
        } else {
            // No `/` in the pattern: it matches the basename at any depth.
            match rel.last() {
                Some(b) => glob_match(&self.segs[0], b),
                None => false,
            }
        }
    }

    /// Whether the pattern matches the path itself or any of its ancestor
    /// directories (ignoring a directory ignores its contents).
    fn matches_path_or_ancestor(&self, rel: &[&str], is_dir: bool) -> bool {
        for i in 0..rel.len() {
            let prefix = &rel[..=i];
            let dir = i < rel.len() - 1 || is_dir;
            if self.matches(prefix, dir) {
                return true;
            }
        }
        false
    }
}

/// Ignore rules loaded from one ignore file.
#[derive(Debug, Clone)]
struct IgnoreFile {
    /// Normalized absolute components of the directory holding the file.
    base: Vec<OsString>,
    patterns: Vec<IgnorePattern>,
}

/// Version-control context discovered for the scan roots.
#[derive(Debug, Clone, Default)]
pub struct VcsContext {
    /// Detected repositories: (kind, root path).
    pub repos: Vec<(VcsKind, PathBuf)>,
    /// Distinct kinds detected.
    pub kinds: Vec<VcsKind>,
    /// Whether any loaded pattern is a negation (`!pattern`). When false
    /// the scanner can prune ignored directories without losing any
    /// re-inclusions; when true it must descend into them.
    pub has_negations: bool,
    /// Total number of loaded ignore rules.
    pub rule_count: usize,
    files: Vec<IgnoreFile>,
}

impl VcsContext {
    /// Detect repositories containing any of `scan_roots` and load their
    /// ignore files. Returns an empty context when nothing is found.
    pub fn detect(scan_roots: &[String]) -> VcsContext {
        let mut repos: Vec<(VcsKind, PathBuf)> = Vec::new();
        for root in scan_roots {
            let mut dir = abs_path(root);
            if dir.is_file() {
                dir.pop();
            }
            loop {
                for kind in ALL_KINDS {
                    let hit =
                        kind.markers().iter().any(|m| dir.join(m).exists());
                    let known =
                        repos.iter().any(|(k, p)| *k == kind && p == &dir);
                    if hit && !known {
                        repos.push((kind, dir.clone()));
                    }
                }
                if !dir.pop() {
                    break;
                }
            }
        }

        let mut kinds = Vec::new();
        let mut files = Vec::new();
        let mut rule_count = 0;
        for (kind, root) in &repos {
            if !kinds.contains(kind) {
                kinds.push(*kind);
            }
            for fname in kind.ignore_files() {
                let path = root.join(fname);
                if path.is_file() {
                    if let Ok(text) = std::fs::read_to_string(&path) {
                        let patterns = parse_ignore_file(*kind, &text);
                        rule_count += patterns.len();
                        files.push(IgnoreFile {
                            base: normalize(&abs_path(&root.to_string_lossy())),
                            patterns,
                        });
                    }
                }
            }
        }
        let has_negations =
            files.iter().any(|f| f.patterns.iter().any(|p| p.negated));
        VcsContext { repos, kinds, has_negations, rule_count, files }
    }

    /// Whether `path` (a file or directory) is ignored by the loaded rules.
    pub fn should_skip(&self, path: &Path, is_dir: bool) -> bool {
        if self.files.is_empty() {
            return false;
        }
        let comps = normalize(&abs_path(&path.to_string_lossy()));
        for file in &self.files {
            if comps.len() < file.base.len()
                || comps[..file.base.len()] != file.base[..]
            {
                continue;
            }
            let rel: Vec<&str> = comps[file.base.len()..]
                .iter()
                .filter_map(|s| s.to_str())
                .collect();
            if rel.is_empty() {
                continue;
            }
            // A pattern that matches an ancestor directory implicitly
            // ignores everything below it. The last matching pattern
            // (over path or any ancestor) decides, so a later negation
            // can still re-include the path.
            let mut ignored = false;
            for p in &file.patterns {
                if p.matches_path_or_ancestor(&rel, is_dir) {
                    ignored = !p.negated;
                }
            }
            if ignored {
                return true;
            }
        }
        false
    }
}

/// Make `p` absolute (relative paths resolve against the current dir).
fn abs_path(p: &str) -> PathBuf {
    let path = Path::new(p);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

/// Split a path into normalized components, resolving `.` and `..` so that
/// paths built from different relative roots compare consistently.
fn normalize(path: &Path) -> Vec<OsString> {
    let mut stack: Vec<OsString> = Vec::new();
    for c in path.components() {
        match c {
            Component::Prefix(p) => {
                stack.clear();
                stack.push(p.as_os_str().to_os_string());
            }
            Component::RootDir => {
                stack.clear();
                stack.push(c.as_os_str().to_os_string());
            }
            Component::CurDir => {}
            Component::ParentDir => match stack.last() {
                Some(l) if is_root_comp(l) => {}
                Some(l) if l == ".." => stack.push("..".into()),
                Some(_) => {
                    stack.pop();
                }
                None => stack.push("..".into()),
            },
            Component::Normal(s) => stack.push(s.to_os_string()),
        }
    }
    stack
}

fn is_root_comp(s: &std::ffi::OsStr) -> bool {
    let s = s.to_string_lossy();
    s == "/" || (s.ends_with(':') && s.len() <= 3)
}

/// Reverse `\X` escapes and drop unescaped trailing whitespace.
fn unescape(line: &str) -> String {
    let b = line.as_bytes();
    let mut end = b.len();
    while end > 0 {
        let ch = b[end - 1];
        if ch == b' ' || ch == b'\t' {
            if end >= 2 && b[end - 2] == b'\\' {
                break;
            }
            end -= 1;
        } else {
            break;
        }
    }
    let mut out = String::with_capacity(end);
    let bytes = &b[..end];
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            out.push(bytes[i + 1] as char);
            i += 2;
        } else {
            out.push(bytes[i] as char);
            i += 1;
        }
    }
    out
}

/// Parse an ignore file into patterns. `.hgignore` only honors `syntax:
/// glob` rules (its default regexp syntax is not implemented).
fn parse_ignore_file(kind: VcsKind, text: &str) -> Vec<IgnorePattern> {
    let mut patterns = Vec::new();
    match kind {
        VcsKind::Hg => {
            let mut glob = false;
            for line in text.lines() {
                let t = line.trim();
                if t.starts_with("syntax:") {
                    glob = t == "syntax: glob";
                    continue;
                }
                if !glob || t.is_empty() || t.starts_with('#') {
                    continue;
                }
                if let Some(p) = IgnorePattern::parse(t) {
                    patterns.push(p);
                }
            }
        }
        _ => {
            for line in text.lines() {
                if let Some(p) = IgnorePattern::parse(line) {
                    patterns.push(p);
                }
            }
        }
    }
    patterns
}

/// Glob match against a single path segment (no `/` crossing): `*` matches
/// any run of characters, `?` a single one, `[...]` a character class.
fn glob_match(pat: &str, text: &str) -> bool {
    if text.contains('/') {
        return false;
    }
    let units = parse_units(pat);
    let t = text.as_bytes();
    let mut prev = vec![false; t.len() + 1];
    prev[0] = true;
    for u in &units {
        let mut cur = vec![false; t.len() + 1];
        match u {
            Unit::Star => {
                cur[0] = prev[0];
                for j in 1..=t.len() {
                    cur[j] = prev[j] || cur[j - 1];
                }
            }
            Unit::Any => {
                for j in 1..=t.len() {
                    cur[j] = prev[j - 1];
                }
            }
            Unit::Lit(c) => {
                for j in 1..=t.len() {
                    cur[j] = prev[j - 1] && t[j - 1] == *c;
                }
            }
            Unit::Class { neg, ranges } => {
                for j in 1..=t.len() {
                    let c = t[j - 1];
                    let hit = ranges.iter().any(|&(a, z)| c >= a && c <= z);
                    cur[j] = prev[j - 1] && (hit != *neg);
                }
            }
        }
        prev = cur;
    }
    prev[t.len()]
}

/// Segment-wise match of an anchored pattern against a relative path,
/// supporting `**` as "any number of segments".
fn path_match(segs: &[String], rel: &[&str]) -> bool {
    let n = segs.len();
    let m = rel.len();
    if n == 0 {
        return m == 0;
    }
    let mut dp = vec![vec![false; m + 1]; n + 1];
    dp[0][0] = true;
    for i in 1..=n {
        let seg = segs[i - 1].as_str();
        for j in 0..=m {
            if seg == "**" {
                dp[i][j] = dp[i - 1][j] || (j > 0 && dp[i][j - 1]);
            } else if j > 0 {
                dp[i][j] = dp[i - 1][j - 1] && glob_match(seg, rel[j - 1]);
            }
        }
    }
    dp[n][m]
}

#[derive(Debug, Clone)]
enum Unit {
    Lit(u8),
    Any,
    Star,
    Class { neg: bool, ranges: Vec<(u8, u8)> },
}

fn parse_units(pat: &str) -> Vec<Unit> {
    let b = pat.as_bytes();
    let mut units: Vec<Unit> = Vec::new();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'*' => {
                units.push(Unit::Star);
                i += 1;
            }
            b'?' => {
                units.push(Unit::Any);
                i += 1;
            }
            b'[' => {
                let mut j = i + 1;
                let mut neg = false;
                if j < b.len() && (b[j] == b'!' || b[j] == b'^') {
                    neg = true;
                    j += 1;
                }
                let mut ranges: Vec<(u8, u8)> = Vec::new();
                let mut first = true;
                while j < b.len() {
                    if b[j] == b']' && !first {
                        break;
                    }
                    first = false;
                    if j + 2 < b.len() && b[j + 1] == b'-' && b[j + 2] != b']' {
                        ranges.push((b[j], b[j + 2]));
                        j += 3;
                    } else {
                        ranges.push((b[j], b[j]));
                        j += 1;
                    }
                }
                if j < b.len() && b[j] == b']' {
                    units.push(Unit::Class { neg, ranges });
                    i = j + 1;
                } else {
                    units.push(Unit::Lit(b'['));
                    i += 1;
                }
            }
            c => {
                units.push(Unit::Lit(c));
                i += 1;
            }
        }
    }
    units
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_glob_basic() {
        assert!(glob_match("*.rs", "main.rs"));
        assert!(!glob_match("*.rs", "main.py"));
        assert!(glob_match("a?c", "abc"));
        assert!(!glob_match("a?c", "abbc"));
        assert!(glob_match("a[bc]d", "abd"));
        assert!(!glob_match("a[bc]d", "aed"));
        assert!(glob_match("a[!bc]d", "aed"));
        assert!(glob_match("file.*", "file.tar.gz"));
        assert!(!glob_match("*.log", "a/b.log"));
    }

    #[test]
    fn test_path_match_doublestar() {
        let mk =
            |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(path_match(
            &mk(&["**", "node_modules"]),
            &["a", "b", "node_modules"]
        ));
        assert!(path_match(&mk(&["**", "node_modules"]), &["node_modules"]));
        assert!(path_match(&mk(&["foo", "**"]), &["foo", "x", "y"]));
        assert!(path_match(&mk(&["a", "**", "b"]), &["a", "x", "b"]));
        assert!(!path_match(&mk(&["a", "b"]), &["a", "b", "c"]));
        assert!(path_match(&mk(&["a", "b"]), &["a", "b"]));
    }

    #[test]
    fn test_parse_line() {
        let p = IgnorePattern::parse("node_modules").unwrap();
        assert!(!p.negated && !p.anchored && !p.dir_only);
        let p = IgnorePattern::parse("build/").unwrap();
        assert!(p.dir_only && !p.anchored);
        let p = IgnorePattern::parse("!keep.txt").unwrap();
        assert!(p.negated);
        let p = IgnorePattern::parse("/root.txt").unwrap();
        assert!(p.anchored);
        let p = IgnorePattern::parse("docs/*.md").unwrap();
        assert!(p.anchored);
        assert!(IgnorePattern::parse("# comment").is_none());
        assert!(IgnorePattern::parse("").is_none());
    }

    #[test]
    fn test_matches_anchored() {
        let p = IgnorePattern::parse("src/generated").unwrap();
        assert!(p.matches(&["src", "generated"], false));
        assert!(p.matches(&["src", "generated"], true));
        assert!(!p.matches(&["x", "src", "generated"], false));
        let p = IgnorePattern::parse("src/").unwrap();
        assert!(p.dir_only && !p.anchored);
        assert!(p.matches(&["src"], true));
        assert!(!p.matches(&["src"], false));
        // `src/` matches a src directory at any depth (not anchored)
        assert!(p.matches(&["a", "src"], true));
        assert!(!p.matches(&["a", "src"], false));
    }

    #[test]
    fn test_detect_and_ignore() {
        let dir = std::env::temp_dir().join(format!(
            "tokl_vcs_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::create_dir_all(dir.join("target")).unwrap();
        std::fs::write(dir.join("a.log"), "x").unwrap();
        std::fs::write(
            dir.join(".gitignore"),
            "target/\n*.log\n!important.log\n",
        )
        .unwrap();
        let ctx = VcsContext::detect(&[dir.to_string_lossy().to_string()]);
        assert_eq!(ctx.kinds, vec![VcsKind::Git]);
        assert!(ctx.has_negations);
        assert!(ctx.should_skip(&dir.join("target"), true));
        assert!(!ctx.should_skip(&dir.join("target"), false));
        assert!(ctx.should_skip(&dir.join("src").join("a.log"), false));
        assert!(!ctx.should_skip(&dir.join("src").join("important.log"), false));
        assert!(!ctx.should_skip(&dir.join("src").join("main.rs"), false));
        assert!(!ctx.should_skip(&dir.join("src"), false));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn test_negation_reinclude() {
        let dir = std::env::temp_dir().join(format!(
            "tokl_vcs_neg_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::create_dir_all(dir.join("vendor").join("pkg")).unwrap();
        std::fs::write(dir.join(".gitignore"), "vendor/\n!vendor/keep.rs\n")
            .unwrap();
        let ctx = VcsContext::detect(&[dir.to_string_lossy().to_string()]);
        assert!(ctx.has_negations);
        // The vendor directory itself is ignored…
        assert!(ctx.should_skip(&dir.join("vendor"), true));
        // …but the negated file below it is re-included…
        assert!(!ctx.should_skip(&dir.join("vendor").join("keep.rs"), false));
        // …while other files below the ignored directory stay ignored,
        // because ignoring a directory implicitly ignores its contents.
        assert!(ctx.should_skip(
            &dir.join("vendor").join("pkg").join("lib.rs"),
            false
        ));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn test_no_repo_detected() {
        let dir = std::env::temp_dir().join(format!(
            "tokl_vcs_empty_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let ctx = VcsContext::detect(&[dir.to_string_lossy().to_string()]);
        assert!(ctx.kinds.is_empty());
        assert_eq!(ctx.rule_count, 0);
        assert!(!ctx.should_skip(&dir.join("x.rs"), false));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
