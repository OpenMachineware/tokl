# tokl -- Token and Line Counter

[![英文文档](https://img.shields.io/badge/English_Docs-Click_here-brightgreen?style=for-the-badge)](./README.md)

统计代码行数与 Token 数量的命令行工具。

- 行数统计：按语言语法（注释 / 字符串标记）区分 **Code / Comments / Blanks**，
  风格与 [scc](https://github.com/boyter/scc) 类似
- Token 统计：为 13 类主流大模型（ChatGPT / Claude / Gemini / Grok / DeepSeek /
  GLM / Kimi / Qwen / Seed / Yuanbao / Llama / Mistral）提供分词计数
- 纯 Rust 标准库实现，无第三方依赖，单二进制分发（macOS / Linux / Windows）
- 多线程并行统计，默认使用全部 CPU 核心，可用 `-j` 调整线程数
- 模块化设计：`cli`（参数解析）、`config`（配置加载）、`scanner`（文件扫描）、
  `language`（语言定义）、`count`（行数统计）、`tokenize`（分词器适配）、
  `format`（输出格式化）

## 构建

```bash
cargo build --release
# 二进制位于 target/release/tokl
```

## 用法

```
tokl [选项] <PATH...>
```

| 参数 | 说明 |
| --- | --- |
| `-h, --help` | 打印帮助 |
| `--version` | 版本与版权信息 |
| `-v, --verbose` | 详细输出（分词器来源、跳过文件等） |
| `-m, --model <MODEL>` | 指定模型（优先级高于配置文件） |
| `-f, --format <json\|table\|markdown>` | 输出格式（优先级高于配置文件） |
| `-i, --ignore <PATTERN>` | 忽略目录/语言/后缀，可多次；与配置 `default_ignore_dirs`、`default_ignore_langs` 取并集 |
| `-e, --ext <EXT>` | 只统计指定后缀，可多次；与配置 `default_exts` 取并集 |
| `-j, --jobs <N>` | 计数线程数（默认：CPU 核心数） |
| `--init` | 生成默认配置文件 |
| `<PATH>` | 要统计的路径，可多个，自动递归 |

示例：

```bash
tokl .
tokl -m deepseek-v3 -f markdown src tests
tokl -i node_modules -i target -e rs -e py .
tokl -m qwen --verbose ~/projects/myapp
tokl -j 8 .                # 用 8 个线程并行统计
tokl -e ui .          # 统计 Qt 的 .ui 文件（未注册语言的扩展名）
```

## 配置文件

默认位置 `~/.config/tokl/user_config.toml`（Windows 为 `%APPDATA%\tokl\user_config.toml`），
可用 `--init` 一键生成，也可通过环境变量 `TOKL_CONFIG` 指定其它路径：

```toml
# 默认使用的大模型（命令行 -m 优先级更高）
default_model = "deepseek-v3"

# 默认的输出格式（对应 -f 参数，支持 table, json, markdown）
default_format = "table"

# 默认忽略的目录（对应 -i 参数，忽略目录）
default_ignore_dirs = ["node_modules", "target", ".git", "dist", "__pycache__"]

# 默认忽略的语言（对应 -i 参数，按后缀或语言名过滤）
default_ignore_langs = ["svg", "lock"]

# 默认只统计的后缀（对应 -e 参数，留空或不写则统计所有）
default_exts = ["rs", "py", "cpp"]

# 可选：分词器词表目录，放入各模型的词表文件后启用精确 Token 计数
# tokenizer_dir = "/path/to/vocabs"
```

## 模型与分词器

各模型的分词算法分为两类：**Byte-level BPE**（tiktoken 风格）与 **SentencePiece**（BPE with byte fallback）。

| 模型 | 别名 | 分词器类型 | 词表来源 |
| --- | --- | --- | --- |
| `chatgpt` | `gpt-4o` `gpt-5` `o1` `o3` 等 | Byte-level BPE | tiktoken 的 `o200k_base` / `cl100k_base` |
| `claude` | `claude-3` `claude-sonnet` 等 | BPE（未开源） | 无公开词表，默认近似 |
| `gemini` | `gemma` 等 | SentencePiece | 基于 Gemma 词表（`gemma_tokenizer.model`） |
| `grok` | `grok-1` `xai` 等 | SentencePiece | Grok-1 开源 `tokenizer.model` |
| `deepseek` | `deepseek-v3` `deepseek-coder` 等 | Byte-level BPE | 128K 词表（`deepseek_v3.tokenizer.json`） |
| `glm` | `glm-4` `zhipu` 等 | BPE | GLM-4 `tokenizer.json` |
| `kimi` | `kimi-k2` `moonshot` 等 | SentencePiece | Kimi K2 开源 `tokenizer.model` |
| `qwen` | `qwen2.5` `qwen3` 等 | Byte-level BPE | `qwen.tiktoken` |
| `seed` | `doubao` `豆包` 等 | BPE（自研） | 无公开词表，默认近似 |
| `yuanbao` | `hunyuan` `混元` 等 | SentencePiece | 混元 `tokenizer.model` |
| `llama` | `llama3` `meta` 等 | Byte-level BPE | Llama 3 `llama3.tiktoken` |
| `llama2` | `llama-2` 等 | SentencePiece | Llama 2 `tokenizer.model` |
| `mistral` | `mixtral` 等 | SentencePiece | Mistral `tokenizer.model` |

### 精确 vs 近似

- **近似模式（默认）**：无需任何词表。英文/代码按约 4 字节 1 token、
  中文按约 1 字 1 token 估算，误差一般在 ±20% 以内。
- **精确模式**：在 `tokenizer_dir` 目录放入对应模型的词表文件即可自动启用。
  支持的格式：
  - `.tiktoken`（tiktoken / GPT 家族、Qwen、DeepSeek 等）
  - `tokenizer.json`（HuggingFace BPE 格式，GLM、DeepSeek 等）
  - `tokenizer.model`（SentencePiece，Gemini / Grok / Kimi / Llama 2 / Mistral 等）
- `chatgpt` 还会自动检测本机 tiktoken 缓存（如 `/tmp/data-gym-cache/o200k_base.tiktoken`）。

词表可从 HuggingFace 对应模型仓库下载（如 `deepseek-ai/DeepSeek-V3`、
`zai-org/glm-4-9b`、`Qwen/Qwen2.5`、`mistralai/Mistral-7B-v0.1`、
`xai-org/grok-1`、`moonshotai/Kimi-K2` 等），用 `-v` 可查看实际使用的分词器来源。

## 语言支持

C, C++, 汇编 (asm/s/S), Java, Kotlin, Scala, D, Vim 脚本, Bash, Zsh, Fish,
Perl, Python, Tcl, Lua, PHP, Ruby, SQL, JSON, XML, XHTML, HTML, CSS,
JavaScript, JSX, TypeScript, TSX, TOML, YAML, Rust, Go, Swift, Verilog,
SystemVerilog, VHDL, Makefile, Ninja, CMake, Dockerfile, INI, Markdown,
LaTeX, Texinfo, GCC MD（`.md`，优先级低于 Markdown）, LLVM TableGen（`.td`）。

## 输出示例

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

列顺序为 `Language Files Tokens Lines Blanks Comments Code`（在 scc 基础上
去掉 Complexity 列，并在 Files 与 Lines 之间插入 Tokens 列）。

## 许可证

GPL-3.0
