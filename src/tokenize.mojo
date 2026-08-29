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
# Token counting: model -> tokenizer engine adapter layer.
#
# Use the exact engine when a local vocab is available; otherwise fall
# back to the approximate engine (-v prints a hint).

from std.collections import List, Optional
from std.os.env import getenv
from std.os.path import isfile, join
from std.pathlib import Path

from approx import ApproxParams, count_approx
from bpe import BpeTokenizer
from sp import SpTokenizer
from util import extension_of

comptime ENGINE_BPE = 0
comptime ENGINE_SP = 1
comptime ENGINE_APPROX = 2


def sls(var *items: String) -> List[String]:
    var l = List[String]()
    for s in items:
        l.append(s)
    return l^


# Model information.
struct ModelInfo(Movable):
    var name: String
    var aliases: List[String]
    var engine: Int
    var vocab_files: List[String]

    def __init__(
        out self,
        name: String,
        var aliases: List[String],
        engine: Int,
        var vocab_files: List[String],
    ):
        self.name = name
        self.aliases = aliases^
        self.engine = engine
        self.vocab_files = vocab_files^


# The supported models.
def models() -> List[ModelInfo]:
    var L = List[ModelInfo]()
    L.append(
        ModelInfo(
            "chatgpt",
            sls(
                "openai",
                "gpt",
                "gpt-4",
                "gpt-4o",
                "gpt-4.1",
                "gpt-5",
                "gpt-5.2",
                "gpt-5.4",
                "gpt-5.5",
                "gpt-5.6",
                "gpt-3.5",
                "o1",
                "o3",
                "gpt-oss",
                "gpt-oss-120b",
                "sol",
                "terra",
                "luna",
            ),
            ENGINE_BPE,
            sls(
                "o200k_base.tiktoken",
                "cl100k_base.tiktoken",
                "chatgpt.tokenizer.json",
            ),
        )
    )
    L.append(
        ModelInfo(
            "claude",
            sls(
                "anthropic",
                "claude-3",
                "claude-3.5",
                "claude-3.7",
                "claude-4",
                "claude-4.8",
                "claude-5",
                "claude-sonnet",
                "claude-sonnet-5",
                "claude-opus",
                "claude-opus-5",
                "claude-haiku",
                "claude-fable-5",
                "claude-mythos-5",
                "fable",
                "mythos",
            ),
            ENGINE_BPE,
            sls("claude.tokenizer.json"),
        )
    )
    L.append(
        ModelInfo(
            "gemini",
            sls(
                "google",
                "gemma",
                "gemini-1.5",
                "gemini-2.0",
                "gemini-2.5",
                "gemini-3",
                "gemini-3.5",
            ),
            ENGINE_SP,
            sls(
                "gemma_tokenizer.model",
                "gemini.tokenizer.model",
                "tokenizer.model",
            ),
        )
    )
    L.append(
        ModelInfo(
            "grok",
            sls(
                "xai",
                "grok-1",
                "grok-2",
                "grok-3",
                "grok-4",
                "grok-4.1",
                "grok-4.3",
                "grok-4.6",
            ),
            ENGINE_SP,
            sls("grok.tokenizer.model", "tokenizer.model"),
        )
    )
    L.append(
        ModelInfo(
            "deepseek",
            sls(
                "deepseek-v3",
                "deepseek-v3.1",
                "deepseek-v3.2",
                "deepseek-v4",
                "deepseek-v4-pro",
                "deepseek-v4-flash",
                "deepseek-v2",
                "deepseek-coder",
                "deepseek-r1",
                "ds",
            ),
            ENGINE_BPE,
            sls(
                "deepseek_v4.tokenizer.json",
                "deepseek_v3.tokenizer.json",
                "deepseek.tokenizer.json",
                "deepseek_v3.tiktoken",
            ),
        )
    )
    L.append(
        ModelInfo(
            "glm",
            sls(
                "glm-4",
                "glm-4.5",
                "glm-4.6",
                "glm-4.7",
                "glm-5",
                "glm-5.1",
                "glm-5.2",
                "glm4",
                "zhipu",
                "chatglm",
            ),
            ENGINE_BPE,
            sls(
                "glm-5.tokenizer.json",
                "glm-4.tokenizer.json",
                "glm.tokenizer.json",
            ),
        )
    )
    L.append(
        ModelInfo(
            "kimi",
            sls(
                "moonshot",
                "moonshotai",
                "kimi-k2",
                "kimi-k1.5",
                "k2",
                "kimi-k3",
                "k3",
            ),
            ENGINE_SP,
            sls(
                "kimi-k3.tokenizer.model",
                "kimi-k2.tokenizer.model",
                "kimi.tokenizer.model",
                "tokenizer.model",
            ),
        )
    )
    L.append(
        ModelInfo(
            "qwen",
            sls(
                "tongyi",
                "tongyi-qianwen",
                "qwen2",
                "qwen2.5",
                "qwen3",
                "qwen3.5",
                "qwen3.5-omni",
                "qwq",
            ),
            ENGINE_BPE,
            sls(
                "qwen.tiktoken",
                "qwen3.tiktoken",
                "qwen.tokenizer.json",
            ),
        )
    )
    L.append(
        ModelInfo(
            "seed",
            sls(
                "doubao",
                "seed-1.6",
                "seed-2.0",
                "seed-2.0-code",
                "doubao-seed",
                "doubao-seed-2.0",
                "seed-coder",
                "bytedance",
            ),
            ENGINE_BPE,
            sls("seed.tokenizer.json", "doubao-seed.tokenizer.model"),
        )
    )
    L.append(
        ModelInfo(
            "yuanbao",
            sls(
                "hunyuan",
                "yuanbao",
                "hunyuan-turbos",
                "hunyuan-t1",
                "hy3",
                "tencent",
            ),
            ENGINE_SP,
            sls("hunyuan.tokenizer.model", "yuanbao.tokenizer.model"),
        )
    )
    L.append(
        ModelInfo(
            "llama",
            sls(
                "llama3",
                "llama-3",
                "llama-3.1",
                "llama-3.2",
                "llama-3.3",
                "llama-4",
                "llama-4.1",
                "scout",
                "maverick",
                "meta",
                "llama3.1",
            ),
            ENGINE_BPE,
            sls(
                "llama3.tiktoken",
                "llama.tokenizer.json",
                "tokenizer.model",
            ),
        )
    )
    L.append(
        ModelInfo(
            "llama2",
            sls("llama-2", "llama2.0"),
            ENGINE_SP,
            sls(
                "llama2.tokenizer.model",
                "tokenizer.model",
            ),
        )
    )
    L.append(
        ModelInfo(
            "mistral",
            sls(
                "mistral-7b",
                "mistral-8x7b",
                "mixtral",
                "mistral-3",
                "mistral-large",
                "mistral-large-3",
                "mistral-small",
                "mistral-small-3",
                "mistral-small-4",
                "mistral-medium",
                "mistral-medium-3.5",
                "codestral",
            ),
            ENGINE_SP,
            sls("mistral.tokenizer.model", "tokenizer.model"),
        )
    )
    return L^


