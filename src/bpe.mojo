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
# Byte-level BPE engine (tiktoken / GPT family, Qwen, DeepSeek, GLM, ...).
#
# After loading the vocab, run rank-based greedy BPE merging over the whole
# UTF-8 byte stream (matching tiktoken's byte_pair_merge, O(n log n) with a
# priority queue).
#
# Vocab keys are stored as String used as a raw byte buffer (Mojo has no
# distinct bytes type); equality/hash operate on the bytes.

from std.collections import Dict, List, Optional, BinaryHeap
from std.pathlib import Path

from json import JsonDoc, json_parse
from util import base64_decode


# Heap entry: (rank, left part index, version). Ordered as a MIN-heap by
# inverting __lt__ (BinaryHeap is a max-heap).
struct HeapItem(Comparable, Copyable):
    var rank: UInt32
    var idx: Int
    var ver: UInt32

    def __init__(out self, rank: UInt32, idx: Int, ver: UInt32):
        self.rank = rank
        self.idx = idx
        self.ver = ver

    # "smaller" (higher priority) = lower rank; ties by lower index.
    def __lt__(self, other: HeapItem) -> Bool:
        if self.rank != other.rank:
            return self.rank > other.rank
        if self.idx != other.idx:
            return self.idx > other.idx
        return self.ver > other.ver

    def __eq__(self, other: HeapItem) -> Bool:
        return (
            self.rank == other.rank
            and self.idx == other.idx
            and self.ver == other.ver
        )


struct BpeTokenizer(Movable):
    var ranks: Dict[String, UInt32]

    def __init__(out self):
        self.ranks = Dict[String, UInt32]()

    def __init__(out self, var ranks: Dict[String, UInt32]):
        self.ranks = ranks^

    # Load from a .tiktoken file (each line: base64 token + rank).
    @staticmethod
    def from_tiktoken_file(path: String) -> Optional[BpeTokenizer]:
        var text: String
        try:
            text = Path(path).read_text()
        except e:
            return Optional[BpeTokenizer]()
        var ranks = Dict[String, UInt32]()
        var lines = text.split("\n")
        for raw in lines:
            var line = String(raw.strip())
            if line == "":
                continue
            var parts = line.split()
            if len(parts) < 2:
                continue
            var b64 = String(parts[0])
            var rank_str = String(parts[1])
            var rank: UInt32
            try:
                rank = UInt32(Int(rank_str))
            except e:
                continue
            var bytes_opt = base64_decode(b64)
            if bytes_opt is None:
                continue
            var key = String(unsafe_from_utf8=bytes_opt.value())
            ranks[key] = rank
        if len(ranks) == 0:
            return Optional[BpeTokenizer]()
        return Optional[BpeTokenizer](BpeTokenizer(ranks^))

    # Load from a HuggingFace tokenizer.json (model.vocab object).
    @staticmethod
    def from_tokenizer_json(path: String) -> Optional[BpeTokenizer]:
        var text: String
        try:
            text = Path(path).read_text()
        except e:
            return Optional[BpeTokenizer]()
        var doc: JsonDoc
        try:
            doc = json_parse(text)
        except e:
            return Optional[BpeTokenizer]()
        var model_idx = doc.get_idx(0, "model")
        if model_idx is None:
            return Optional[BpeTokenizer]()
        var vocab_idx = doc.get_idx(model_idx.value(), "vocab")
        if vocab_idx is None:
            return Optional[BpeTokenizer]()
        return BpeTokenizer.from_vocab(doc, vocab_idx.value())

    # Build a tokenizer from the model.vocab object of a tokenizer.json.
    @staticmethod
    def from_vocab(ref doc: JsonDoc, vocab_idx: Int) -> Optional[BpeTokenizer]:
        var v = doc.values[vocab_idx]
        if v.kind != 5:  # JV_OBJ
            return Optional[BpeTokenizer]()
        var ranks = Dict[String, UInt32]()
        var i = 0
        while i < len(v.keys):
            var tok = v.keys[i]
            var child = v.children[i]
            var num = doc.values[child].num
            ranks[tok] = UInt32(num)
            i += 1
        if len(ranks) == 0:
            return Optional[BpeTokenizer]()
        return Optional[BpeTokenizer](BpeTokenizer(ranks^))

    # Count tokens (run BPE merging over the whole byte stream).
    def count(self, data: List[Byte]) -> UInt64:
        var n = len(data)
        if n == 0:
            return 0
        if n == 1:
            return 1

        # parts[i] = [start, end), byte range
        var start = List[Int](length=n, fill=0)
        var end = List[Int](length=n, fill=0)
        var i0 = 0
        while i0 < n:
            start[i0] = i0
            end[i0] = i0 + 1
            i0 += 1
        # Linked list (by original index)
        var next = List[Optional[Int]](length=n, fill=Optional[Int]())
        var prev = List[Optional[Int]](length=n, fill=Optional[Int]())
        var i1 = 0
        while i1 < n:
            if i1 + 1 < n:
                next[i1] = Optional[Int](i1 + 1)
            if i1 > 0:
                prev[i1] = Optional[Int](i1 - 1)
            i1 += 1
        var versions = List[UInt32](length=n, fill=0)

        var heap = BinaryHeap[HeapItem]()
        var i2 = 0
        while i2 < n - 1:
            var key = String(unsafe_from_utf8=data[i2 : i2 + 2])
            var r = self.ranks.find(key)
            if r is not None:
                heap.push(HeapItem(r.value(), i2, 0))
            i2 += 1

        var merged: UInt64 = 0
        while len(heap) > 0:
            var item = heap.pop()
            var rank = item.rank
            var i = item.idx
            var ver = item.ver
            if ver != versions[i]:
                continue
            var nj = next[i]
            if nj is None:
                continue
            var j = nj.value()
            var a = start[i]
            var c = end[j]
            # Check content still matches rank (skip stale entries)
            var key2 = String(unsafe_from_utf8=data[a:c])
            var r2 = self.ranks.find(key2)
            if r2 is None or r2.value() != rank:
                continue
            # Merge i and j
            versions[i] += 1
            end[i] = c
            next[i] = next[j]
            var nnj = next[j]
            if nnj is not None:
                prev[nnj.value()] = Optional[Int](i)
            merged += 1

            # Left neighbor (prev[i], i)
            var kp = prev[i]
            if kp is not None:
                var k = kp.value()
                var b = start[k]
                var e = end[i]
                var key3 = String(unsafe_from_utf8=data[b:e])
                var r3 = self.ranks.find(key3)
                if r3 is not None:
                    heap.push(HeapItem(r3.value(), k, versions[k]))
            # Right neighbor (i, next[i])
            var ni = next[i]
            if ni is not None:
                var b2 = start[i]
                var e2 = end[ni.value()]
                var key4 = String(unsafe_from_utf8=data[b2:e2])
                var r4 = self.ranks.find(key4)
                if r4 is not None:
                    versions[i] += 1
                    heap.push(HeapItem(r4.value(), i, versions[i]))
        return UInt64(n) - merged
