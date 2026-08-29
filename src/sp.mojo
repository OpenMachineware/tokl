# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2025 Jia Liu <proljc@gmail.com>
# SPDX-FileCopyrightText: 2025 tokl contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# SentencePiece engine (Gemini/Gemma, Grok, Kimi, Mistral, Llama 2,
# Hunyuan, ...).
#
# Encoding flow (approximating sentencepiece's Encode):
# 1. Replace spaces (0x20) with ▁ (U+2581)
# 2. Split words on other whitespace
# 3. Viterbi max-score path per word (piece match + byte fallback)

from std.collections import Dict, List, Optional

from proto import SP_BYTE, SP_NORMAL, SP_UNKNOWN, SentencePiece, parse_model


comptime U2581_0 = 0xEF
comptime U2581_1 = 0x96
comptime U2581_2 = 0x81  # UTF-8 encoding of ▁
comptime SP_CHUNK = 2048


struct SpTokenizer(Movable):
    var lookup: Dict[String, Float32]  # piece bytes -> score
    var byte_lookup: Dict[UInt8, Float32]  # <0xXX> byte piece table
    var unk_score: Optional[Float32]
    var max_len: Int

    def __init__(out self):
        self.lookup = Dict[String, Float32]()
        self.byte_lookup = Dict[UInt8, Float32]()
        self.unk_score = Optional[Float32]()
        self.max_len = 1

    # Build from the raw bytes of a tokenizer.model.
    @staticmethod
    def from_model_bytes(data: Span[Byte, _]) -> Optional[SpTokenizer]:
        var parsed: Optional[List[SentencePiece]] = Optional[
            List[SentencePiece]
        ]()
        try:
            var p = parse_model(data)
            parsed = Optional[List[SentencePiece]](p^)
        except e:
            pass
        if parsed is None:
            return Optional[SpTokenizer]()
        var pieces = parsed.take()
        var lookup = Dict[String, Float32]()
        var byte_lookup = Dict[UInt8, Float32]()
        var unk_score = Optional[Float32]()
        var max_len: Int = 1
        var pi = 0
        while pi < len(pieces):
            if pieces[pi].typ == SP_NORMAL:
                if pieces[pi].piece.byte_length() > max_len:
                    max_len = pieces[pi].piece.byte_length()
                var key = String(unsafe_from_utf8=pieces[pi].piece)
                lookup[key] = pieces[pi].score
            elif pieces[pi].typ == SP_BYTE:
                var b = parse_byte_piece(pieces[pi].piece)
                if b is not None:
                    byte_lookup[b.value()] = pieces[pi].score
            elif pieces[pi].typ == SP_UNKNOWN:
                unk_score = Optional[Float32](pieces[pi].score)
            pi += 1
        if len(lookup) == 0:
            return Optional[SpTokenizer]()
        var t = SpTokenizer()
        t.lookup = lookup^
        t.byte_lookup = byte_lookup^
        t.unk_score = unk_score^
        t.max_len = max_len
        return Optional[SpTokenizer](t^)

    # Count tokens.
    def count(self, text: List[Byte]) -> UInt64:
        var total: UInt64 = 0
        var word = List[Byte]()
        var in_word = False
        for b in text:
            if b == 0x20:  # space
                word.append(U2581_0)
                word.append(U2581_1)
                word.append(U2581_2)
                in_word = True
            elif is_ws(b):
                if in_word:
                    total += self.encode_word(word)
                    word.clear()
                    in_word = False
            else:
                word.append(b)
                in_word = True
        if in_word:
            total += self.encode_word(word)
        return total

    # Viterbi max-score split of a single word.
    def encode_word(self, word: Span[Byte, _]) -> UInt64:
        var n = len(word)
        if n == 0:
            return 0
        # Chunk very long words to avoid a slow worst case
        if n > SP_CHUNK:
            var total: UInt64 = 0
            var start = 0
            while start < n:
                var end = start + SP_CHUNK
                if end > n:
                    end = n
                total += self.encode_word(word[start:end])
                start = end
            return total

        var neg_inf: Float32 = -1.0e30
        var dp = List[Float32](length=n + 1, fill=neg_inf)
        var cnt = List[UInt64](length=n + 1, fill=0)
        dp[0] = 0.0

        var i = 0
        while i < n:
            if dp[i] == neg_inf:
                i += 1
                continue
            var maxl = n - i
            if maxl > self.max_len:
                maxl = self.max_len
            # Normal pieces (longer first; keep the longer on ties)
            var l = maxl
            while l >= 1:
                var key = String(unsafe_from_utf8=word[i : i + l])
                var s = self.lookup.find(key)
                if s is not None:
                    var j = i + l
                    var cand = dp[i] + s.value()
                    if dp[j] == neg_inf or cand > dp[j]:
                        dp[j] = cand
                        cnt[j] = cnt[i] + 1
                l -= 1
            # Byte fallback: <0xXX>
            var bs = self.byte_lookup.find(word[i])
            if bs is not None:
                var j = i + 1
                var cand = dp[i] + bs.value()
                if dp[j] == neg_inf or cand > dp[j]:
                    dp[j] = cand
                    cnt[j] = cnt[i] + 1
            else:
                if self.unk_score is not None:
                    var j2 = i + 1
                    var cand2 = dp[i] + self.unk_score.value()
                    if dp[j2] == neg_inf or cand2 > dp[j2]:
                        dp[j2] = cand2
                        cnt[j2] = cnt[i] + 1
            i += 1

        if cnt[n] > 0:
            return cnt[n]
        else:
            # Fallback: approximate by bytes/4 when nothing matches
            return (UInt64(n) + 3) / 4


def is_ws(b: Byte) -> Bool:
    return b == 0x09 or b == 0x0A or b == 0x0D or b == 0x0B or b == 0x0C


# Parse a `<0xAB>`-style byte piece.
def parse_byte_piece(piece: Span[Byte, _]) -> Optional[UInt8]:
    var s = String(unsafe_from_utf8=piece)
    var t = String(s.strip())
    if t.find("<0x") != 0:
        return Optional[UInt8]()
    if t.rfind(">") != t.byte_length() - 1:
        return Optional[UInt8]()
    var hexs = String(t[byte = 3 : t.byte_length() - 1])
    if hexs.byte_length() != 2:
        return Optional[UInt8]()
    var hi = hex_digit(hexs.as_bytes()[0])
    var lo = hex_digit(hexs.as_bytes()[1])
    if hi < 0 or lo < 0:
        return Optional[UInt8]()
    return Optional[UInt8](Byte(hi * 16 + lo))


def hex_digit(b: Byte) -> Int:
    if b >= 0x30 and b <= 0x39:
        return Int(b - 0x30)
    if b >= 0x41 and b <= 0x46:
        return Int(b - 0x41 + 10)
    if b >= 0x61 and b <= 0x66:
        return Int(b - 0x61 + 10)
    return -1