# Resolve a model by name or alias. Returns the index into `models`.
def resolve_model(ref mod: List[ModelInfo], name: String) -> Optional[Int]:
    var lower = name.lower()
    var i = 0
    while i < len(mod):
        if mod[i].name == lower:
            return Optional[Int](i)
        var a = 0
        while a < len(mod[i].aliases):
            if mod[i].aliases[a] == lower:
                return Optional[Int](i)
            a += 1
        i += 1
    return Optional[Int]()


# Tokenizer (engine tag + the three engines; only one is active).
struct Tokenizer(Movable):
    var kind: Int
    var bpe: BpeTokenizer
    var sp: SpTokenizer
    var approx: ApproxParams

    def __init__(
        out self,
        kind: Int,
        var bpe: BpeTokenizer,
        var sp: SpTokenizer,
        var approx: ApproxParams,
    ):
        self.kind = kind
        self.bpe = bpe^
        self.sp = sp^
        self.approx = approx

    def count(self, data: List[Byte]) -> UInt64:
        if self.kind == ENGINE_BPE:
            return self.bpe.count(data)
        if self.kind == ENGINE_SP:
            return self.sp.count(data)
        return count_approx(data, self.approx)


def make_bpe_tokenizer(var bt: BpeTokenizer) -> Tokenizer:
    return Tokenizer(ENGINE_BPE, bt^, SpTokenizer(), ApproxParams())


def make_sp_tokenizer(var sp: SpTokenizer) -> Tokenizer:
    return Tokenizer(ENGINE_SP, BpeTokenizer(), sp^, ApproxParams())


def make_approx_tokenizer() -> Tokenizer:
    return Tokenizer(
        ENGINE_APPROX, BpeTokenizer(), SpTokenizer(), ApproxParams()
    )


