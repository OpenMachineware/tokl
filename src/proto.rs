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
//! Minimal protobuf wire parser - only used to read SentencePiece's
//! tokenizer.model.
//!
//! ModelProto structure (relevant parts):
//!   repeated SentencePiece pieces = 1;
//!   SentencePiece { string piece = 1; float score = 2;
//!     enum Type { NORMAL=1; UNKNOWN=2; CONTROL=3; USER_DEFINED=4;
//!                 UNUSED=5; BYTE=6; } type = 3; }

/// A single SentencePiece.
#[derive(Debug, Clone)]
pub struct SentencePiece {
    pub piece: Vec<u8>,
    pub score: f32,
    pub typ: u32,
}

pub const SP_NORMAL: u32 = 1;
pub const SP_UNKNOWN: u32 = 2;
pub const SP_BYTE: u32 = 6;

/// Parse ModelProto and return all pieces.
pub fn parse_model(data: &[u8]) -> Result<Vec<SentencePiece>, String> {
    let mut pieces = Vec::new();
    let mut pos = 0usize;
    while pos < data.len() {
        let (tag, new_pos) = read_varint(data, pos)?;
        pos = new_pos;
        let field = tag >> 3;
        let wire = tag & 0x7;
        match wire {
            0 => {
                let (_, np) = read_varint(data, pos)?;
                pos = np;
            }
            1 => {
                pos += 8;
                if pos > data.len() {
                    return Err("truncated protobuf (fixed64)".into());
                }
            }
            2 => {
                let (len, np) = read_varint(data, pos)?;
                pos = np;
                let end = pos + len as usize;
                if end > data.len() {
                    return Err("truncated protobuf (len-delimited)".into());
                }
                if field == 1 {
                    pieces.push(parse_sentence_piece(&data[pos..end])?);
                }
                pos = end;
            }
            5 => {
                pos += 4;
                if pos > data.len() {
                    return Err("truncated protobuf (fixed32)".into());
                }
            }
            other => return Err(format!("unsupported wire type: {}", other)),
        }
    }
    Ok(pieces)
}

fn parse_sentence_piece(data: &[u8]) -> Result<SentencePiece, String> {
    let mut piece = Vec::new();
    let mut score = 0.0f32;
    let mut typ = SP_NORMAL;
    let mut pos = 0usize;
    while pos < data.len() {
        let (tag, np) = read_varint(data, pos)?;
        pos = np;
        let field = tag >> 3;
        let wire = tag & 0x7;
        match (field, wire) {
            (1, 2) => {
                let (len, np) = read_varint(data, pos)?;
                pos = np;
                let end = pos + len as usize;
                if end > data.len() {
                    return Err("truncated piece".into());
                }
                piece = data[pos..end].to_vec();
                pos = end;
            }
            (2, 5) => {
                if pos + 4 > data.len() {
                    return Err("truncated score".into());
                }
                score =
                    f32::from_le_bytes(data[pos..pos + 4].try_into().unwrap());
                pos += 4;
            }
            (3, 0) => {
                let (v, np) = read_varint(data, pos)?;
                pos = np;
                typ = v as u32;
            }
            (_, 0) => {
                let (_, np) = read_varint(data, pos)?;
                pos = np;
            }
            (_, 1) => pos += 8,
            (_, 5) => pos += 4,
            (_, 2) => {
                let (len, np) = read_varint(data, pos)?;
                pos = np + len as usize;
            }
            other => {
                return Err(format!("unsupported field in piece: {:?}", other))
            }
        }
    }
    Ok(SentencePiece { piece, score, typ })
}

fn read_varint(data: &[u8], mut pos: usize) -> Result<(u64, usize), String> {
    let mut result: u64 = 0;
    let mut shift = 0u32;
    loop {
        if pos >= data.len() {
            return Err("truncated varint".into());
        }
        let b = data[pos];
        pos += 1;
        result |= ((b & 0x7f) as u64) << shift;
        if b & 0x80 == 0 {
            return Ok((result, pos));
        }
        shift += 7;
        if shift >= 64 {
            return Err("varint too long".into());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_varint() {
        let data = [0x96, 0x01];
        assert_eq!(read_varint(&data, 0).unwrap(), (150, 2));
    }
}
