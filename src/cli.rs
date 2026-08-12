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
//! Command-line argument parsing.
//!
//! Usage:
//!   tokl [OPTIONS] <PATH...>
//!
//! Options:
//!   -h                       print help
//!   --version                print version and copyright info
//!   -v, --verbose            verbose output (e.g. approximate tokenizer hints)
//!   -m, --model <MODEL>      set the model (takes precedence over config)
//!   -f, --format <FMT>       output format: json | table | markdown
//!   -j, --jobs <N>           number of counting threads
//!                            (default: number of CPU cores)
//!   -i, --ignore <PATTERN>   ignore dirs/languages/extensions
//!                            (repeatable, merged with config)
//!   -e, --ext <EXT>          only count given extensions
//!                            (repeatable, merged with config)
//!   --init                   generate a default config file in the config dir
//!                            (the config file is auto-generated on first run)
//!   <PATH>                   paths to scan (multiple allowed, recursive)

#[derive(Debug, Clone, Default)]
pub struct Options {
    pub verbose: bool,
    pub model: Option<String>,
    pub format: Option<String>,
    pub jobs: Option<usize>,
    pub ignore: Vec<String>,
    pub exts: Vec<String>,
    pub paths: Vec<String>,
    pub show_help: bool,
    pub show_version: bool,
    pub init_config: bool,
}

pub fn parse(args: &[String]) -> Result<Options, String> {
    let mut opts = Options::default();
    let mut it = args.iter().peekable();
    let mut no_more_opts = false;

    while let Some(arg) = it.next() {
        if no_more_opts || !arg.starts_with('-') || arg == "-" {
            opts.paths.push(arg.clone());
            continue;
        }
        match arg.as_str() {
            "--" => no_more_opts = true,
            "-h" | "--help" => opts.show_help = true,
            "--version" | "-V" => opts.show_version = true,
            "-v" | "--verbose" => opts.verbose = true,
            "--init" => opts.init_config = true,
            "-m" | "--model" => {
                let v = it.next().ok_or_else(|| {
                    format!("option {} requires an argument", arg)
                })?;
                opts.model = Some(v.clone());
            }
            "-f" | "--format" => {
                let v = it.next().ok_or_else(|| {
                    format!("option {} requires an argument", arg)
                })?;
                opts.format = Some(v.clone());
            }
            "-i" | "--ignore" => {
                let v = it.next().ok_or_else(|| {
                    format!("option {} requires an argument", arg)
                })?;
                opts.ignore.push(v.clone());
            }
            "-e" | "--ext" => {
                let v = it.next().ok_or_else(|| {
                    format!("option {} requires an argument", arg)
                })?;
                opts.exts.push(v.clone());
            }
            "-j" | "--jobs" => {
                let v = it.next().ok_or_else(|| {
                    format!("option {} requires an argument", arg)
                })?;
                let n: usize = v
                    .parse()
                    .map_err(|_| format!("invalid thread count: {}", v))?;
                if n == 0 {
                    return Err("thread count must be >= 1".to_string());
                }
                opts.jobs = Some(n);
            }
            _ => {
                // Support the --model=value form
                if let Some((key, val)) = arg.split_once('=') {
                    match key {
                        "-m" | "--model" => opts.model = Some(val.to_string()),
                        "-f" | "--format" => {
                            opts.format = Some(val.to_string())
                        }
                        "-i" | "--ignore" => opts.ignore.push(val.to_string()),
                        "-e" | "--ext" => opts.exts.push(val.to_string()),
                        "-j" | "--jobs" => {
                            let n: usize = val.parse().map_err(|_| {
                                format!("invalid thread count: {}", val)
                            })?;
                            if n == 0 {
                                return Err(
                                    "thread count must be >= 1".to_string()
                                );
                            }
                            opts.jobs = Some(n);
                        }
                        _ => return Err(format!("unknown option: {}", arg)),
                    }
                } else {
                    return Err(format!("unknown option: {}", arg));
                }
            }
        }
    }

    if opts.show_help || opts.show_version || opts.init_config {
        return Ok(opts);
    }
    if opts.paths.is_empty() {
        return Err(
            "missing path argument <PATH> (use -h for help)".to_string()
        );
    }
    Ok(opts)
}

