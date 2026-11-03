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
//! Minimal JSON parser (used to read HuggingFace tokenizer.json / vocab.json).
//! Not a full standard implementation; valid input only.

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Value>),
    Obj(Vec<(String, Value)>),
}

impl Value {
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Obj(fields) => {
                fields.iter().find(|(k, _)| k == key).map(|(_, v)| v)
            }
            _ => None,
        }
    }

    pub fn as_num(&self) -> Option<f64> {
        match self {
            Value::Num(n) => Some(*n),
            _ => None,
        }
    }
}

pub fn parse(input: &str) -> Result<Value, String> {
    let mut p = Parser { bytes: input.as_bytes(), pos: 0 };
    p.skip_ws();
    let v = p.parse_value()?;
    p.skip_ws();
    if p.pos != p.bytes.len() {
        return Err(format!(
            "trailing content after JSON (position {})",
            p.pos
        ));
    }
    Ok(v)
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn skip_ws(&mut self) {
        while self.pos < self.bytes.len() {
            match self.bytes[self.pos] {
                b' ' | b'\t' | b'\n' | b'\r' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn parse_value(&mut self) -> Result<Value, String> {
        self.skip_ws();
        match self.peek() {
            Some(b'{') => self.parse_obj(),
            Some(b'[') => self.parse_arr(),
            Some(b'"') => Ok(Value::Str(self.parse_string()?)),
            Some(b't') => self.parse_lit("true", Value::Bool(true)),
            Some(b'f') => self.parse_lit("false", Value::Bool(false)),
            Some(b'n') => self.parse_lit("null", Value::Null),
            Some(c) if c == b'-' || c.is_ascii_digit() => self.parse_num(),
            other => Err(format!(
                "unexpected JSON character: {:?} (position {})",
                other, self.pos
            )),
        }
    }

    fn parse_lit(&mut self, lit: &str, val: Value) -> Result<Value, String> {
        if self.bytes.len() < self.pos + lit.len()
            || &self.bytes[self.pos..self.pos + lit.len()] != lit.as_bytes()
        {
            return Err(format!(
                "unexpected JSON content (position {})",
                self.pos
            ));
        }
        self.pos += lit.len();
        Ok(val)
    }

    fn parse_num(&mut self) -> Result<Value, String> {
        let start = self.pos;
        while self.pos < self.bytes.len() {
            match self.bytes[self.pos] {
                b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E' => self.pos += 1,
                _ => break,
            }
        }
        let s = std::str::from_utf8(&self.bytes[start..self.pos])
            .map_err(|_| "invalid number")?;
        s.parse::<f64>()
            .map(Value::Num)
            .map_err(|_| format!("invalid number: {}", s))
    }

    fn parse_string(&mut self) -> Result<String, String> {
        if self.peek() != Some(b'"') {
            return Err("expected string".into());
        }
        self.pos += 1;
        let mut out = String::new();
        loop {
            match self.peek() {
                None => return Err("unterminated string".into()),
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    let esc = self.peek().ok_or("incomplete escape")?;
                    self.pos += 1;
                    match esc {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{0008}'),
                        b'f' => out.push('\u{000C}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            if self.pos + 4 > self.bytes.len() {
                                return Err("incomplete \\u escape".into());
                            }
                            let hex = std::str::from_utf8(
                                &self.bytes[self.pos..self.pos + 4],
                            )
                            .map_err(|_| "invalid \\u")?;
                            let code = u32::from_str_radix(hex, 16)
                                .map_err(|_| "invalid \\u code point")?;
                            self.pos += 4;
                            if let Some(c) = char::from_u32(code) {
                                out.push(c);
                            } else {
                                out.push('\u{FFFD}');
                            }
                        }
                        other => {
                            return Err(format!(
                                "invalid escape: \\{}",
                                other as char
                            ))
                        }
                    }
                }
                Some(b) => {
                    // Advance by UTF-8 boundary
                    let len = utf8_len(b);
                    let end = (self.pos + len).min(self.bytes.len());
                    let s = std::str::from_utf8(&self.bytes[self.pos..end])
                        .map_err(|_| "invalid UTF-8")?;
                    out.push_str(s);
                    self.pos = end;
                }
            }
        }
    }

    fn parse_arr(&mut self) -> Result<Value, String> {
        self.pos += 1; // [
        let mut arr = Vec::new();
        loop {
            self.skip_ws();
            match self.peek() {
                None => return Err("unterminated array".into()),
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Value::Arr(arr));
                }
                Some(b',') => {
                    self.pos += 1;
                }
                _ => arr.push(self.parse_value()?),
            }
        }
    }

    fn parse_obj(&mut self) -> Result<Value, String> {
        self.pos += 1; // {
        let mut fields = Vec::new();
        loop {
            self.skip_ws();
            match self.peek() {
                None => return Err("unterminated object".into()),
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Value::Obj(fields));
                }
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b'"') => {
                    let key = self.parse_string()?;
                    self.skip_ws();
                    if self.peek() != Some(b':') {
                        return Err("object missing ':'".into());
                    }
                    self.pos += 1;
                    let val = self.parse_value()?;
                    fields.push((key, val));
                }
                other => {
                    return Err(format!(
                        "unexpected object character: {:?} (position {})",
                        other, self.pos
                    ))
                }
            }
        }
    }
}

fn utf8_len(b: u8) -> usize {
    if b < 0x80 {
        1
    } else if b >> 5 == 0b110 {
        2
    } else if b >> 4 == 0b1110 {
        3
    } else if b >> 3 == 0b11110 {
        4
    } else {
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_basic() {
        let v = parse(r#"{"a": [1, 2.5, "x", true, null], "b": {"c": "d"}}"#)
            .unwrap();
        let arr = v.get("a").unwrap();
        match arr {
            Value::Arr(items) => {
                assert_eq!(items.len(), 5);
                assert_eq!(items[2], Value::Str("x".to_string()));
                assert_eq!(items[3], Value::Bool(true));
                assert_eq!(items[4], Value::Null);
            }
            _ => panic!("expected an array"),
        }
        assert_eq!(
            v.get("b").unwrap().get("c").unwrap(),
            &Value::Str("d".to_string())
        );
    }

    #[test]
    fn test_unicode_escape() {
        let v = parse(r#""\u0068\u0065\u006c\u006c\u006f""#).unwrap();
        assert_eq!(v, Value::Str("hello".to_string()));
    }
}
