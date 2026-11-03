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

use shipup::{UpdateEvent, UpdaterBuilder};
use std::io::Write;

const MANIFEST_BASE_URL: &str = "https://openmachineware.github.io/tokl/latest";

pub fn current_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

fn manifest_url() -> String {
    let target = shipup::current_target_triple();
    match target {
        "x86_64-unknown-linux-gnu" => {
            format!("{}/linux.json", MANIFEST_BASE_URL)
        }
        "aarch64-apple-darwin" => format!("{}/macos.json", MANIFEST_BASE_URL),
        "x86_64-pc-windows-msvc" => {
            format!("{}/windows.json", MANIFEST_BASE_URL)
        }
        _ => format!("{}-{}.json", MANIFEST_BASE_URL, target),
    }
}

pub fn check_update() -> shipup::Result<Option<String>> {
    let url = manifest_url();
    let updater = UpdaterBuilder::new()
        .current_version(current_version())?
        .endpoint(&url)
        .build()?;

    let update = updater.check()?;

    if let Some(update) = update {
        Ok(Some(format!(
            "Update available: {} → {}",
            current_version(),
            update.version()
        )))
    } else {
        Ok(None)
    }
}

pub fn self_update() -> shipup::Result<()> {
    let url = manifest_url();
    let updater = UpdaterBuilder::new()
        .current_version(current_version())?
        .endpoint(&url)
        .build()?;

    println!("Checking for updates...");
    let update = updater.check()?;

    if let Some(update_info) = update {
        println!("Updating to version {}...", update_info.version());

        // Download with progress callback
        let downloaded = update_info.download(|event| {
            if let UpdateEvent::DownloadProgress {
                downloaded_bytes,
                total_bytes,
                ..
            } = event
            {
                if let Some(total) = total_bytes {
                    let percent = ((downloaded_bytes as f64 / total as f64)
                        * 100.0) as u8;
                    print!("\rDownloading: {}%", percent);
                    std::io::stdout().flush().ok();
                }
            }
        })?;
        println!("\rDownloading: 100%");

        // Install
        println!("Installing...");
        downloaded.install(|_| {})?;

        println!("Successfully updated to {}!", update_info.version());
        println!("Restart tokl to use the new version.");
    } else {
        println!("Already up to date (version {})", current_version());
    }

    Ok(())
}
