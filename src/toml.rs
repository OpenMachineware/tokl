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
//! Minimal TOML parser - only the subset used by tokl config files:
//! top-level key-value pairs: `key = "string"`, `key = ["a", "b", ...]`,
//! `key = true/false`, `key = 123`. Supports `#` comments and blank lines.
//! No inline tables / nested tables.

#[derive(Debug, Clone, Default)]
pub struct MiniToml {
    entries: Vec<(String, TomlValue)>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TomlValue {
    String(String),
    Bool(bool),
    Int(i64),
    StrArray(Vec<String>),
}

impl MiniToml {
    pub fn parse(text: &str) -> Result<MiniToml, String> {
        let mut entries = Vec::new();
        for (lineno, raw) in text.lines().enumerate() {
            let line = strip_comment(raw).trim();
            if line.is_empty() {
                continue;
            }
            // Ignore type errors for unknown keys, but record errors
            let eq = line.find('=').ok_or_else(|| {
                format!("line {}: missing '=': {}", lineno + 1, raw.trim())
            })?;
            let key = line[..eq].trim();
            let val = line[eq + 1..].trim();
            if key.is_empty() || val.is_empty() {
                return Err(format!(
                    "line {}: missing key or value",
                    lineno + 1
                ));
            }
            let value = parse_value(val, lineno + 1)?;
            entries.push((key.to_string(), value));
        }
        Ok(MiniToml { entries })
    }

    pub fn get_str(&self, key: &str) -> Option<String> {
        self.entries.iter().find(|(k, _)| k == key).and_then(|(_, v)| match v {
            TomlValue::String(s) => Some(s.clone()),
            _ => None,
        })
    }

    pub fn get_str_array(&self, key: &str) -> Option<Vec<String>> {
        self.entries.iter().find(|(k, _)| k == key).and_then(|(_, v)| match v {
            TomlValue::StrArray(a) => Some(a.clone()),
            _ => None,
        })
    }
}

fn strip_comment(line: &str) -> &str {
    // Strip only '#' outside strings
    let bytes = line.as_bytes();
    let mut in_str = false;
    let mut escape = false;
    for (i, &b) in bytes.iter().enumerate() {
        if in_str {
            if escape {
                escape = false;
            } else if b == b'\\' {
                escape = true;
            } else if b == b'"' {
                in_str = false;
            }
        } else if b == b'"' {
            in_str = true;
        } else if b == b'#' {
            return &line[..i];
        }
    }
    line
}

fn parse_value(raw: &str, lineno: usize) -> Result<TomlValue, String> {
    let raw = raw.trim();
    if let Some(rest) = raw.strip_prefix('[') {
        let inner = rest
            .strip_suffix(']')
            .ok_or_else(|| format!("line {}: array missing ']'", lineno))?;
        let mut arr = Vec::new();
        for item in inner.split(',') {
            let item = item.trim();
            if item.is_empty() {
                continue;
            }
            let s = item
                .strip_prefix('"')
                .and_then(|r| r.strip_suffix('"'))
                .ok_or_else(|| {
                    format!(
                        "line {}: array items must be strings: {}",
                        lineno, item
                    )
                })?;
            arr.push(unquote(s));
        }
        return Ok(TomlValue::StrArray(arr));
    }
    if let Some(s) = raw.strip_prefix('"') {
        let s = s.strip_suffix('"').ok_or_else(|| {
            format!("line {}: string missing closing quote", lineno)
        })?;
        return Ok(TomlValue::String(unquote(s)));
    }
    if raw == "true" {
        return Ok(TomlValue::Bool(true));
    }
    if raw == "false" {
        return Ok(TomlValue::Bool(false));
    }
    if let Ok(i) = raw.parse::<i64>() {
        return Ok(TomlValue::Int(i));
    }
    Err(format!("line {}: unrecognized value: {}", lineno, raw))
}

fn unquote(s: &str) -> String {
    // Handle \n \t \" \\ escapes
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic() {
        let toml = MiniToml::parse(
            r#"
# Default model
default_model = "deepseek-v3"
default_format = "table"
default_ignore_dirs = ["node_modules", "target"]
default_exts = ["rs", "py"]
"#,
        )
        .unwrap();
        assert_eq!(toml.get_str("default_model").unwrap(), "deepseek-v3");
        assert_eq!(
            toml.get_str_array("default_ignore_dirs").unwrap(),
            vec!["node_modules", "target"]
        );
    }
}
