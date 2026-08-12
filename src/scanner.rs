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
//! File scanning: recursively walk directories, filter by language table /
//! extension, and return the list of files to count.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::thread;

use crate::language::{LangSpec, LANGUAGES};
use crate::util::{extension_of, file_name_of};

/// Scan options.
#[derive(Debug, Clone, Default)]
pub struct ScanOptions {
    /// Directory names to ignore (exact basename match; -i merged with config)
    pub ignore_dirs: Vec<String>,
    /// Language names/aliases/extensions to ignore (-i merged with config)
    pub ignore_langs: Vec<String>,
    /// Extensions to count only (-e merged with config; empty counts all)
    pub only_exts: Vec<String>,
}

/// A file to be counted.
#[derive(Debug, Clone)]
pub struct ScannedFile {
    pub path: PathBuf,
    /// Language name (uppercased extension when unknown but allowed by -e)
    pub lang_name: String,
    /// Language syntax (generic syntax for unknown languages)
    pub syntax: LangSpec,
}

/// Language registry: extension / filename -> language index.
pub struct Registry {
    /// Extension -> language index (first match wins, highest priority)
    ext_map: HashMap<String, usize>,
    /// Exact filename -> language index
    filename_map: HashMap<String, usize>,
}

/// Generic syntax for unknown languages: no comments, plain strings only.
pub const GENERIC_SYNTAX: LangSpec = LangSpec {
    name: "Other",
    aliases: &[],
    exts: &[],
    filenames: &[],
    line_comments: &[],
    line_comments_bol: &[],
    block_comments: &[],
    nestable: false,
    strings: &[
        crate::language::StringSpec {
            start: "\"",
            end: "\"",
            multiline: false,
            escape: Some('\\'),
        },
        crate::language::StringSpec {
            start: "'",
            end: "'",
            multiline: false,
            escape: Some('\\'),
        },
    ],
    raw: crate::language::RawKind::None,
};

impl Registry {
    pub fn new() -> Registry {
        let mut ext_map = HashMap::new();
        let mut filename_map = HashMap::new();
        for (idx, lang) in LANGUAGES.iter().enumerate() {
            for &ext in lang.exts {
                ext_map.entry(ext.to_ascii_lowercase()).or_insert(idx);
            }
            for &f in lang.filenames {
                filename_map.entry(f.to_ascii_lowercase()).or_insert(idx);
            }
        }
        Registry { ext_map, filename_map }
    }

    /// Match a language index for a path (filename first, then extension).
    fn match_lang(&self, path: &Path) -> Option<usize> {
        let name = file_name_of(path);
        let lower = name.to_ascii_lowercase();
        if let Some(&idx) = self.filename_map.get(&lower) {
            return Some(idx);
        }
        if let Some(ext) = extension_of(path) {
            if let Some(&idx) = self.ext_map.get(&ext) {
                return Some(idx);
            }
        }
        None
    }

    /// Whether a language matches ignore_langs (by name/alias or extension).
    fn lang_ignored(
        &self,
        lang_idx: Option<usize>,
        ext: Option<&str>,
        ignores: &[String],
    ) -> bool {
        if ignores.is_empty() {
            return false;
        }
        let ignore_set: HashSet<&str> =
            ignores.iter().map(|s| s.as_str()).collect();
        if let Some(idx) = lang_idx {
            let lang = &LANGUAGES[idx];
            if ignore_set.contains(lang.name) {
                return true;
            }
            for a in lang.aliases {
                if ignore_set.contains(a) {
                    return true;
                }
            }
            for e in lang.exts {
                if ignore_set.contains(e) {
                    return true;
                }
            }
        }
        if let Some(ext) = ext {
            if ignore_set.contains(ext) {
                return true;
            }
        }
        false
    }
}

