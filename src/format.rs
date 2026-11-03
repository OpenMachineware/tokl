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
//! Output formatting: table (scc style) / markdown / json.
//!
//! Column order: Language, Files, Tokens, Lines, Blanks, Comments, Code
//! (Tokens sits between Files and Lines; no Complexity column).

use crate::count::LangAgg;
use crate::util::thousands;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Table,
    Markdown,
    Json,
}

impl Format {
    pub fn from_str(s: &str) -> Result<Format, String> {
        match s.trim().to_ascii_lowercase().as_str() {
            "table" => Ok(Format::Table),
            "markdown" | "md" => Ok(Format::Markdown),
            "json" => Ok(Format::Json),
            other => Err(format!(
                "unknown output format '{}' \
                 (supported: table | markdown | json)",
                other
            )),
        }
    }
}

const HEADERS: [&str; 7] =
    ["Language", "Files", "Tokens", "Lines", "Blanks", "Comments", "Code"];

/// Render statistics. model is used for json metadata.
pub fn render(
    rows: &[(String, LangAgg)],
    total: &LangAgg,
    fmt: Format,
    model: &str,
) -> String {
    match fmt {
        Format::Table => render_table(rows, total),
        Format::Markdown => render_markdown(rows, total),
        Format::Json => render_json(rows, total, model),
    }
}

fn cell_values(a: &LangAgg) -> [String; 6] {
    [
        thousands(a.files),
        thousands(a.tokens),
        thousands(a.lines),
        thousands(a.blanks),
        thousands(a.comments),
        thousands(a.code),
    ]
}

fn render_table(rows: &[(String, LangAgg)], total: &LangAgg) -> String {
    let mut widths = [0usize; 7];
    for (i, h) in HEADERS.iter().enumerate() {
        widths[i] = h.len();
    }
    for (lang, a) in rows {
        widths[0] = widths[0].max(lang.len());
        let cells = cell_values(a);
        for (i, c) in cells.iter().enumerate() {
            widths[i + 1] = widths[i + 1].max(c.len());
        }
    }
    {
        let cells = cell_values(total);
        for (i, c) in cells.iter().enumerate() {
            widths[i + 1] = widths[i + 1].max(c.len());
        }
    }

    // Column gap of 3 spaces
    let sep_width = widths.iter().sum::<usize>() + (widths.len() - 1) * 3;
    let sep: String = "─".repeat(sep_width);

    let mut out = String::new();
    // Header
    let mut line = String::new();
    line.push_str(&format!("{:<w$}", HEADERS[0], w = widths[0]));
    for i in 1..7 {
        line.push_str(&format!("   {:>w$}", HEADERS[i], w = widths[i]));
    }
    out.push_str(line.trim_end());
    out.push('\n');
    out.push_str(&sep);
    out.push('\n');

    for (lang, a) in rows {
        let mut line = String::new();
        line.push_str(&format!("{:<w$}", lang, w = widths[0]));
        let cells = cell_values(a);
        for (i, c) in cells.iter().enumerate() {
            line.push_str(&format!("   {:>w$}", c, w = widths[i + 1]));
        }
        out.push_str(line.trim_end());
        out.push('\n');
    }

    out.push_str(&sep);
    out.push('\n');
    let mut line = String::new();
    line.push_str(&format!("{:<w$}", "Total", w = widths[0]));
    let cells = cell_values(total);
    for (i, c) in cells.iter().enumerate() {
        line.push_str(&format!("   {:>w$}", c, w = widths[i + 1]));
    }
    out.push_str(line.trim_end());
    out.push('\n');
    out.push_str(&sep);
    out.push('\n');

    out
}

fn render_markdown(rows: &[(String, LangAgg)], total: &LangAgg) -> String {
    let mut out = String::new();
    out.push('|');
    for h in HEADERS {
        out.push(' ');
        out.push_str(h);
        out.push_str(" |");
    }
    out.push('\n');
    out.push('|');
    for h in HEADERS {
        let _ = h;
        out.push_str(" --- |");
    }
    out.push('\n');
    for (lang, a) in rows {
        out.push('|');
        out.push(' ');
        out.push_str(lang);
        out.push_str(" |");
        for c in cell_values(a) {
            out.push(' ');
            out.push_str(&c);
            out.push_str(" |");
        }
        out.push('\n');
    }
    out.push('|');
    out.push_str(" **Total** |");
    for c in cell_values(total) {
        out.push(' ');
        out.push_str(&c);
        out.push_str(" |");
    }
    out.push('\n');
    out
}

fn render_json(
    rows: &[(String, LangAgg)],
    total: &LangAgg,
    model: &str,
) -> String {
    let mut out = String::new();
    out.push_str("{\n");
    out.push_str(&format!(
        "  \"tool\": \"tokl\",\n  \"version\": \"{}\",\n  \"model\": {},\n",
        env!("CARGO_PKG_VERSION"),
        json_str(model)
    ));
    out.push_str("  \"languages\": [\n");
    for (i, (lang, a)) in rows.iter().enumerate() {
        out.push_str("    {\n");
        out.push_str(&format!("      \"language\": {},\n", json_str(lang)));
        out.push_str(&format!("      \"files\": {},\n", a.files));
        out.push_str(&format!("      \"tokens\": {},\n", a.tokens));
        out.push_str(&format!("      \"lines\": {},\n", a.lines));
        out.push_str(&format!("      \"blanks\": {},\n", a.blanks));
        out.push_str(&format!("      \"comments\": {},\n", a.comments));
        out.push_str(&format!("      \"code\": {}\n", a.code));
        out.push_str("    }");
        if i + 1 < rows.len() {
            out.push(',');
        }
        out.push('\n');
    }
    out.push_str("  ],\n");
    out.push_str("  \"total\": {\n");
    out.push_str(&format!("    \"files\": {},\n", total.files));
    out.push_str(&format!("    \"tokens\": {},\n", total.tokens));
    out.push_str(&format!("    \"lines\": {},\n", total.lines));
    out.push_str(&format!("    \"blanks\": {},\n", total.blanks));
    out.push_str(&format!("    \"comments\": {},\n", total.comments));
    out.push_str(&format!("    \"code\": {}\n", total.code));
    out.push_str("  }\n");
    out.push_str("}\n");
    out
}

/// Render a JSON string literal (with escaping).
fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32))
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
