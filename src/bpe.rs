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
//! Byte-level BPE engine (tiktoken / GPT family, Qwen, DeepSeek, GLM, ...).
//!
//! After loading the vocab, run rank-based greedy BPE merging over the whole
//! UTF-8 byte stream (matching tiktoken's byte_pair_merge, O(n log n) with a
//! priority queue).

use std::collections::{BinaryHeap, HashMap};
use std::path::Path;

use crate::json::Value;
use crate::util::base64_decode;

pub struct BpeTokenizer {
    /// token bytes -> rank (lower merges first; 0-255 are single bytes)
    ranks: HashMap<Vec<u8>, u32>,
}

impl BpeTokenizer {
    /// Load from a .tiktoken file (each line: base64 token + rank).
    pub fn from_tiktoken_file(path: &Path) -> Option<BpeTokenizer> {
        let text = std::fs::read_to_string(path).ok()?;
        let mut ranks = HashMap::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let mut parts = line.split_whitespace();
            let (b64, rank_str) = (parts.next()?, parts.next()?);
            let rank = rank_str.parse::<u32>().ok()?;
            let bytes = base64_decode(b64)?;
            ranks.insert(bytes, rank);
        }
        if ranks.is_empty() {
            return None;
        }
        Some(BpeTokenizer { ranks })
    }

    /// Load from a HuggingFace tokenizer.json (model.vocab + model.merges).
    pub fn from_tokenizer_json(path: &Path) -> Option<BpeTokenizer> {
        let text = std::fs::read_to_string(path).ok()?;
        let v = crate::json::parse(&text).ok()?;
        let model = v.get("model")?;
        let vocab = model.get("vocab")?;
        Self::from_vocab(vocab)
    }

    /// Build from the model.vocab object of a tokenizer.json.
    fn from_vocab(vocab: &Value) -> Option<BpeTokenizer> {
        let Value::Obj(fields) = vocab else {
            return None;
        };
        let mut ranks = HashMap::new();
        for (tok, id) in fields {
            let id = id.as_num()? as u32;
            ranks.insert(tok.as_bytes().to_vec(), id);
        }
        if ranks.is_empty() {
            return None;
        }
        Some(BpeTokenizer { ranks })
    }

    /// Count tokens (run BPE merging over the whole byte stream).
    pub fn count(&self, data: &[u8]) -> u64 {
        let n = data.len();
        if n == 0 {
            return 0;
        }
        if n == 1 {
            return 1;
        }

        // parts[i] = [start, end), byte range
        let mut parts: Vec<[usize; 2]> = (0..n).map(|i| [i, i + 1]).collect();
        // Linked list (by original index)
        let mut next: Vec<Option<usize>> =
            (1..n).map(Some).chain(std::iter::once(None)).collect();
        let mut prev: Vec<Option<usize>> =
            (0..n).map(|i| if i == 0 { None } else { Some(i - 1) }).collect();
        let mut versions: Vec<u32> = vec![0; n];

        // min-heap: (rank, left part index, version)
        let mut heap: BinaryHeap<std::cmp::Reverse<(u32, usize, u32)>> =
            BinaryHeap::new();
        for i in 0..n - 1 {
            if let Some(&r) = self.ranks.get(&data[i..i + 2]) {
                heap.push(std::cmp::Reverse((r, i, 0)));
            }
        }

        let mut merged: u64 = 0;
        while let Some(std::cmp::Reverse((rank, i, ver))) = heap.pop() {
            if ver != versions[i] {
                continue;
            }
            let Some(j) = next[i] else { continue };
            let a = parts[i][0];
            let c = parts[j][1];
            // Check content still matches rank (skip stale entries)
            if self.ranks.get(&data[a..c]) != Some(&rank) {
                continue;
            }
            // Merge i and j
            versions[i] += 1;
            parts[i][1] = c;
            next[i] = next[j];
            if let Some(nj) = next[j] {
                prev[nj] = Some(i);
            }
            merged += 1;

            // Left neighbor (prev[i], i)
            if let Some(k) = prev[i] {
                let b = parts[k][0];
                let e = parts[i][1];
                if let Some(&r) = self.ranks.get(&data[b..e]) {
                    heap.push(std::cmp::Reverse((r, k, versions[k])));
                }
            }
            // Right neighbor (i, next[i])
            if let Some(ni) = next[i] {
                let b = parts[i][0];
                let e = parts[ni][1];
                if let Some(&r) = self.ranks.get(&data[b..e]) {
                    versions[i] += 1;
                    heap.push(std::cmp::Reverse((r, i, versions[i])));
                }
            }
        }

        (n as u64) - merged
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty() {
        let t = BpeTokenizer { ranks: HashMap::new() };
        assert_eq!(t.count(b""), 0);
    }

    #[test]
    fn test_simple_vocab() {
        // Tiny vocab: single bytes + "ab" + "cd"
        let mut ranks = HashMap::new();
        for b in 0u8..=255 {
            ranks.insert(vec![b], b as u32);
        }
        ranks.insert(b"ab".to_vec(), 256);
        ranks.insert(b"cd".to_vec(), 257);
        let t = BpeTokenizer { ranks };
        // "abcd" -> "ab" + "cd" = 2 tokens
        assert_eq!(t.count(b"abcd"), 2);
        // "axcd" -> 'a','x',"cd" = 3
        assert_eq!(t.count(b"axcd"), 3);
    }
}
