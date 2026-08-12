# tokl -- Token and Line Counter

[![英文文档](https://img.shields.io/badge/English_Docs-Click_here-brightgreen?style=for-the-badge)](./README.md)
[![Release](https://img.shields.io/github/v/release/OpenMachineware/tokl?sort=semver&style=for-the-badge)](https://github.com/OpenMachineware/tokl/releases)

统计代码行数与 Token 数量的命令行工具。

- 行数统计：按语言语法（注释 / 字符串标记）区分 **Code / Comments / Blanks**
- Token 统计：为 13 类主流大模型（ChatGPT / Claude / Gemini / Grok / DeepSeek /
  GLM / Kimi / Qwen / Seed / Yuanbao / Llama / Mistral）提供分词计数，
  别名跟踪最新版本（DeepSeek V4、GPT-5.6、Claude 5、Gemini 3.5、Grok 4.6、
  GLM-5.2、Kimi K3、Qwen3.5 等）
- 首次运行自动生成配置文件（`~/.config/tokl/user_config.toml`），默认值符合
  大多数开发者需求（默认模型：DeepSeek V4）
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
| Linux（x86_64） | `tokl-<tag>-x86_64-unknown-linux-gnu` |
| macOS（Apple Silicon） | `tokl-<tag>-aarch64-apple-darwin` |
| Windows（x86_64） | `tokl-<tag>-x86_64-pc-windows-msvc.exe` |

下载对应平台的版本后，加执行权限、改个名就能直接用，无需安装、无任何依赖：

```bash
# Linux / macOS（以 v0.1.0 为例）：
curl -LO https://github.com/OpenMachineware/tokl/releases/download/v0.1.0/tokl-v0.1.0-x86_64-unknown-linux-gnu
chmod +x tokl-v0.1.0-x86_64-unknown-linux-gnu
mv tokl-v0.1.0-x86_64-unknown-linux-gnu tokl
./tokl .
```

```powershell
# Windows：把下载的 .exe 重命名后直接运行
ren tokl-v0.1.0-x86_64-pc-windows-msvc.exe tokl.exe
.\tokl.exe .
```

> 说明：macOS 目前只构建 Apple Silicon（aarch64）版本，Intel Mac 用户请从源码构建（见下）。

## 安全警告

预编译二进制**未做代码签名**（没有 Apple Developer ID 或 Microsoft
Authenticode 证书——两者都需要付费的开发者账号）。因此 macOS 和 Windows
首次运行时都可能弹出安全警告。开源软件从 GitHub Releases 下载的二进制出现
这种情况很正常——**出现警告不代表文件有恶意**。

为安全起见，请始终从官方
[Releases](https://github.com/OpenMachineware/tokl/releases) 页面下载，
并核对文件名与发布版本号一致。

### macOS（Gatekeeper）

首次运行可能提示：*无法打开“tokl”，因为无法验证开发者。*

- **方式一**：在 Finder 中右键（或按住 Control 点击）该文件，选择**打开**，
  在弹出的对话框中再次点击**打开**。
- **方式二**：在终端中清除隔离属性后再运行：

  ```bash
  xattr -d com.apple.quarantine tokl
  ./tokl .
  ```

  （若提示 `No such xattr`，说明文件没有隔离属性，直接运行即可。）

### Windows（SmartScreen）

首次运行可能提示：*Windows 已保护你的电脑。*

- **方式一**：右键 `.exe` 文件 → **属性**，勾选底部的**解除锁定**，点击**确定**，
  然后正常运行。
- **方式二**：在警告弹窗中点击**更多信息**，再点击**仍要运行**。

  也可以在 PowerShell 中编程式解除锁定：

  ```powershell
  Unblock-File .\tokl.exe
  ```

## 从源码构建

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

| 模型 | 别名 | 分词器类型 | 词表来源 |
| --- | --- | --- | --- |
| `chatgpt` | `gpt-5.6` `gpt-5.5` `gpt-5.2` `gpt-4o` `gpt-5` `sol` `terra` `luna` `o1` `o3` 等 | Byte-level BPE | tiktoken 的 `o200k_base` / `cl100k_base` |
| `claude` | `claude-5` `claude-opus-5` `claude-fable-5` `claude-mythos-5` `claude-4.8` `claude-4` `claude-sonnet` 等 | BPE（未开源） | 无公开词表，默认近似 |
| `gemini` | `gemini-3.5` `gemini-3` `gemma` 等 | SentencePiece | 基于 Gemma 词表（`gemma_tokenizer.model`） |
| `grok` | `grok-4.6` `grok-4.3` `grok-4.1` `grok-4` `grok-1` `xai` 等 | SentencePiece | Grok-1 开源 `tokenizer.model` |
| `deepseek` | `deepseek-v4` `deepseek-v4-pro` `deepseek-v4-flash` `deepseek-v3` `deepseek-coder` 等 | Byte-level BPE | 128K 词表（`deepseek_v4.tokenizer.json`） |
| `glm` | `glm-5.2` `glm-5` `glm-4.7` `glm-4` `zhipu` 等 | BPE | GLM `tokenizer.json` |
| `kimi` | `kimi-k3` `kimi-k2` `moonshot` 等 | SentencePiece | Kimi K2/K3 开源 `tokenizer.model` |
| `qwen` | `qwen3.5` `qwen3.5-omni` `qwen3` `qwen2.5` 等 | Byte-level BPE | `qwen.tiktoken` |
| `seed` | `seed-2.0` `doubao-seed-2.0` `doubao` `豆包` 等 | BPE（自研） | 无公开词表，默认近似 |
| `yuanbao` | `hunyuan` `hunyuan-turbos` `hunyuan-t1` `hy3` `混元` 等 | SentencePiece | 混元 `tokenizer.model` |
| `llama` | `llama-4.1` `llama-4` `scout` `maverick` `llama3` `meta` 等 | Byte-level BPE | Llama 3/4 `llama3.tiktoken` |
| `llama2` | `llama-2` 等 | SentencePiece | Llama 2 `tokenizer.model` |
| `mistral` | `mistral-3` `mistral-medium-3.5` `mistral-small-4` `mixtral` 等 | SentencePiece | Mistral `tokenizer.model` |

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
Perl, Python, Tcl, Lua, PHP, Ruby, SQL, JSON, XML, XHTML, HTML, CSS,
JavaScript, JSX, TypeScript, TSX, TOML, YAML, Rust, Go, Swift, Verilog,
SystemVerilog, VHDL, Makefile, Ninja, CMake, Dockerfile, INI, Markdown,
LaTeX, Texinfo, GCC MD（`.md`，优先级低于 Markdown）, LLVM TableGen（`.td`）。

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
