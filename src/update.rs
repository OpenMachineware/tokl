// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jia Liu

use shipup::{UpdateEvent, UpdaterBuilder};
use std::io::Write;
const MANIFEST_BASE_URL: &str = "https://openmachineware.github.io/tokl/latest";
const PUBLIC_KEY: &str = "Zlg3wdewbxUmc9AoAjl/ZKCJ7vexCT1Bsu1LGLpRQH8=";
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
        .public_key(PUBLIC_KEY)
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
        .public_key(PUBLIC_KEY)
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
