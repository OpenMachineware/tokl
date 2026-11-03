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
mod vcs;

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::{mpsc, Mutex};
use std::thread;

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
        .unwrap_or_else(|| "deepseek-v4".to_string());
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

    // Detect version control (git/svn/hg/...) and load repository ignore
    // rules (.gitignore etc.); they are merged with -i / config ignores.
    let vcs = vcs::VcsContext::detect(&opts.paths);
    if opts.verbose {
        if vcs.kinds.is_empty() {
            eprintln!("[verbose] no version-control repository detected");
        } else {
            for (kind, root) in &vcs.repos {
                eprintln!(
                    "[verbose] vcs: {} repository at {}",
                    kind.name(),
                    root.display()
                );
            }
            if vcs.rule_count > 0 {
                eprintln!(
                    "[verbose] vcs: applying {} ignore rule(s) from repo \
                     ignore files",
                    vcs.rule_count
                );
            }
        }
    }

    let scan_opts = ScanOptions {
        ignore_dirs,
        ignore_langs,
        only_exts: exts,
        vcs: Some(vcs),
    };

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

    // Count files in parallel
    enum WorkResult {
        Counted(String, count::FileCount),
        SkippedBinary(PathBuf),
    }

    let n_threads = opts.jobs.unwrap_or_else(|| {
        let cores =
            thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
        // Fewer files than cores: no point spawning a thread per file
        cores.min(files.len().max(1))
    });
    if opts.verbose {
        eprintln!("[verbose] counting with {} thread(s)", n_threads);
    }

    // Each worker accumulates results locally and ships them in batches,
    // so the channel carries O(threads) messages instead of O(files).
    const BATCH: usize = 256;
    let mut file_counts = Vec::with_capacity(files.len());
    let mut binary_skipped = 0u64;
    {
        let work = Mutex::new(files.iter());
        let (tx, rx) = mpsc::channel::<Vec<WorkResult>>();
        thread::scope(|s| {
            for _ in 0..n_threads {
                let work = &work;
                let tx = tx.clone();
                let tokenizer = &tokenizer;
                s.spawn(move || {
                    let mut batch = Vec::with_capacity(BATCH);
                    // Reuse the read buffer across files so small files do
                    // not cause an allocation each time.
                    let mut data = Vec::new();
                    loop {
                        let Some(f) = work.lock().unwrap().next() else {
                            break;
                        };
                        // Read only the first 8KB for the binary sniff; a
                        // binary file never needs to be fully read.
                        let mut file = match std::fs::File::open(&f.path) {
                            Ok(f) => f,
                            Err(_) => continue,
                        };
                        let mut head = [0u8; 8192];
                        let Ok(n) = file.read(&mut head) else {
                            continue;
                        };
                        if util::looks_binary(&head[..n]) {
                            batch.push(WorkResult::SkippedBinary(
                                f.path.clone(),
                            ));
                            if batch.len() >= BATCH {
                                if tx.send(std::mem::take(&mut batch)).is_err()
                                {
                                    return;
                                }
                            }
                            continue;
                        }
                        data.clear();
                        data.extend_from_slice(&head[..n]);
                        if file.read_to_end(&mut data).is_err() {
                            continue;
                        }
                        let tokens = tokenizer.count(&data);
                        let fc = count::count_file(&data, &f.syntax, tokens);
                        batch
                            .push(WorkResult::Counted(f.lang_name.clone(), fc));
                        if batch.len() >= BATCH {
                            if tx.send(std::mem::take(&mut batch)).is_err() {
                                return;
                            }
                        }
                    }
                    if !batch.is_empty() {
                        let _ = tx.send(batch);
                    }
                });
            }
            drop(tx);
            for batch in rx {
                for r in batch {
                    match r {
                        WorkResult::Counted(lang, fc) => {
                            file_counts.push((lang, fc));
                        }
                        WorkResult::SkippedBinary(p) => {
                            binary_skipped += 1;
                            if opts.verbose {
                                eprintln!(
                                    "[verbose] skipped binary file: {}",
                                    p.display()
                                );
                            }
                        }
                    }
                }
            }
        });
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
    let Some(path) = config::config_file_path() else {
        eprintln!("error: cannot determine config directory");
        return ExitCode::from(1);
    };
    if path.exists() {
        eprintln!("config file already exists: {}", path.display());
        return ExitCode::from(1);
    }
    if let Err(e) = config::write_default_config(&path) {
        eprintln!("error: cannot write {}: {}", path.display(), e);
        return ExitCode::from(1);
    }
    println!("generated config file: {}", path.display());
    ExitCode::SUCCESS
}
