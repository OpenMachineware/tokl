# tokl -- Token and Line Counter

[![Chinese Docs](https://img.shields.io/badge/Chinese_Docs-Click_here-blue?style=for-the-badge)](./README_zh.md)

A command-line tool that counts code lines and tokens.

- Line counting: classify lines into **Code / Comments / Blanks** using language
  syntax (comment / string markers), in a style similar to
  [scc](https://github.com/boyter/scc)
- Token counting: tokenize for 13 mainstream LLMs (ChatGPT / Claude / Gemini /
  Grok / DeepSeek / GLM / Kimi / Qwen / Seed / Yuanbao / Llama / Mistral)
- Pure Rust standard library, no third-party dependencies, single-binary
  distribution (macOS / Linux / Windows)
- Parallel counting across all CPU cores by default, tunable with `-j`
- Modular design: `cli` (argument parsing), `config` (config loading),
  `scanner` (file scanning), `language` (language definitions),
  `count` (line counting), `tokenize` (tokenizer adapter), `format`
  (output formatting)

## Build

```bash
cargo build --release
# Binary is at target/release/tokl
```

## Usage

```
tokl [OPTIONS] <PATH...>
```

| Flag | Description |
| --- | --- |
| `-h, --help` | Print help |
| `--version` | Version and copyright info |
| `-v, --verbose` | Verbose output (tokenizer source, skipped files, etc.) |
| `-m, --model <MODEL>` | Set the model (takes precedence over config) |
| `-f, --format <json\|table\|markdown>` | Output format (takes precedence over config) |
| `-i, --ignore <PATTERN>` | Ignore dirs/languages/extensions, repeatable; merged with `default_ignore_dirs` and `default_ignore_langs` |
| `-e, --ext <EXT>` | Count only the given extensions, repeatable; merged with `default_exts` |
| `-j, --jobs <N>` | Number of counting threads (default: number of CPU cores) |
| `--init` | Generate a default config file |
| `<PATH>` | Paths to count, multiple allowed, recursive |

Examples:

```bash
tokl .
tokl -m deepseek-v3 -f markdown src tests
tokl -i node_modules -i target -e rs -e py .
tokl -m qwen --verbose ~/projects/myapp
tokl -e ui .          # count Qt .ui files (extensions of unregistered languages)
tokl -j 8 .           # count with 8 parallel threads
```

## Config file

Default location `~/.config/tokl/user_config.toml`
(`%APPDATA%\tokl\user_config.toml` on Windows); generate it with `--init`,
or point to another path via the `TOKL_CONFIG` environment variable:

```toml
# Default LLM used (the -m flag takes precedence)
default_model = "deepseek-v3"

# Default output format (maps to -f; supports table, json, markdown)
default_format = "table"

# Default directories to ignore (maps to -i, ignores directories)
default_ignore_dirs = ["node_modules", "target", ".git", "dist", "__pycache__"]

# Default languages to ignore (maps to -i; filtered by extension or language name)
default_ignore_langs = ["svg", "lock"]

# Default extensions to count only (maps to -e; empty or unset counts all)
default_exts = ["rs", "py", "cpp"]

# Optional: tokenizer vocab directory; exact token counting is enabled
# once each model's vocab files are placed here
# tokenizer_dir = "/path/to/vocabs"
```

## Models and tokenizers

Each model's tokenization algorithm falls into one of two families:
**Byte-level BPE** (tiktoken style) and **SentencePiece** (BPE with byte fallback).

| Model | Aliases | Tokenizer type | Vocab source |
| --- | --- | --- | --- |
| `chatgpt` | `gpt-4o` `gpt-5` `o1` `o3`, etc. | Byte-level BPE | tiktoken `o200k_base` / `cl100k_base` |
| `claude` | `claude-3` `claude-sonnet`, etc. | BPE (not open source) | no public vocab, approximate by default |
| `gemini` | `gemma`, etc. | SentencePiece | based on Gemma vocab (`gemma_tokenizer.model`) |
| `grok` | `grok-1` `xai`, etc. | SentencePiece | open `tokenizer.model` from Grok-1 |
| `deepseek` | `deepseek-v3` `deepseek-coder`, etc. | Byte-level BPE | 128K vocab (`deepseek_v3.tokenizer.json`) |
| `glm` | `glm-4` `zhipu`, etc. | BPE | GLM-4 `tokenizer.json` |
| `kimi` | `kimi-k2` `moonshot`, etc. | SentencePiece | open `tokenizer.model` from Kimi K2 |
| `qwen` | `qwen2.5` `qwen3`, etc. | Byte-level BPE | `qwen.tiktoken` |
| `seed` | `doubao`, etc. | BPE (proprietary) | no public vocab, approximate by default |
| `yuanbao` | `hunyuan`, etc. | SentencePiece | Hunyuan `tokenizer.model` |
| `llama` | `llama3` `meta`, etc. | Byte-level BPE | Llama 3 `llama3.tiktoken` |
| `llama2` | `llama-2`, etc. | SentencePiece | Llama 2 `tokenizer.model` |
| `mistral` | `mixtral`, etc. | SentencePiece | Mistral `tokenizer.model` |

### Exact vs approximate

- **Approximate mode (default)**: needs no vocab. English/code is estimated at
  roughly 1 token per 4 bytes, CJK at roughly 1 token per character; the error
  is usually within ±20%.
- **Exact mode**: drop the vocab files for the corresponding model into
  `tokenizer_dir` to enable it automatically. Supported formats:
  - `.tiktoken` (tiktoken / GPT family, Qwen, DeepSeek, etc.)
  - `tokenizer.json` (HuggingFace BPE format, GLM, DeepSeek, etc.)
  - `tokenizer.model` (SentencePiece, Gemini / Grok / Kimi / Llama 2 / Mistral, etc.)
- For `chatgpt`, the local tiktoken cache is also detected automatically
  (e.g. `/tmp/data-gym-cache/o200k_base.tiktoken`).

Vocab files can be downloaded from the corresponding HuggingFace model repos
(e.g. `deepseek-ai/DeepSeek-V3`, `zai-org/glm-4-9b`, `Qwen/Qwen2.5`,
`mistralai/Mistral-7B-v0.1`, `xai-org/grok-1`, `moonshotai/Kimi-K2`); use `-v`
to see which tokenizer source is actually in use.

## Language support

C, C++, Assembly (asm/s/S), Java, Kotlin, Scala, D, Vim script, Bash, Zsh, Fish,
Perl, Python, Tcl, Lua, PHP, Ruby, SQL, JSON, XML, XHTML, HTML, CSS,
JavaScript, JSX, TypeScript, TSX, TOML, YAML, Rust, Go, Swift, Verilog,
SystemVerilog, VHDL, Makefile, Ninja, CMake, Dockerfile, INI, Markdown,
LaTeX, Texinfo, GCC MD (`.md`, lower priority than Markdown), LLVM TableGen (`.td`).

## Sample output

```
Language            Files       Lines    Blanks  Comments       Code    Tokens
──────────────────────────────────────────────────────────────────────────────
Rust                  183      51,131     4,789     6,636     39,706  165,642
Markdown               35       6,238     1,545         0      4,693    9,124
SystemVerilog           6          92         8        42         42      701
TOML                    2          42         8         0         34       91
──────────────────────────────────────────────────────────────────────────────
Total                 226      57,503     6,350     6,678     44,475  175,558
──────────────────────────────────────────────────────────────────────────────
```

Column order is `Language Files Tokens Lines Blanks Comments Code` (the
Complexity column from scc is dropped, and Tokens sits between Files and Lines).

## License

GPL-3.0
