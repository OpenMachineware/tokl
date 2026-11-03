# tokl -- Token and Line Counter

[![英文文档](https://img.shields.io/badge/English_Docs-Click_here-brightgreen?style=for-the-badge)](./README.md)
[![Release](https://img.shields.io/github/v/release/OpenMachineware/tokl?sort=semver&style=for-the-badge)](https://github.com/OpenMachineware/tokl/releases)

统计代码行数与 Token 数量的命令行工具。

- 行数统计：按语言语法（注释 / 字符串标记）区分 **Code / Comments / Blanks**
- Token 统计：为 13 类主流大模型（ChatGPT / Claude / Gemini / Grok / DeepSeek /
  GLM / Kimi / Qwen / Seed / Yuanbao / Llama / Mistral）提供分词计数
- 首次运行自动生成配置文件（`~/.config/tokl/user_config.toml`），默认值符合
  大多数开发者需求（默认模型：DeepSeek）
- 纯 Rust 标准库实现，无第三方依赖，单二进制分发（macOS / Linux / Windows）
- 多线程并行统计，默认使用全部 CPU 核心，可用 `-j` 调整线程数
- 模块化设计：`cli`（参数解析）、`config`（配置加载）、`scanner`（文件扫描）、
  `language`（语言定义）、`count`（行数统计）、`tokenize`（分词器适配）、
  `format`（输出格式化）

## 安装（下载预编译二进制）

每个 [GitHub Release](https://github.com/OpenMachineware/tokl/releases) 都附带
预编译二进制：推送 `v*` 标签时，GitHub Actions 会自动构建并上传。

| 平台 | 文件名 |
| --- | --- |
| Linux（x86_64） | `tokl-<tag>-x86_64-unknown-linux-gnu.tar.gz` |
| macOS（Apple Silicon） | `tokl-<tag>-aarch64-apple-darwin.tar.gz` |
| Windows（x86_64） | `tokl-<tag>-x86_64-pc-windows-msvc.zip` |

下载对应平台的版本后，解压即可使用，无需安装、无任何依赖：

```bash
# Linux / macOS（以 v0.1.4 为例）：
curl -LO https://github.com/OpenMachineware/tokl/releases/download/v0.1.4/tokl-v0.1.4-x86_64-unknown-linux-gnu.tar.gz
tar -xzf tokl-v0.1.4-x86_64-unknown-linux-gnu.tar.gz
./tokl .
```

```powershell
# Windows（PowerShell，以 v0.1.4 为例）：
Invoke-WebRequest -Uri https://github.com/OpenMachineware/tokl/releases/download/v0.1.4/tokl-v0.1.4-x86_64-pc-windows-msvc.zip -OutFile tokl.zip
Expand-Archive tokl.zip
.\tokl\tokl.exe .
```

> 说明：macOS 构建目标为 Apple Silicon（aarch64）并已代码签名。Intel Mac 用户请从源码构建（见下）。

## 从源码构建

```bash
cargo build --release
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
| `-i, --ignore <PATTERN>` | 忽略目录/语言/后缀，可多次；与配置 `default_ignore_dirs`、`default_ignore_langs` 及版本控制忽略文件取并集 |
| `-e, --ext <EXT>` | 只统计指定后缀，可多次；与配置 `default_exts` 取并集 |
| `-j, --jobs <N>` | 计数线程数（默认：CPU 核心数） |
| `--init` | 生成默认配置文件（首次运行会自动生成） |
| `<PATH>` | 要统计的路径，可多个，自动递归 |

示例：

```bash
tokl .
tokl -m deepseek-v4 -f markdown src tests
tokl -i node_modules -i target -e rs -e py .
tokl -m qwen --verbose ~/projects/myapp
tokl -j 8 .                # 用 8 个线程并行统计
tokl -e ui .          # 统计 Qt 的 .ui 文件（未注册语言的扩展名）
```

## 版本控制

当统计路径位于 **git / svn / hg / bzr / fossil** 仓库内时，tokl 会自动读取
仓库的忽略文件（`.gitignore`、`.svnignore`、`.hgignore`、`.bzrignore` 或
`.ignore`），并与 `-i` / 配置中的忽略规则**取并集**——任何一方忽略都会被跳过：

```text
# .gitignore:  *.log          → notes.log 被跳过
# -i build:                   → build/ 被跳过
# 两者取并集：                → 两侧规则都生效
```

支持的匹配语法与 gitignore 一致：`#` 注释、`!` 取反、结尾 `/` 表示目录、
含 `/` 的模式相对仓库根锚定匹配，以及 `*` / `?` / `[...]` / `**` 通配符。
Mercurial 的 `.hgignore` 仅支持其 `syntax: glob` 规则（默认的正则语法未实现）。
用 `-v` 可查看检测到的仓库与规则数量。

## 配置文件

默认位置 `~/.config/tokl/user_config.toml`（Windows 为 `%APPDATA%\tokl\user_config.toml`）。
**首次运行会自动生成该文件**，开箱即用；也可用 `--init` 显式生成，或通过
环境变量 `TOKL_CONFIG` 指定其它路径。

生成的默认值贴合大多数开发者场景：默认模型为**国产 DeepSeek V4**，
自动忽略常见的构建 / 依赖 / 缓存目录，统计所有文件类型：

```toml
# 默认使用的大模型（命令行 -m 优先级更高）。
# 默认国产大模型：DeepSeek V4（Byte-level BPE，128K 词表）。
default_model = "deepseek-v4"

# 默认的输出格式（对应 -f 参数，支持 table, json, markdown）
default_format = "table"

# 默认忽略的目录（对应 -i 参数，按目录名匹配）；数组支持跨行书写
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

# 默认忽略的语言（对应 -i 参数，按后缀或语言名过滤）
default_ignore_langs = [
    "svg",
    "lock",
    "map",
]

# 默认只统计的后缀（对应 -e 参数，留空表示统计所有类型）
default_exts = []

# 可选：分词器词表目录，放入各模型的词表文件后启用精确 Token 计数
# tokenizer_dir = "/path/to/vocabs"
```

数组支持跨行书写（如上例所示），也支持常规的单行写法。

## 模型与分词器

各模型的分词算法分为两类：**Byte-level BPE**（tiktoken 风格）与 **SentencePiece**（BPE with byte fallback）。

| 模型 | 分词器类型 | 词表来源 |
| --- | --- | --- |
| `chatgpt` | Byte-level BPE | tiktoken 的 `o200k_base` / `cl100k_base` |
| `claude` | BPE（未开源） | 无公开词表，默认近似 |
| `gemini` | SentencePiece | 基于 Gemma 词表（`gemma_tokenizer.model`） |
| `grok` | SentencePiece | Grok-1 开源 `tokenizer.model` |
| `deepseek` | Byte-level BPE | 128K 词表（`deepseek_v4.tokenizer.json`） |
| `glm` | BPE | GLM `tokenizer.json` |
| `kimi` | SentencePiece | Kimi 开源 `tokenizer.model` |
| `qwen` | Byte-level BPE | `qwen.tiktoken` |
| `seed` | BPE（自研） | 无公开词表，默认近似 |
| `yuanbao` | SentencePiece | 混元 `tokenizer.model` |
| `llama` | Byte-level BPE | Llama `llama3.tiktoken` |
| `llama2` | SentencePiece | Llama 2 `tokenizer.model` |
| `mistral` | SentencePiece | Mistral `tokenizer.model` |

各模型均支持常用别名（如 `gpt`、`claude`、`gemini`、`deepseek`、`qwen` 等）。

### 精确 vs 近似

- **近似模式（默认）**：无需任何词表。英文/代码按约 4 字节 1 token、
  中文按约 1 字 1 token 估算，误差一般在 ±20% 以内。
- **精确模式**：在 `tokenizer_dir` 目录放入对应模型的词表文件即可自动启用。
  支持的格式：
  - `.tiktoken`（tiktoken / GPT 家族、Qwen、DeepSeek 等）
  - `tokenizer.json`（HuggingFace BPE 格式，GLM、DeepSeek 等）
  - `tokenizer.model`（SentencePiece，Gemini / Grok / Kimi / Llama 2 / Mistral 等）
- `chatgpt` 还会自动检测本机 tiktoken 缓存（如 `/tmp/data-gym-cache/o200k_base.tiktoken`）。

词表可从 HuggingFace 对应模型仓库下载（如 `deepseek-ai/DeepSeek-V4-Pro-Base`、
`zai-org/glm-5`、`Qwen/Qwen3.5`、`xai-org/grok-1`、`moonshotai/Kimi-K2` 等），
用 `-v` 可查看实际使用的分词器来源。

## 语言支持

C, C++, 汇编 (asm/s/S), Java, Kotlin, Scala, D, Vim 脚本, Bash, Zsh, Fish,
Perl, Python, Mojo, Tcl, Lua, PHP, Ruby, SQL, JSON, XML, XHTML, HTML, CSS,
JavaScript, JSX, TypeScript, TSX, TOML, YAML, Rust, Go, Swift, Verilog,
SystemVerilog, VHDL, Makefile, Ninja, CMake, Dockerfile, INI, Markdown,
LaTeX, Texinfo, GCC MD（`.md`，优先级低于 Markdown）, LLVM TableGen（`.td`）。

GPU 着色器语言：CUDA（`.cu`/`.cuh`）、HIP/ROCm（`.hip`）、Metal（`.metal`）、
GLSL（`.glsl`/`.vert`/`.frag`/`.comp`/`.tesc`/`.tese`/`.geom`）、
HLSL（`.hlsl`/`.fx`/`.fxh`）、WGSL（`.wgsl`）。

WebAssembly：WAT（`.wat`/`.wast`）。

## 输出示例

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

列顺序为 `Language Files Tokens Lines Blanks Comments Code`（Tokens 位于
Files 与 Lines 之间）。

## 许可证

GPL-3.0
