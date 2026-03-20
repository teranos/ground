#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use rusqlite::Connection;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

fn db_path() -> PathBuf {
    dirs_next().join("graunde.db")
}

fn dirs_next() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home)
        .join(".local")
        .join("share")
        .join("graunde")
}

fn controls_dir() -> PathBuf {
    // Walk up from the executable to find the graunde project root,
    // or use a known path. For now, use the compile-time project root.
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    dir.pop(); // tower/src-tauri -> tower
    dir.pop(); // tower -> graunde
    dir.join("controls")
}

#[derive(Serialize)]
struct ControlFile {
    name: String,
    content: String,
}

#[tauri::command]
fn read_controls() -> Vec<ControlFile> {
    let dir = controls_dir();
    let mut files = Vec::new();

    let entries = match fs::read_dir(&dir) {
        Ok(e) => e,
        Err(_) => return files,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "pbt") {
            if let Ok(content) = fs::read_to_string(&path) {
                let name = path
                    .file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string();
                files.push(ControlFile { name, content });
            }
        }
    }

    // Stable order: controls first, then alphabetical
    files.sort_by(|a, b| {
        if a.name == "controls" {
            std::cmp::Ordering::Less
        } else if b.name == "controls" {
            std::cmp::Ordering::Greater
        } else {
            a.name.cmp(&b.name)
        }
    });

    files
}

#[derive(Serialize, Clone)]
struct FireInfo {
    count: u32,
    last_fired: Option<String>,
    buckets: Vec<u32>,
}

const BUCKET_COUNT: usize = 7;

#[tauri::command]
fn read_fires() -> HashMap<String, FireInfo> {
    let mut result = HashMap::new();
    let db = db_path();

    let conn = match Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY) {
        Ok(c) => c,
        Err(_) => return result,
    };

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let day_ms: i64 = 86_400_000;

    let mut stmt = match conn.prepare(
        "SELECT attributes, timestamp FROM attestations WHERE predicates LIKE '%Graunded%' ORDER BY timestamp DESC",
    ) {
        Ok(s) => s,
        Err(_) => return result,
    };

    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
        ))
    });

    let rows = match rows {
        Ok(r) => r,
        Err(_) => return result,
    };

    for row in rows.flatten() {
        let (attrs_str, timestamp) = row;

        let name = match serde_json::from_str::<serde_json::Value>(&attrs_str) {
            Ok(v) => match v.get("control").and_then(|c| c.as_str()) {
                Some(n) => n.to_string(),
                None => continue,
            },
            Err(_) => continue,
        };

        let entry = result.entry(name).or_insert_with(|| FireInfo {
            count: 0,
            last_fired: None,
            buckets: vec![0; BUCKET_COUNT],
        });

        entry.count += 1;
        if entry.last_fired.is_none() {
            entry.last_fired = Some(timestamp.clone());
        }

        // Parse timestamp and bucket by day
        if let Ok(ts) = chrono_parse_ms(&timestamp) {
            let days_ago = ((now - ts) / day_ms) as usize;
            if days_ago < BUCKET_COUNT {
                let idx = BUCKET_COUNT - 1 - days_ago;
                entry.buckets[idx] += 1;
            }
        }
    }

    result
}

/// Parse ISO timestamp to epoch millis (minimal, no chrono dependency)
fn chrono_parse_ms(ts: &str) -> Result<i64, ()> {
    // Try parsing as epoch millis first
    if let Ok(ms) = ts.parse::<i64>() {
        return Ok(ms);
    }

    // Try ISO 8601: "2026-03-20T01:23:45.678Z" or similar
    // Rough parse — good enough for bucketing
    let ts = ts.trim().trim_end_matches('Z');
    let parts: Vec<&str> = ts.splitn(2, 'T').collect();
    if parts.len() != 2 {
        return Err(());
    }

    let date_parts: Vec<&str> = parts[0].split('-').collect();
    let time_parts: Vec<&str> = parts[1].split(':').collect();

    if date_parts.len() != 3 || time_parts.len() < 2 {
        return Err(());
    }

    let year: i64 = date_parts[0].parse().map_err(|_| ())?;
    let month: i64 = date_parts[1].parse().map_err(|_| ())?;
    let day: i64 = date_parts[2].parse().map_err(|_| ())?;
    let hour: i64 = time_parts[0].parse().map_err(|_| ())?;
    let min: i64 = time_parts[1].parse().map_err(|_| ())?;

    // Rough epoch calculation (not accounting for leap seconds etc, fine for day bucketing)
    let days_since_epoch = (year - 1970) * 365 + (year - 1969) / 4 - (year - 1901) / 100
        + (year - 1601) / 400
        + month_days(month)
        + day
        - 1;
    let ms = (days_since_epoch * 86400 + hour * 3600 + min * 60) * 1000;
    Ok(ms)
}

fn month_days(month: i64) -> i64 {
    const DAYS: [i64; 12] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
    if month >= 1 && month <= 12 {
        DAYS[(month - 1) as usize]
    } else {
        0
    }
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![read_controls, read_fires])
        .run(tauri::generate_context!())
        .expect("error running graunde");
}
