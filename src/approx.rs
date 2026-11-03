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
//! Approximate tokenizer: heuristic estimate when no vocab is available.
//!
//! BPE-style tokenizers use roughly 1 token per 4 bytes for English/code;
//! CJK text is roughly 1 token per character; other multi-byte characters
//! (Hangul, kana, emoji, ...) are prorated by byte count. Error is usually
//! within ±20%, giving a reasonable estimate without a local vocab.

#[derive(Debug, Clone, Copy)]
pub struct ApproxParams {
    /// Approximate tokens per CJK character
    pub cjk_per_char: f64,
    /// Bytes of ASCII/Latin text per token
    pub ascii_div: f64,
}

impl Default for ApproxParams {
    fn default() -> Self {
        ApproxParams { cjk_per_char: 1.0, ascii_div: 4.0 }
    }
}

/// Whether a character is CJK.
fn is_cjk(c: char) -> bool {
    matches!(
        c,
        '\u{4E00}'..='\u{9FFF}'        // Basic block
        | '\u{3400}'..='\u{4DBF}'      // Extension A
        | '\u{20000}'..='\u{2A6DF}'    // Extension B
        | '\u{2A700}'..='\u{2B73F}'    // Extension C
        | '\u{2B740}'..='\u{2B81F}'    // Extension D
        | '\u{F900}'..='\u{FAFF}'      // Compatibility ideographs
        | '\u{3007}'                   // 〇 (ideographic zero)
    )
}

/// Approximate token count.
pub fn count_approx(data: &[u8], params: &ApproxParams) -> u64 {
    let mut tokens = 0.0f64;
    let mut ascii_count = 0u64;
    let mut ascii_tokens = 0.0f64;

    let s = match std::str::from_utf8(data) {
        Ok(s) => s,
        // Not UTF-8: prorate by bytes
        Err(_) => {
            let mut n = 0.0f64;
            let mut ascii = 0u64;
            for &b in data {
                if b.is_ascii() {
                    ascii += 1;
                } else {
                    n += 0.5;
                }
            }
            return (n + ascii as f64 / params.ascii_div).floor() as u64;
        }
    };

    for c in s.chars() {
        if c.is_ascii() {
            ascii_count += 1;
            if ascii_count >= 4096 {
                ascii_tokens += ascii_count as f64 / params.ascii_div;
                ascii_count = 0;
            }
        } else if is_cjk(c) {
            tokens += params.cjk_per_char;
        } else {
            tokens += c.len_utf8() as f64 / 2.0;
        }
    }
    ascii_tokens += ascii_count as f64 / params.ascii_div;
    tokens += ascii_tokens;
    tokens.floor() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_english() {
        let p = ApproxParams::default();
        // 16 ASCII bytes -> 4 tokens
        assert_eq!(count_approx(b"hello world hello x", &p), 4);
    }

    #[test]
    fn test_chinese() {
        let p = ApproxParams::default();
        // 4 CJK characters -> 4 tokens
        assert_eq!(
            count_approx("\u{4f60}\u{597d}\u{4e16}\u{754c}".as_bytes(), &p),
            4
        );
    }
}
