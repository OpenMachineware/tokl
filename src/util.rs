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
//! General utilities: base64 decoding, thousands separators,
//! binary detection, etc.

/// Base64 decode (standard alphabet, ignores whitespace).
pub fn base64_decode(s: &str) -> Option<Vec<u8>> {
    const TABLE: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut rev = [255u8; 256];
    for (i, &b) in TABLE.iter().enumerate() {
        rev[b as usize] = i as u8;
    }

    let mut out = Vec::with_capacity(s.len() / 4 * 3);
    let mut acc: u32 = 0;
    let mut nbits = 0u32;
    for &b in s.as_bytes() {
        if b == b' ' || b == b'\t' || b == b'\r' || b == b'\n' {
            continue;
        }
        if b == b'=' {
            break;
        }
        let v = rev[b as usize];
        if v == 255 {
            return None;
        }
        acc = (acc << 6) | v as u32;
        nbits += 6;
        if nbits >= 8 {
            nbits -= 8;
            out.push((acc >> nbits) as u8);
        }
    }
    Some(out)
}

/// Thousands separator: 1234567 -> "1,234,567"
pub fn thousands(n: u64) -> String {
    let s = n.to_string();
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len() + s.len() / 3);
    let digits = bytes.len();
    for (i, &b) in bytes.iter().enumerate() {
        if i > 0 && (digits - i) % 3 == 0 {
            out.push(',');
        }
        out.push(b as char);
    }
    out
}

/// Simple binary detection: a NUL byte in the first 8KB means binary.
pub fn looks_binary(data: &[u8]) -> bool {
    let limit = data.len().min(8192);
    data[..limit].contains(&0)
}

/// A fast, non-cryptographic hasher (FNV-1a).
///
/// The default SipHash guards against hash-flooding attacks, but that is not
/// a concern for tokenizer lookup tables. FNV-1a is several times faster for
/// the short byte keys used here (BPE ranks, SentencePiece pieces), and it
/// keeps the hot counting path allocation-free.
#[derive(Default, Clone, Copy)]
pub struct FastBuildHasher;

impl std::hash::BuildHasher for FastBuildHasher {
    type Hasher = FastHasher;
    fn build_hasher(&self) -> FastHasher {
        FastHasher(0xcbf2_9ce4_8422_2325)
    }
}

pub struct FastHasher(u64);

impl std::hash::Hasher for FastHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        let mut h = self.0;
        for &b in bytes {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x100_0000_01b3);
        }
        self.0 = h;
    }
}

/// File extension (lowercase, no dot). Returns None when absent.
pub fn extension_of(path: &std::path::Path) -> Option<String> {
    let name = path.file_name()?.to_str()?;
    match name.rfind('.') {
        Some(idx) if idx > 0 && idx < name.len() - 1 => {
            Some(name[idx + 1..].to_ascii_lowercase())
        }
        _ => None,
    }
}

/// File name (without the directory).
pub fn file_name_of(path: &std::path::Path) -> String {
    path.file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_base64() {
        assert_eq!(base64_decode("aGVsbG8=").unwrap(), b"hello");
        assert_eq!(base64_decode("aGVsbG8").unwrap(), b"hello");
    }

    #[test]
    fn test_thousands() {
        assert_eq!(thousands(0), "0");
        assert_eq!(thousands(999), "999");
        assert_eq!(thousands(1000), "1,000");
        assert_eq!(thousands(1234567), "1,234,567");
    }

    #[test]
    fn test_extension() {
        let p = std::path::Path::new("/a/b/Foo.RS");
        assert_eq!(extension_of(p).as_deref(), Some("rs"));
        let p2 = std::path::Path::new("/a/b/.gitignore");
        assert_eq!(extension_of(p2), None);
    }
}
