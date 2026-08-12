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
//! Config loading: read ~/.config/tokl/user_config.toml (Linux/macOS)
//! or %APPDATA%\tokl\user_config.toml (Windows).

use std::env;
use std::path::PathBuf;

use crate::toml::MiniToml;

#[derive(Debug, Clone, Default)]
pub struct Config {
    pub default_model: Option<String>,
    pub default_format: Option<String>,
    pub default_ignore_dirs: Vec<String>,
    pub default_ignore_langs: Vec<String>,
    pub default_exts: Vec<String>,
    /// Optional: directory holding tokenizer vocab files (exact token counting)
    pub tokenizer_dir: Option<String>,
}

/// Return the config file path, if it exists.
pub fn config_path() -> Option<PathBuf> {
    if let Ok(p) = env::var("TOKL_CONFIG") {
        let p = PathBuf::from(p);
        if p.is_file() {
            return Some(p);
        }
    }
    let dir = config_dir()?;
    let p = dir.join("user_config.toml");
    if p.is_file() {
        Some(p)
    } else {
        None
    }
}

/// The directory holding the config file (may not exist).
pub fn config_dir() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        if let Some(appdata) = env::var_os("APPDATA") {
            return Some(PathBuf::from(appdata).join("tokl"));
        }
    }
    #[cfg(not(windows))]
    {
        if let Some(xdg) = env::var_os("XDG_CONFIG_HOME") {
            if !xdg.is_empty() {
                return Some(PathBuf::from(xdg).join("tokl"));
            }
        }
        if let Some(home) = env::var_os("HOME") {
            return Some(PathBuf::from(home).join(".config").join("tokl"));
        }
    }
    None
}

/// Load config; return the default (empty) config if the file is missing.
pub fn load() -> Config {
    let mut cfg = Config::default();
    let Some(path) = config_path() else {
        return cfg;
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        eprintln!("[warning] cannot read config file: {}", path.display());
        return cfg;
    };
    match MiniToml::parse(&text) {
        Ok(toml) => {
            if let Some(v) = toml.get_str("default_model") {
                cfg.default_model = Some(v);
            }
            if let Some(v) = toml.get_str("default_format") {
                cfg.default_format = Some(v);
            }
            if let Some(v) = toml.get_str_array("default_ignore_dirs") {
                cfg.default_ignore_dirs = v;
            }
            if let Some(v) = toml.get_str_array("default_ignore_langs") {
                cfg.default_ignore_langs = v;
            }
            if let Some(v) = toml.get_str_array("default_exts") {
                cfg.default_exts = v;
            }
            if let Some(v) = toml.get_str("tokenizer_dir") {
                cfg.tokenizer_dir = Some(v);
            }
        }
        Err(e) => {
            eprintln!(
                "[warning] failed to parse config file ({}): {}",
                path.display(),
                e
            )
        }
    }
    cfg
}

/// Default config file contents (reference output for --init).
pub const DEFAULT_CONFIG_TEMPLATE: &str = r#"# tokl user configuration
# Default LLM used (the -m flag takes precedence)
default_model = "deepseek-v3"

# Default output format (maps to -f; supports table, json, markdown)
default_format = "table"

# Default directories to ignore (maps to -i, ignores directories)
default_ignore_dirs = [
    "node_modules",
    "target",
    ".git",
    "dist",
    "__pycache__",
]

# Default languages to ignore (maps to -i; filtered by extension or language name)
default_ignore_langs = [
    "svg",
    "lock",
]

# Default extensions to count only (maps to -e; empty or unset counts all)
default_exts = ["rs", "py", "cpp"]

# Optional: tokenizer vocab directory. Put each model's vocab files here
# (tokenizer.json / tokenizer.model / *.tiktoken) to get exact token counts;
# the built-in approximate algorithm is used when unset or not found.
# tokenizer_dir = "/path/to/vocabs"
"#;
