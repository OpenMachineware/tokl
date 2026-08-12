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
//! Token counting: model -> tokenizer engine adapter layer.
//!
//! Supported models and their tokenizer types (research findings, 2026-08):
//! - chatgpt  : Byte-level BPE (tiktoken, o200k/cl100k), vocab from
//!              tiktoken cache or local files; GPT-5.2/5.4/5.5/5.6 (2026)
//! - claude   : proprietary BPE (not open source), approximate by default;
//!              Claude 4.8 and Claude 5 (Fable/Mythos/Opus 5, 2026)
//! - gemini   : SentencePiece (based on Gemma vocab); Gemini 3 / 3.5 (2026)
//! - grok     : SentencePiece (Grok-1 ships open tokenizer.model);
//!              Grok 4 / 4.1 / 4.3 / 4.6 (2026)
//! - deepseek : Byte-level BPE (128K vocab, tokenizer.json is public);
//!              DeepSeek V4 (2026-04, Pro/Flash), the default model
//! - glm      : BPE (GLM tokenizer.json is public); GLM-5 / 5.1 / 5.2 (2026)
//! - kimi     : SentencePiece (Kimi K2 ships open kimi-spm); Kimi K3 (2026-07)
//! - qwen     : Byte-level BPE (qwen.tiktoken); Qwen3.5 (2026)
//! - seed     : ByteDance proprietary (approximate); Doubao Seed 2.0 (2026-02)
//! - yuanbao  : SentencePiece (Hunyuan); Hunyuan TurboS/T1, Hy3 (2026-07)
//! - llama    : BPE (Llama 3/4 uses tiktoken style); `llama2` is SentencePiece
//! - mistral  : SentencePiece (byte fallback); Mistral 3 series (2026)
//!
//! Use the exact engine when a local vocab is available; otherwise fall
//! back to the approximate engine (-v prints a hint).

use std::path::{Path, PathBuf};

use crate::approx::{count_approx, ApproxParams};
use crate::bpe::BpeTokenizer;
use crate::sp::SpTokenizer;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineKind {
    Bpe,
    SentencePiece,
}

/// Model information.
pub struct ModelInfo {
    pub name: &'static str,
    pub aliases: &'static [&'static str],
    pub engine: EngineKind,
    /// Candidate vocab file names searched in tokenizer_dir, in order
    pub vocab_files: &'static [&'static str],
}

