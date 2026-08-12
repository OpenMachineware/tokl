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
//! tokl — Token and Line Counter.

mod approx;
mod bpe;
mod cli;
mod config;
mod count;
mod format;
mod json;
mod language;
mod proto;
mod scanner;
mod sp;
mod tokenize;
mod toml;
mod util;

use std::path::Path;
use std::process::ExitCode;

use cli::{USAGE, VERSION_INFO};
use count::LangAgg;
use scanner::ScanOptions;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let opts = match cli::parse(&args) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("error: {}", e);
            eprintln!();
            eprintln!("{}", USAGE);
            return ExitCode::from(2);
        }
    };

    if opts.show_help {
        println!("{}", USAGE);
        return ExitCode::SUCCESS;
    }
    if opts.show_version {
        println!("{}", VERSION_INFO);
        return ExitCode::SUCCESS;
    }
    if opts.init_config {
        return init_config();
    }

    // Load config (CLI flags take precedence)
    let cfg = config::load();
    if opts.verbose {
        if let Some(p) = config::config_path() {
            eprintln!("[verbose] config file: {}", p.display());
        } else {
            eprintln!(
                "[verbose] no config file found (use --init to create one)"
            );
        }
    }

    // Merge defaults with CLI arguments
    let model_name = opts
        .model
        .clone()
        .or(cfg.default_model.clone())
        .unwrap_or_else(|| "deepseek-v3".to_string());
    let model = match tokenize::resolve_model(&model_name) {
        Some(m) => m,
        None => {
            eprintln!(
                "error: unknown model '{}' (use -h to list supported models)",
                model_name
            );
            return ExitCode::from(2);
        }
    };

    let format_name = opts
        .format
        .clone()
        .or(cfg.default_format.clone())
        .unwrap_or_else(|| "table".to_string());
    let format = match format::Format::from_str(&format_name) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("error: {}", e);
            return ExitCode::from(2);
        }
    };

    // Merge -i with ignore_dirs / ignore_langs from config
    let mut ignore_dirs = cfg.default_ignore_dirs.clone();
    ignore_dirs.extend(opts.ignore.iter().cloned());
    let mut ignore_langs = cfg.default_ignore_langs.clone();
    ignore_langs.extend(opts.ignore.iter().cloned());

    // Merge -e with default_exts from config
    let mut exts = cfg.default_exts.clone();
    exts.extend(opts.exts.iter().cloned());
    // Deduplicate (order-insensitive)
    let exts: Vec<String> = {
        let mut seen = std::collections::HashSet::new();
        exts.into_iter()
            .filter(|e| seen.insert(e.to_ascii_lowercase()))
            .collect()
    };

    let scan_opts = ScanOptions { ignore_dirs, ignore_langs, only_exts: exts };

    // Build the tokenizer
    let tokenizer_dir = cfg.tokenizer_dir.as_deref().map(Path::new);
    let (tokenizer, loaded_from) = tokenize::build(model, tokenizer_dir);
    if opts.verbose {
        match &loaded_from {
            Some(src) => eprintln!(
                "[verbose] model {}: using exact tokenizer ({})",
                model.name, src
            ),
            None => eprintln!(
                "[verbose] model {}: no local vocab found, using approximate \
                 tokenizer (set tokenizer_dir in config)",
                model.name
            ),
        }
    }

    // Scan
    let registry = scanner::Registry::new();
    let files = scanner::scan(&opts.paths, &scan_opts, &registry);
    if files.is_empty() {
        eprintln!("info: no countable files found");
        return ExitCode::SUCCESS;
    }

    // Count file by file
    let mut file_counts = Vec::with_capacity(files.len());
    let mut binary_skipped = 0u64;
    for f in &files {
        let Ok(data) = std::fs::read(&f.path) else {
            continue;
        };
        if util::looks_binary(&data) {
            binary_skipped += 1;
            if opts.verbose {
                eprintln!(
                    "[verbose] skipped binary file: {}",
                    f.path.display()
                );
            }
            continue;
        }
        let tokens = tokenizer.count(&data);
        let fc = count::count_file(&data, &f.syntax, tokens);
        file_counts.push((f.lang_name.clone(), fc));
    }

    if opts.verbose {
        eprintln!(
            "[verbose] counted {} files (skipped {} binary files)",
            file_counts.len(),
            binary_skipped
        );
    }

    // Aggregate
    let rows = count::aggregate(file_counts);
    let mut total = LangAgg::default();
    for (_, a) in &rows {
        total.add(a);
    }

    // Output
    print!("{}", format::render(&rows, &total, format, model.name));
    ExitCode::SUCCESS
}

/// --init: generate a default config file.
fn init_config() -> ExitCode {
    let Some(dir) = config::config_dir() else {
        eprintln!("error: cannot determine config directory");
        return ExitCode::from(1);
    };
    let path = dir.join("user_config.toml");
    if path.exists() {
        eprintln!("config file already exists: {}", path.display());
        return ExitCode::from(1);
    }
    if let Err(e) = std::fs::create_dir_all(&dir) {
        eprintln!("error: cannot create directory {}: {}", dir.display(), e);
        return ExitCode::from(1);
    }
    if let Err(e) = std::fs::write(&path, config::DEFAULT_CONFIG_TEMPLATE) {
        eprintln!("error: cannot write {}: {}", path.display(), e);
        return ExitCode::from(1);
    }
    println!("generated config file: {}", path.display());
    ExitCode::SUCCESS
}
