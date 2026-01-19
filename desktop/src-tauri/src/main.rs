//! AI Goodbye Desktop Application
//!
//! This is the main entry point for the Tauri desktop wrapper.
//! It manages the embedded Ollama process and provides the native desktop experience.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use tauri::{Manager, State};

/// State to manage the Ollama process
struct OllamaProcess(Mutex<Option<Child>>);

/// Get the path to the Ollama executable and its directory
fn get_ollama_paths() -> (PathBuf, PathBuf) {
    // In development, try to use system Ollama
    if cfg!(debug_assertions) {
        return (PathBuf::from("ollama"), PathBuf::from("."));
    }

    // Get the target triple for the current platform
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    let binary_name = "ollama-aarch64-apple-darwin";

    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    let binary_name = "ollama-x86_64-apple-darwin";

    #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
    let binary_name = "ollama-x86_64-pc-windows-msvc.exe";

    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    let binary_name = "ollama-x86_64-unknown-linux-gnu";

    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    let binary_name = "ollama-aarch64-unknown-linux-gnu";

    // In production, use the bundled binary
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
        .unwrap_or_default();

    #[cfg(target_os = "macos")]
    let binaries_dir = exe_dir.join("../Resources/binaries");

    #[cfg(target_os = "windows")]
    let binaries_dir = exe_dir.join("binaries");

    #[cfg(target_os = "linux")]
    let binaries_dir = exe_dir.join("binaries");

    let binary_path = binaries_dir.join(binary_name);

    (binary_path, binaries_dir)
}

/// Prepare the Ollama binary for execution (macOS specific)
#[cfg(target_os = "macos")]
fn prepare_binary(binary_path: &PathBuf) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;

    // Ensure the binary is executable
    if let Ok(metadata) = std::fs::metadata(binary_path) {
        let mut perms = metadata.permissions();
        perms.set_mode(0o755);
        let _ = std::fs::set_permissions(binary_path, perms);
    }

    // Remove quarantine attribute on macOS (downloaded files are quarantined)
    let _ = Command::new("xattr")
        .args(["-d", "com.apple.quarantine"])
        .arg(binary_path)
        .output();

    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn prepare_binary(_binary_path: &PathBuf) -> Result<(), String> {
    Ok(())
}

/// Start the Ollama server
fn start_ollama_server(state: &State<'_, OllamaProcess>) -> Result<(), String> {
    let mut process_guard = state.0.lock().map_err(|e| e.to_string())?;

    if process_guard.is_some() {
        return Ok(()); // Already running
    }

    let (ollama_path, binaries_dir) = get_ollama_paths();

    // Log the path we're trying to use
    eprintln!("=== Ollama Startup ===");
    eprintln!("Binary path: {:?}", ollama_path);
    eprintln!("Binaries dir: {:?}", binaries_dir);
    eprintln!("Binary exists: {}", ollama_path.exists());
    eprintln!("Dir exists: {}", binaries_dir.exists());

    // List binaries directory contents for debugging
    if let Ok(entries) = std::fs::read_dir(&binaries_dir) {
        eprintln!("Binaries directory contents:");
        for entry in entries.flatten() {
            eprintln!("  - {:?}", entry.file_name());
        }
    }

    if !ollama_path.exists() && !cfg!(debug_assertions) {
        return Err(format!("Ollama binary not found at: {:?}", ollama_path));
    }

    // Prepare binary (set permissions, remove quarantine on macOS)
    prepare_binary(&ollama_path)?;

    // Set HOME directory for Ollama to store models
    let home_dir = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));

    eprintln!("Starting Ollama server...");
    eprintln!("Working directory: {:?}", binaries_dir);
    eprintln!("HOME: {:?}", home_dir);

    // Start Ollama with current_dir set (like electron-ollama does)
    let child = Command::new(&ollama_path)
        .arg("serve")
        .current_dir(&binaries_dir)
        .env("OLLAMA_HOST", "127.0.0.1:11434")
        .env("HOME", &home_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to start Ollama at {:?}: {}", ollama_path, e))?;

    eprintln!("Ollama process spawned with PID: {:?}", child.id());
    *process_guard = Some(child);

    Ok(())
}

/// Stop the Ollama server
fn stop_ollama_server(state: &State<'_, OllamaProcess>) -> Result<(), String> {
    let mut process_guard = state.0.lock().map_err(|e| e.to_string())?;

    if let Some(mut child) = process_guard.take() {
        eprintln!("Stopping Ollama server...");
        let _ = child.kill();
        let _ = child.wait();
        eprintln!("Ollama server stopped");
    }

    Ok(())
}

/// Check if Ollama is ready
#[tauri::command]
async fn check_ollama_status() -> Result<bool, String> {
    match reqwest::get("http://127.0.0.1:11434/api/tags").await {
        Ok(response) => Ok(response.status().is_success()),
        Err(_) => Ok(false),
    }
}

/// Get the Ollama API URL
#[tauri::command]
fn get_ollama_url() -> String {
    "http://127.0.0.1:11434".to_string()
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(OllamaProcess(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            check_ollama_status,
            get_ollama_url
        ])
        .setup(|app| {
            // Start Ollama when the app launches
            let state: State<OllamaProcess> = app.state();
            if let Err(e) = start_ollama_server(&state) {
                eprintln!("Warning: Could not start Ollama: {}", e);
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                // Stop Ollama when the window closes
                let handle = window.app_handle();
                let state: State<OllamaProcess> = handle.state();
                let _ = stop_ollama_server(&state);
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