pub const MODELS: &[ModelInfo] = &[
    ModelInfo {
        name: "chatgpt",
        aliases: &[
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
        ],
        engine: EngineKind::Bpe,
        vocab_files: &[
            "o200k_base.tiktoken",
            "cl100k_base.tiktoken",
            "chatgpt.tokenizer.json",
        ],
    },
    ModelInfo {
        name: "claude",
        aliases: &[
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
        ],
        engine: EngineKind::Bpe,
        vocab_files: &["claude.tokenizer.json"],
    },
    ModelInfo {
        name: "gemini",
        aliases: &[
            "google",
            "gemma",
            "gemini-1.5",
            "gemini-2.0",
            "gemini-2.5",
            "gemini-3",
            "gemini-3.5",
        ],
        engine: EngineKind::SentencePiece,
        vocab_files: &[
            "gemma_tokenizer.model",
            "gemini.tokenizer.model",
            "tokenizer.model",
        ],
    },
    ModelInfo {
        name: "grok",
        aliases: &[
            "xai", "grok-1", "grok-2", "grok-3", "grok-4", "grok-4.1",
            "grok-4.3", "grok-4.6",
        ],
        engine: EngineKind::SentencePiece,
        vocab_files: &["grok.tokenizer.model", "tokenizer.model"],
    },
    ModelInfo {
        name: "deepseek",
        aliases: &[
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
        ],
        engine: EngineKind::Bpe,
        vocab_files: &[
            "deepseek_v4.tokenizer.json",
            "deepseek_v3.tokenizer.json",
            "deepseek.tokenizer.json",
            "deepseek_v3.tiktoken",
        ],
    },
    ModelInfo {
        name: "glm",
        aliases: &[
            "glm-4", "glm-4.5", "glm-4.6", "glm-4.7", "glm-5", "glm-5.1",
            "glm-5.2", "glm4", "zhipu", "chatglm",
        ],
        engine: EngineKind::Bpe,
        vocab_files: &[
            "glm-5.tokenizer.json",
            "glm-4.tokenizer.json",
            "glm.tokenizer.json",
        ],
    },
    ModelInfo {
        name: "kimi",
        aliases: &[
            "moonshot",
            "moonshotai",
            "kimi-k2",
            "kimi-k1.5",
            "k2",
            "kimi-k3",
            "k3",
        ],
        engine: EngineKind::SentencePiece,
        vocab_files: &[
            "kimi-k3.tokenizer.model",
            "kimi-k2.tokenizer.model",
            "kimi.tokenizer.model",
            "tokenizer.model",
        ],
    },
    ModelInfo {
        name: "qwen",
        aliases: &[
            "tongyi",
            "tongyi-qianwen",
            "qwen2",
            "qwen2.5",
            "qwen3",
            "qwen3.5",
            "qwen3.5-omni",
            "qwq",
        ],
        engine: EngineKind::Bpe,
        vocab_files: &[
            "qwen.tiktoken",
            "qwen3.tiktoken",
            "qwen.tokenizer.json",
        ],
    },
    ModelInfo {
        name: "seed",
        aliases: &[
            "doubao",
            "seed-1.6",
            "seed-2.0",
            "seed-2.0-code",
            "doubao-seed",
            "doubao-seed-2.0",
            "seed-coder",
            "bytedance",
        ],
        engine: EngineKind::Bpe,
        vocab_files: &["seed.tokenizer.json", "doubao-seed.tokenizer.model"],
    },
    ModelInfo {
        name: "yuanbao",
        aliases: &[
            "hunyuan",
            "yuanbao",
            "hunyuan-turbos",
            "hunyuan-t1",
            "hy3",
            "tencent",
        ],
        engine: EngineKind::SentencePiece,
        vocab_files: &["hunyuan.tokenizer.model", "yuanbao.tokenizer.model"],
    },
    ModelInfo {
        name: "llama",
        aliases: &[
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
        ],
        engine: EngineKind::Bpe,
        vocab_files: &[
            "llama3.tiktoken",
            "llama.tokenizer.json",
            "tokenizer.model",
        ],
    },
    ModelInfo {
        name: "llama2",
        aliases: &["llama-2", "llama2.0"],
        engine: EngineKind::SentencePiece,
        vocab_files: &["llama2.tokenizer.model", "tokenizer.model"],
    },
    ModelInfo {
        name: "mistral",
        aliases: &[
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
        ],
        engine: EngineKind::SentencePiece,
        vocab_files: &["mistral.tokenizer.model", "tokenizer.model"],
    },
];

/// Resolve a model by name or alias.
pub fn resolve_model(name: &str) -> Option<&'static ModelInfo> {
    let name = name.to_ascii_lowercase();
    MODELS.iter().find(|m| m.name == name || m.aliases.contains(&name.as_str()))
}

/// Tokenizer (engine enum).
pub enum Tokenizer {
    Bpe(BpeTokenizer),
    Sp(SpTokenizer),
    Approx(ApproxParams),
}

impl Tokenizer {
    pub fn count(&self, text: &[u8]) -> u64 {
        match self {
            Tokenizer::Bpe(t) => t.count(text),
            Tokenizer::Sp(t) => t.count(text),
            Tokenizer::Approx(p) => count_approx(text, p),
        }
    }
}