/// Recursively scan and return a sorted list of files.
pub fn scan(
    roots: &[String],
    opts: &ScanOptions,
    registry: &Registry,
) -> Vec<ScannedFile> {
    let ignore_dirs: HashSet<String> =
        opts.ignore_dirs.iter().map(|s| s.to_ascii_lowercase()).collect();
    // Empty only_exts means no filtering
    let only_exts: HashSet<String> =
        opts.only_exts.iter().map(|s| s.to_ascii_lowercase()).collect();
    let only = !only_exts.is_empty();

    let files: Mutex<Vec<ScannedFile>> = Mutex::new(Vec::new());
    // Directories still to visit: (canonical path, display path)
    let dirs: Mutex<VecDeque<(PathBuf, PathBuf)>> = Mutex::new(VecDeque::new());
    // Track visited canonical paths to prevent symlink loops
    let visited: Mutex<HashSet<PathBuf>> = Mutex::new(HashSet::new());

    for root in roots {
        let root = Path::new(root);
        let root_canon =
            root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
        if !visited.lock().unwrap().insert(root_canon.clone()) {
            continue;
        }
        if root.is_file() {
            let mut f = files.lock().unwrap();
            push_file(
                root,
                &mut f,
                opts,
                registry,
                &ignore_dirs,
                &only_exts,
                only,
            );
        } else if root.is_dir() {
            dirs.lock().unwrap().push_back((root_canon, root.to_path_buf()));
        }
    }

    // Walk directories in parallel: each thread drains the shared queue.
    let n_threads =
        thread::available_parallelism().map(|n| n.get()).unwrap_or(2).max(1);
    thread::scope(|s| {
        for _ in 0..n_threads {
            let files = &files;
            let dirs = &dirs;
            let visited = &visited;
            // Re-bind Copy references so the `move` closure captures
            // references instead of the owned sets.
            let ignore_dirs = &ignore_dirs;
            let only_exts = &only_exts;
            let opts = opts;
            let registry = registry;
            s.spawn(move || loop {
                let (_canon, disp) = match dirs.lock().unwrap().pop_front() {
                    Some(d) => d,
                    None => return,
                };
                let Ok(entries) = std::fs::read_dir(&disp) else {
                    continue;
                };
                let mut subdirs = Vec::new();
                for entry in entries.flatten() {
                    let path = entry.path();
                    let ftype = match entry.file_type() {
                        Ok(t) => t,
                        Err(_) => continue,
                    };
                    if ftype.is_dir() {
                        let name =
                            entry.file_name().to_string_lossy().into_owned();
                        if ignore_dirs.contains(&name.to_ascii_lowercase()) {
                            continue;
                        }
                        let canon = path
                            .canonicalize()
                            .unwrap_or_else(|_| path.clone());
                        if visited.lock().unwrap().insert(canon.clone()) {
                            subdirs.push((canon, path));
                        }
                    } else if ftype.is_file() || ftype.is_symlink() {
                        let mut f = files.lock().unwrap();
                        push_file(
                            &path,
                            &mut f,
                            opts,
                            registry,
                            &ignore_dirs,
                            &only_exts,
                            only,
                        );
                    }
                }
                // Process subdirectories later (LIFO keeps the old DFS order)
                let mut d = dirs.lock().unwrap();
                for sd in subdirs.into_iter().rev() {
                    d.push_front(sd);
                }
            });
        }
    });

    let mut files = files.into_inner().unwrap();
    files.sort_by(|a, b| a.path.cmp(&b.path));
    files
}

#[allow(clippy::too_many_arguments)]
fn push_file(
    path: &Path,
    files: &mut Vec<ScannedFile>,
    opts: &ScanOptions,
    registry: &Registry,
    ignore_dirs: &HashSet<String>,
    only_exts: &HashSet<String>,
    only: bool,
) {
    let name = file_name_of(path);
    if ignore_dirs.contains(&name.to_ascii_lowercase()) {
        return;
    }
    let lang_idx = registry.match_lang(path);
    let ext = extension_of(path);

    let ext_allowed = if only {
        // With -e: extensions must match; extensionless files
        // (e.g. Dockerfile) fall back to the language table
        match &ext {
            Some(e) => only_exts.contains(e),
            None => match lang_idx {
                Some(i) => {
                    LANGUAGES[i].exts.iter().any(|x| only_exts.contains(*x))
                }
                None => false,
            },
        }
    } else {
        // Default mode: only count known languages
        lang_idx.is_some()
    };
    if !ext_allowed {
        return;
    }
    if registry.lang_ignored(lang_idx, ext.as_deref(), &opts.ignore_langs) {
        return;
    }

    let (lang_name, syntax) = match lang_idx {
        Some(i) => {
            let lang = &LANGUAGES[i];
            (lang.name.to_string(), *lang)
        }
        None => {
            // Unknown language (reached only when allowed by -e)
            let display = ext
                .map(|e| e.to_uppercase())
                .unwrap_or_else(|| "Other".to_string());
            (display, GENERIC_SYNTAX)
        }
    };
    files.push(ScannedFile { path: path.to_path_buf(), lang_name, syntax });
}
