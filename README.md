# tokl -- Token and Line Counter

[![Chinese Docs](https://img.shields.io/badge/Chinese_Docs-Click_here-blue?style=for-the-badge)](./README_zh.md)
[![Release](https://img.shields.io/github/v/release/OpenMachineware/tokl?sort=semver&style=for-the-badge)](https://github.com/OpenMachineware/tokl/releases)

A command-line tool that counts code lines and tokens.

- Line counting: classify lines into **Code / Comments / Blanks** using language
  syntax (comment / string markers)
- Token counting: tokenize for 13 mainstream LLMs (ChatGPT / Claude / Gemini /
  Grok / DeepSeek / GLM / Kimi / Qwen / Seed / Yuanbao / Llama / Mistral)
- A config file (`~/.config/tokl/user_config.toml`) is generated automatically
  on first run, with defaults for most developers (default model: DeepSeek V4)
- Pure Rust standard library, no third-party dependencies, single-binary
  distribution (macOS / Linux / Windows)
- Parallel counting across all CPU cores by default, tunable with `-j`
- Modular design: `cli` (argument parsing), `config` (config loading),
  `scanner` (file scanning), `language` (language definitions),
  `count` (line counting), `tokenize` (tokenizer adapter), `format`
  (output formatting)

## Install (pre-built binaries)

Pre-built binaries are attached to every
[GitHub Release](https://github.com/OpenMachineware/tokl/releases): GitHub
Actions builds and uploads them automatically whenever a `v*` tag is pushed.

| Platform | Asset name |
| --- | --- |
| Linux (x86_64) | `tokl-<tag>-x86_64-unknown-linux-gnu` |
| macOS (Apple Silicon) | `tokl-<tag>-aarch64-apple-darwin` |

Download the asset for your platform, then make it executable and rename it —
that's all, no install step and no dependencies:

```bash
# Linux / macOS (example for release v0.1.0):
curl -LO https://github.com/OpenMachineware/tokl/releases/download/v0.1.0/tokl-v0.1.0-x86_64-unknown-linux-gnu
chmod +x tokl-v0.1.0-x86_64-unknown-linux-gnu
mv tokl-v0.1.0-x86_64-unknown-linux-gnu tokl
./tokl .
```

> Note: the macOS build currently targets Apple Silicon (aarch64). Intel Mac
> users can build from source instead (see below).

## Security warning

The pre-built binaries are **not code-signed** (no Apple Developer ID or
Microsoft Authenticode certificate; both require paid developer accounts).
Because of that, macOS and Windows may show a security warning the first time
you run them. This is normal for open-source binaries downloaded from GitHub
Releases — the warning does **not** mean the file is malicious.

To be safe, always download from the official
[Releases](https://github.com/OpenMachineware/tokl/releases) page and check
that the asset name matches the release tag you expect.

### macOS (Gatekeeper)

The first run may show: *"tokl" cannot be opened because the developer cannot
be verified.*

- **Option A** — right-click (or Ctrl-click) the file in Finder, choose
  **Open**, then click **Open** in the dialog that appears.
- **Option B** — remove the quarantine flag in Terminal, then run:

  ```bash
  xattr -d com.apple.quarantine tokl
  ./tokl .
  ```

  (If the command reports `No such xattr`, the file has no quarantine flag —
  just run it.)

## Build from source

```bash
mojo build src/main.mojo -o tokl
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
| `-i, --ignore <PATTERN>` | Ignore dirs/languages/extensions, repeatable; merged with `default_ignore_dirs`, `default_ignore_langs` and the repository's version-control ignore file |
| `-e, --ext <EXT>` | Count only the given extensions, repeatable; merged with `default_exts` |
| `-j, --jobs <N>` | Number of counting threads (default: number of CPU cores) |
| `--init` | Generate a default config file (auto-created on first run) |
| `<PATH>` | Paths to count, multiple allowed, recursive |

Examples:

```bash
tokl .
tokl -m deepseek-v4 -f markdown src tests
tokl -i node_modules -i target -e rs -e py .
tokl -m qwen --verbose ~/projects/myapp
tokl -e ui .          # count Qt .ui files (extensions of unregistered languages)
tokl -j 8 .           # count with 8 parallel threads
```

## Version control

When the path you count is inside a **git / svn / hg / bzr / fossil**
repository, tokl automatically applies the repository's ignore rules
(`.gitignore`, `.svnignore`, `.hgignore`, `.bzrignore` or `.ignore`) on top
of the `-i` / config ignores (the rules are merged — anything ignored by
either side is skipped):

```text
# .gitignore:  *.log          → notes.log is skipped
# -i build:                   → build/ is skipped
# both:                       → the union of the two sets
```

The supported pattern syntax follows gitignore: `#` comments, `!` negation,
trailing `/` for directories, `/`-anchored paths, and the `*` / `?` /
`[...]` / `**` globs. Mercurial's `.hgignore` is honored for its
`syntax: glob` rules only (its default regexp syntax is not implemented).
Use `-v` to see which repository and how many rules were detected.

## Config file

Default location `~/.config/tokl/user_config.toml`
(`%APPDATA%\tokl\user_config.toml` on Windows). **The file is generated
automatically on first run**, so nothing needs to be configured before first
use; you can also create it explicitly with `--init`, or point to another
path via the `TOKL_CONFIG` environment variable.

The generated defaults fit most developer workflows: the default model is
**DeepSeek V4** (a domestic LLM), common build/dependency/cache directories
are ignored, and all file types are counted:

```toml
# Default LLM used (the -m flag takes precedence).
# A domestic LLM is the default: DeepSeek V4 (Byte-level BPE, 128K vocab).
default_model = "deepseek-v4"

# Default output format (maps to -f; supports table, json, markdown)
default_format = "table"

# Default directories to ignore (maps to -i, matched by directory name);
# arrays may span multiple lines
default_ignore_dirs = [
    "node_modules",
    "target",
    ".git",
    ".hg",
    ".svn",
    "dist",
    "build",
    "out",
    "coverage",
    "__pycache__",
    ".venv",
    "venv",
    ".idea",
    ".vscode",
    ".next",
    ".nuxt",
    "vendor",
    "Pods",
    ".gradle",
    ".terraform",
    ".cache",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".tox",
    ".nox",
    ".dart_tool",
]

# Default languages to ignore (maps to -i; filtered by extension or language name)
default_ignore_langs = [
    "svg",
    "lock",
    "map",
]

# Default extensions to count only (maps to -e; empty counts all types)
default_exts = []

# Optional: tokenizer vocab directory; exact token counting is enabled
# once each model's vocab files are placed here
# tokenizer_dir = "/path/to/vocabs"
```

Multi-line arrays (as in the example above) are supported, as well as the
usual single-line form.

## Models and tokenizers

Each model's tokenization algorithm falls into one of two families:
**Byte-level BPE** (tiktoken style) and **SentencePiece** (BPE with byte fallback).

| Model | Aliases | Tokenizer type | Vocab source |
| --- | --- | --- | --- |
| `chatgpt` | `gpt-5.6` `gpt-5.5` `gpt-5.2` `gpt-4o` `gpt-5` `sol` `terra` `luna` `o1` `o3`, etc. | Byte-level BPE | tiktoken `o200k_base` / `cl100k_base` |
| `claude` | `claude-5` `claude-opus-5` `claude-fable-5` `claude-mythos-5` `claude-4.8` `claude-4` `claude-sonnet`, etc. | BPE (not open source) | no public vocab, approximate by default |
| `gemini` | `gemini-3.5` `gemini-3` `gemma`, etc. | SentencePiece | based on Gemma vocab (`gemma_tokenizer.model`) |
| `grok` | `grok-4.6` `grok-4.3` `grok-4.1` `grok-4` `grok-1` `xai`, etc. | SentencePiece | open `tokenizer.model` from Grok-1 |
| `deepseek` | `deepseek-v4` `deepseek-v4-pro` `deepseek-v4-flash` `deepseek-v3` `deepseek-coder`, etc. | Byte-level BPE | 128K vocab (`deepseek_v4.tokenizer.json`) |
| `glm` | `glm-5.2` `glm-5` `glm-4.7` `glm-4` `zhipu`, etc. | BPE | GLM `tokenizer.json` |
| `kimi` | `kimi-k3` `kimi-k2` `moonshot`, etc. | SentencePiece | open `tokenizer.model` from Kimi K2/K3 |
| `qwen` | `qwen3.5` `qwen3.5-omni` `qwen3` `qwen2.5`, etc. | Byte-level BPE | `qwen.tiktoken` |
| `seed` | `seed-2.0` `doubao-seed-2.0` `doubao`, etc. | BPE (proprietary) | no public vocab, approximate by default |
| `yuanbao` | `hunyuan` `hunyuan-turbos` `hunyuan-t1` `hy3`, etc. | SentencePiece | Hunyuan `tokenizer.model` |
| `llama` | `llama-4.1` `llama-4` `scout` `maverick` `llama3` `meta`, etc. | Byte-level BPE | Llama 3/4 `llama3.tiktoken` |
| `llama2` | `llama-2`, etc. | SentencePiece | Llama 2 `tokenizer.model` |
| `mistral` | `mistral-3` `mistral-medium-3.5` `mistral-small-4` `mixtral`, etc. | SentencePiece | Mistral `tokenizer.model` |

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
(e.g. `deepseek-ai/DeepSeek-V4-Pro-Base`, `zai-org/glm-5`, `Qwen/Qwen3.5`,
`xai-org/grok-1`, `moonshotai/Kimi-K2`); use `-v` to see which tokenizer
source is actually in use.

## Language support

C, C++, Assembly (asm/s/S), Java, Kotlin, Scala, D, Vim script, Bash, Zsh, Fish,
Perl, Python, Mojo, Tcl, Lua, PHP, Ruby, SQL, JSON, XML, XHTML, HTML, CSS,
JavaScript, JSX, TypeScript, TSX, TOML, YAML, Rust, Go, Swift, Verilog,
SystemVerilog, VHDL, Makefile, Ninja, CMake, Dockerfile, INI, Markdown,
LaTeX, Texinfo, GCC MD (`.md`, lower priority than Markdown), LLVM TableGen (`.td`).

## Sample output

```
Language        Files    Tokens    Lines   Blanks   Comments     Code
─────────────────────────────────────────────────────────────────────
Rust              183   165,642   51,131    4,789      6,636   39,706
Markdown           35     9,124    6,238    1,545          0    4,693
SystemVerilog       6       701       92        8         42       42
TOML                2        91       42        8          0       34
─────────────────────────────────────────────────────────────────────
Total             226   175,558   57,503    6,350      6,678   44,475
─────────────────────────────────────────────────────────────────────
```

Column order is `Language Files Tokens Lines Blanks Comments Code` (Tokens sits
between Files and Lines).

## License

GPL-3.0
