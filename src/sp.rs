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
//! SentencePiece engine (Gemini/Gemma, Grok, Kimi, Mistral, Llama 2,
//! Hunyuan, ...).
//!
//! Encoding flow (approximating sentencepiece's Encode):
//! 1. Replace spaces (0x20) with ▁ (U+2581)
//! 2. Split words on other whitespace
//! 3. Viterbi max-score path per word (piece match + byte fallback)

use std::collections::HashMap;

use crate::proto::{SP_BYTE, SP_NORMAL, SP_UNKNOWN};
use crate::util::FastBuildHasher;

const U2581: &[u8] = &[0xEF, 0x96, 0x81]; // UTF-8 encoding of ▁

pub struct SpTokenizer {
    /// piece bytes -> score
    lookup: HashMap<Vec<u8>, f32, FastBuildHasher>,
    /// <0xXX> byte piece table
    byte_lookup: HashMap<u8, f32, FastBuildHasher>,
    unk_score: Option<f32>,
    max_len: usize,
}

impl SpTokenizer {
    /// Build from the raw bytes of a tokenizer.model.
    pub fn from_model_bytes(data: &[u8]) -> Option<SpTokenizer> {
        let pieces = crate::proto::parse_model(data).ok()?;
        let mut lookup: HashMap<Vec<u8>, f32, FastBuildHasher> =
            HashMap::with_hasher(FastBuildHasher);
        let mut byte_lookup: HashMap<u8, f32, FastBuildHasher> =
            HashMap::with_hasher(FastBuildHasher);
        let mut unk_score = None;
        let mut max_len = 1usize;
        for p in pieces {
            match p.typ {
                SP_NORMAL => {
                    max_len = max_len.max(p.piece.len());
                    lookup.insert(p.piece.clone(), p.score);
                }
                SP_BYTE => {
                    if let Some(b) = parse_byte_piece(&p.piece) {
                        byte_lookup.insert(b, p.score);
                    }
                }
                SP_UNKNOWN => unk_score = Some(p.score),
                _ => {}
            }
        }
        if lookup.is_empty() {
            return None;
        }
        Some(SpTokenizer { lookup, byte_lookup, unk_score, max_len })
    }

    /// Count tokens.
    pub fn count(&self, text: &[u8]) -> u64 {
        let mut total: u64 = 0;
        let mut word: Vec<u8> = Vec::with_capacity(64);
        let mut in_word = false;

        for &b in text {
            if b == b' ' {
                word.extend_from_slice(U2581);
                in_word = true;
            } else if is_ws(b) {
                if in_word {
                    total += self.encode_word(&word);
                    word.clear();
                    in_word = false;
                }
            } else {
                word.push(b);
                in_word = true;
            }
        }
        if in_word {
            total += self.encode_word(&word);
        }
        total
    }

    /// Viterbi max-score split of a single word.
    fn encode_word(&self, word: &[u8]) -> u64 {
        let n = word.len();
        if n == 0 {
            return 0;
        }
        // Chunk very long words to avoid a slow worst case
        const CHUNK: usize = 2048;
        if n > CHUNK {
            let mut total = 0u64;
            let mut start = 0usize;
            while start < n {
                let end = (start + CHUNK).min(n);
                total += self.encode_word(&word[start..end]);
                start = end;
            }
            return total;
        }

        let neg_inf = f32::NEG_INFINITY;
        let mut dp = vec![neg_inf; n + 1];
        let mut cnt = vec![0u64; n + 1];
        dp[0] = 0.0;

        for i in 0..n {
            if dp[i] == neg_inf {
                continue;
            }
            let maxl = (n - i).min(self.max_len);
            // Normal pieces (longer first; keep the longer on ties)
            for l in (1..=maxl).rev() {
                if let Some(&s) = self.lookup.get(&word[i..i + l]) {
                    let j = i + l;
                    let cand = dp[i] + s;
                    if dp[j] == neg_inf || cand > dp[j] {
                        dp[j] = cand;
                        cnt[j] = cnt[i] + 1;
                    }
                }
            }
            // Byte fallback: <0xXX>
            if let Some(&s) = self.byte_lookup.get(&word[i]) {
                let j = i + 1;
                let cand = dp[i] + s;
                if dp[j] == neg_inf || cand > dp[j] {
                    dp[j] = cand;
                    cnt[j] = cnt[i] + 1;
                }
            } else if let Some(unk) = self.unk_score {
                let j = i + 1;
                let cand = dp[i] + unk;
                if dp[j] == neg_inf || cand > dp[j] {
                    dp[j] = cand;
                    cnt[j] = cnt[i] + 1;
                }
            }
        }

        if cnt[n] > 0 {
            cnt[n]
        } else {
            // Fallback: approximate by bytes/4 when nothing matches
            ((n as u64) + 3) / 4
        }
    }
}

fn is_ws(b: u8) -> bool {
    matches!(b, b'\t' | b'\n' | b'\r' | 0x0b | 0x0c)
}

/// Parse a `<0xAB>`-style byte piece.
fn parse_byte_piece(piece: &[u8]) -> Option<u8> {
    let s = std::str::from_utf8(piece).ok()?;
    let s = s.trim();
    let hex = s.strip_prefix("<0x")?.strip_suffix('>')?;
    u8::from_str_radix(hex, 16).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_byte_piece() {
        assert_eq!(parse_byte_piece(b"<0x00>"), Some(0));
        assert_eq!(parse_byte_piece(b"<0xff>"), Some(255));
        assert_eq!(parse_byte_piece(b"<0xAB>"), Some(0xAB));
        assert_eq!(parse_byte_piece(b"hello"), None);
    }
}