def has_vocab_ext(name: String) -> Bool:
    var ext = extension_of(name)
    if ext is None:
        return False
    var e = ext.value()
    return e == "tiktoken" or e == "model" or e == "json"


# Load a vocab file by extension.
def load_file(path: String, engine: Int) -> Optional[Tokenizer]:
    var ext = extension_of(path)
    if ext is None:
        return Optional[Tokenizer]()
    var e = ext.value()
    if e == "tiktoken":
        var bt = BpeTokenizer.from_tiktoken_file(path)
        if bt is None:
            return Optional[Tokenizer]()
        return Optional[Tokenizer](make_bpe_tokenizer(bt.take()))
    if e == "model":
        if engine == ENGINE_SP:
            var data: List[Byte]
            try:
                data = Path(path).read_bytes()
            except e2:
                return Optional[Tokenizer]()
            var sp = SpTokenizer.from_model_bytes(data)
            if sp is None:
                return Optional[Tokenizer]()
            return Optional[Tokenizer](make_sp_tokenizer(sp.take()))
        return Optional[Tokenizer]()
    if e == "json":
        var bt2 = BpeTokenizer.from_tokenizer_json(path)
        if bt2 is None:
            return Optional[Tokenizer]()
        return Optional[Tokenizer](make_bpe_tokenizer(bt2.take()))
    return Optional[Tokenizer]()


# File path inside the tiktoken cache directory (first that exists).
def tiktoken_cache_path(name: String) -> Optional[String]:
    var dirs = List[String]()
    var t = getenv("TMPDIR", "")
    if t != "":
        dirs.append(t)
    t = getenv("TEMP", "")
    if t != "":
        dirs.append(t)
    t = getenv("TMP", "")
    if t != "":
        dirs.append(t)
    var i = 0
    while i < len(dirs):
        var p = join(join(dirs[i], "data-gym-cache"), name)
        if isfile(p):
            return Optional[String](p)
        i += 1
    var p2 = join("/tmp/data-gym-cache", name)
    if isfile(p2):
        return Optional[String](p2)
    return Optional[String]()


def sort_strings(mut lst: List[String]):
    var n = len(lst)
    var i = 1
    while i < n:
        var key = lst[i]
        var j = i - 1
        while j >= 0 and lst[j] > key:
            lst[j + 1] = lst[j]
            j -= 1
        lst[j + 1] = key
        i += 1


# Build a tokenizer. Sets `loaded_from` to the source description (or None
# when the approximate engine is used) and returns the tokenizer.
def build(
    ref model: ModelInfo,
    tokenizer_dir: Optional[String],
    mut loaded_from: Optional[String],
) -> Tokenizer:
    # 1) Prefer the configured vocab directory
    if tokenizer_dir is not None:
        var dir = tokenizer_dir.value()
        var f = 0
        while f < len(model.vocab_files):
            var p = join(dir, model.vocab_files[f])
            if isfile(p):
                var loaded = load_file(p, model.engine)
                if loaded is not None:
                    loaded_from = Optional[String](
                        "{} ({})".format(p, model.vocab_files[f])
                    )
                    return loaded.take()
            f += 1
        # Other vocab files in the dir matching the extensions
        var entries: List[Path]
        try:
            entries = Path(dir).listdir()
        except e:
            entries = List[Path]()
        var cands = List[String]()
        var k = 0
        while k < len(entries):
            var nm = entries[k].name()
            if has_vocab_ext(nm):
                cands.append(join(dir, nm))
            k += 1
        sort_strings(cands)
        var c = 0
        while c < len(cands):
            var loaded2 = load_file(cands[c], model.engine)
            if loaded2 is not None:
                loaded_from = Optional[String](cands[c])
                return loaded2.take()
            c += 1

    # 2) chatgpt: auto-discover the tiktoken cache
    if model.name == "chatgpt":
        var cache_names = sls("o200k_base.tiktoken", "cl100k_base.tiktoken")
        var cn = 0
        while cn < len(cache_names):
            var cp = tiktoken_cache_path(cache_names[cn])
            if cp is not None and isfile(cp.value()):
                var bt = BpeTokenizer.from_tiktoken_file(cp.value())
                if bt is not None:
                    loaded_from = Optional[String](
                        "{} (tiktoken cache)".format(cp.value())
                    )
                    return make_bpe_tokenizer(bt.take())
            cn += 1

    # 3) Approximate
    loaded_from = Optional[String]()
    return make_approx_tokenizer()