pub const USAGE: &str = r#"tokl - count code lines and tokens

Usage:
    tokl [OPTIONS] <PATH...>

Options:
    -h, --help               Print help
    --version                Print version and copyright info
    -v, --verbose            Verbose output
    -m, --model <MODEL>      Model, one of:
                             chatgpt claude gemini grok deepseek glm kimi
                             qwen seed yuanbao llama mistral
                             (aliases allowed, e.g. gpt-5.6 / deepseek-v4)
    -f, --format <FMT>       Output format: json | table | markdown
    -i, --ignore <PATTERN>   Ignore dirs/languages/extensions
                             (repeatable; merged with config)
    -e, --ext <EXT>          Count only given extensions, e.g. -e ui
                             (repeatable; merged with config)
    -j, --jobs <N>           Number of counting threads
                             (default: number of CPU cores)
    --init                   Write default user_config.toml to config dir
                             (created automatically on first run)
    <PATH>                   Paths to scan (multiple allowed, recursive)

Configuration:
    Default config file: ~/.config/tokl/user_config.toml
    (%APPDATA%\tokl\user_config.toml on Windows). It is generated
    automatically on first run (defaults: deepseek-v4, table output,
    common build/dependency dirs ignored). Keys: default_model /
    default_format / default_ignore_dirs / default_ignore_langs /
    default_exts / tokenizer_dir.

Version control:
    When scanning inside a git/svn/hg/bzr/fossil repository, ignore rules
    from the repository's ignore file (.gitignore / .svnignore /
    .hgignore / .bzrignore / .ignore) are applied automatically and merged
    with the -i ignores. Supports *, ?, [...], ** globs and ! negation.

Examples:
    tokl .
    tokl -m deepseek-v4 -f markdown src tests
    tokl -i node_modules -i target -e rs -e py .
    tokl -m qwen --verbose ~/projects/myapp
"#;

pub const VERSION_INFO: &str = concat!(
    "tokl ",
    env!("CARGO_PKG_VERSION"),
    "\n",
    "Counts code lines and tokens\n",
    "License: GPL-3.0\n",
    "Copyright (C) 2026 Jia Liu & tokl contributors"
);

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_args(args: &[&str]) -> Result<Options, String> {
        let v: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        parse(&v)
    }

    #[test]
    fn test_basic() {
        let o = parse_args(&["-m", "qwen", "-f", "json", ".", "-v"]).unwrap();
        assert_eq!(o.model.as_deref(), Some("qwen"));
        assert_eq!(o.format.as_deref(), Some("json"));
        assert_eq!(o.paths, vec!["."]);
        assert!(o.verbose);
    }

    #[test]
    fn test_equals_form() {
        let o = parse_args(&["--model=qwen", "-i=node_modules", "."]).unwrap();
        assert_eq!(o.model.as_deref(), Some("qwen"));
        assert_eq!(o.ignore, vec!["node_modules"]);
    }

    #[test]
    fn test_jobs() {
        let o = parse_args(&["-j", "8", "."]).unwrap();
        assert_eq!(o.jobs, Some(8));
        let o = parse_args(&["--jobs=4", "."]).unwrap();
        assert_eq!(o.jobs, Some(4));
        assert!(parse_args(&["-j", "0", "."]).is_err());
        assert!(parse_args(&["-j", "abc", "."]).is_err());
    }

    #[test]
    fn test_missing_path() {
        assert!(parse_args(&["-m", "qwen"]).is_err());
    }

    #[test]
    fn test_help() {
        assert!(parse_args(&["-h"]).unwrap().show_help);
    }
}