/// Build a tokenizer. Returns (tokenizer, load source description).
pub fn build(
    model: &ModelInfo,
    tokenizer_dir: Option<&Path>,
) -> (Tokenizer, Option<String>) {
    // 1) Prefer the configured vocab directory
    if let Some(dir) = tokenizer_dir {
        for f in model.vocab_files {
            let p = dir.join(f);
            if p.is_file() {
                if let Some(t) = load_file(&p, model.engine) {
                    return (t, Some(format!("{} ({})", p.display(), f)));
                }
            }
        }
        // Other vocab files in the dir matching the extensions
        if let Some(entries) = std::fs::read_dir(dir).ok() {
            let mut cands: Vec<PathBuf> = entries
                .flatten()
                .map(|e| e.path())
                .filter(|p| {
                    p.extension()
                        .map(|e| {
                            matches!(
                                e.to_str(),
                                Some("tiktoken" | "model" | "json")
                            )
                        })
                        .unwrap_or(false)
                })
                .collect();
            cands.sort();
            for p in cands {
                if let Some(t) = load_file(&p, model.engine) {
                    return (t, Some(p.display().to_string()));
                }
            }
        }
    }

    // 2) chatgpt: auto-discover the tiktoken cache
    if model.name == "chatgpt" {
        for f in ["o200k_base.tiktoken", "cl100k_base.tiktoken"] {
            if let Some(p) = tiktoken_cache_path(f) {
                if p.is_file() {
                    if let Some(t) = BpeTokenizer::from_tiktoken_file(&p) {
                        return (
                            Tokenizer::Bpe(t),
                            Some(format!("{} (tiktoken cache)", p.display())),
                        );
                    }
                }
            }
        }
    }

    // 3) Approximate
    (Tokenizer::Approx(ApproxParams::default()), None)
}

/// Load a vocab file by extension.
fn load_file(path: &Path, engine: EngineKind) -> Option<Tokenizer> {
    match path.extension().and_then(|e| e.to_str()) {
        Some("tiktoken") => {
            BpeTokenizer::from_tiktoken_file(path).map(Tokenizer::Bpe)
        }
        Some("model") => {
            if engine == EngineKind::SentencePiece {
                let data = std::fs::read(path).ok()?;
                SpTokenizer::from_model_bytes(&data).map(Tokenizer::Sp)
            } else {
                None
            }
        }
        Some("json") => {
            BpeTokenizer::from_tokenizer_json(path).map(Tokenizer::Bpe)
        }
        _ => None,
    }
}

/// File path inside the tiktoken cache directory.
fn tiktoken_cache_path(name: &str) -> Option<PathBuf> {
    let dirs = std::env::vars()
        .filter(|(k, _)| matches!(k.as_str(), "TMPDIR" | "TEMP" | "TMP"))
        .map(|(_, v)| PathBuf::from(v));
    let mut paths: Vec<PathBuf> = Vec::new();
    paths.extend(dirs.map(|d| d.join("data-gym-cache").join(name)));
    #[cfg(not(windows))]
    paths.push(PathBuf::from("/tmp/data-gym-cache").join(name));
    paths.into_iter().find(|p| p.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resolve() {
        assert!(resolve_model("qwen").is_some());
        assert!(resolve_model("deepseek-v3").is_some());
        assert!(resolve_model("deepseek-v4").is_some());
        assert!(resolve_model("deepseek-v4-pro").is_some());
        assert!(resolve_model("gpt-4o").is_some());
        assert!(resolve_model("gpt-5.6").is_some());
        assert!(resolve_model("sol").is_some());
        assert!(resolve_model("claude-sonnet").is_some());
        assert!(resolve_model("claude-5").is_some());
        assert!(resolve_model("gemini-3.5").is_some());
        assert!(resolve_model("grok-4.6").is_some());
        assert!(resolve_model("glm-5.2").is_some());
        assert!(resolve_model("kimi-k3").is_some());
        assert!(resolve_model("qwen3.5").is_some());
        assert!(resolve_model("seed-2.0").is_some());
        assert!(resolve_model("hy3").is_some());
        assert!(resolve_model("llama-4.1").is_some());
        assert!(resolve_model("mistral-3").is_some());
        assert!(resolve_model("LLAMA3").is_some());
        assert!(resolve_model("nonexistent").is_none());
        // "llama2" must not resolve to "llama"
        let m = resolve_model("llama2").unwrap();
        assert_eq!(m.name, "llama2");
        let m2 = resolve_model("llama").unwrap();
        assert_eq!(m2.name, "llama");
    }
}
