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
use std::path::{Path, PathBuf};

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

/// Resolve the config file path, whether or not the file exists yet.
///
/// Priority: `TOKL_CONFIG` environment variable, then the platform config
/// directory (`~/.config/tokl/user_config.toml` on Linux/macOS,
/// `%APPDATA%\tokl\user_config.toml` on Windows).
pub fn config_file_path() -> Option<PathBuf> {
    if let Ok(p) = env::var("TOKL_CONFIG") {
        if !p.is_empty() {
            return Some(PathBuf::from(p));
        }
    }
    config_dir().map(|d| d.join("user_config.toml"))
}

/// Return the config file path, if it exists.
pub fn config_path() -> Option<PathBuf> {
    config_file_path().filter(|p| p.is_file())
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

/// Write the default config template to `path`, creating parent directories.
pub fn write_default_config(path: &Path) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    std::fs::write(path, DEFAULT_CONFIG_TEMPLATE)
}

/// First-run bootstrap: create the default config file when missing.
///
/// Best effort only - a failure is reported as a warning and never aborts
/// the run (built-in defaults are used instead). Returns the path when a
/// new file was written.
pub fn ensure_default_config() -> Option<PathBuf> {
    let path = config_file_path()?;
    if path.is_file() {
        return None;
    }
    match write_default_config(&path) {
        Ok(()) => Some(path),
        Err(e) => {
            eprintln!(
                "[warning] cannot create default config file {}: {}",
                path.display(),
                e
            );
            None
        }
    }
}

/// Load config; return the default (empty) config if the file is missing.
///
/// On first run (no config file yet) a default config file is generated
/// automatically so the user can find and tweak it.
pub fn load() -> Config {
    let mut cfg = Config::default();
    if let Some(path) = ensure_default_config() {
        eprintln!("generated default config file: {}", path.display());
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_template_parses() {
        let toml = MiniToml::parse(DEFAULT_CONFIG_TEMPLATE).unwrap();
        assert_eq!(toml.get_str("default_model").unwrap(), "deepseek-v4");
        assert_eq!(toml.get_str("default_format").unwrap(), "table");
        let dirs = toml.get_str_array("default_ignore_dirs").unwrap();
        assert!(dirs.contains(&"node_modules".to_string()));
        assert!(dirs.contains(&".dart_tool".to_string()));
        let langs = toml.get_str_array("default_ignore_langs").unwrap();
        assert!(langs.contains(&"svg".to_string()));
        assert!(toml.get_str_array("default_exts").unwrap().is_empty());
    }

    #[test]
    fn test_config_file_path_prefers_env() {
        // TOKL_CONFIG wins even if the file does not exist yet
        unsafe {
            std::env::set_var("TOKL_CONFIG", "/nonexistent/tokl/config.toml");
        }
        let p = config_file_path().unwrap();
        assert_eq!(p, PathBuf::from("/nonexistent/tokl/config.toml"));
        unsafe { std::env::remove_var("TOKL_CONFIG") };
    }
}

/// Default config file contents (written on first run and by --init).
pub const DEFAULT_CONFIG_TEMPLATE: &str = r#"# tokl user configuration
#
# This file is generated automatically on first run. You can edit it and
# the changes will take effect the next time tokl starts.

# Default LLM used for token counting (the -m flag takes precedence).
# A domestic LLM is the default: DeepSeek V4 (Byte-level BPE, 128K vocab).
default_model = "deepseek-v4"

# Default output format (maps to -f; supports table, json, markdown)
default_format = "table"

# Default directories to ignore (maps to -i; matched by exact directory
# name, case-insensitively). Covers common dependency/build/cache dirs:
#   JS/TS: node_modules, dist, .next, .nuxt, vendor
#   Rust:  target        Java: .gradle        Python: __pycache__,
#   .venv, venv, .mypy_cache, .pytest_cache, .ruff_cache, .tox, .nox
#   Generic: .git, .hg, .svn, build, out, coverage, .idea, .vscode,
#   .terraform, .cache, .dart_tool, Pods
# When scanning inside a git/svn/hg/bzr/fossil repository, the repository's
# ignore file (.gitignore etc.) is also applied and merged with this list.
# 当扫描路径位于 git/svn/hg/bzr/fossil 仓库内时，仓库的忽略文件
# （.gitignore 等）也会自动生效，与本列表取并集。
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

# Default languages to ignore (maps to -i; filtered by extension or
# language name): svg images, lockfiles and source maps are rarely of
# interest when counting code.
default_ignore_langs = [
    "svg",
    "lock",
    "map",
]

# Default extensions to count only (maps to -e).
# Empty counts all file types; set it, e.g. ["rs", "py", "js"], if you
# usually want to restrict counting to specific languages.
default_exts = []

# Optional: tokenizer vocab directory. Put each model's vocab files here
# (tokenizer.json / tokenizer.model / *.tiktoken) to get exact token counts;
# the built-in approximate algorithm is used when unset or not found.
# tokenizer_dir = "/path/to/vocabs"
"#;
