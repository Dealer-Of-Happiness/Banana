//! AI Goodbye Desktop Application
//!
//! This is the main entry point for the Tauri desktop wrapper.
//! It manages the embedded Ollama process and provides the native desktop experience.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use tauri::{Manager, State};

/// State to manage the Ollama process
struct OllamaProcess(Mutex<Option<Child>>);

/// Get the path to the Ollama executable
fn get_ollama_path() -> String {
    #[cfg(target_os = "windows")]
    let binary_name = "ollama.exe";

    #[cfg(not(target_os = "windows"))]
    let binary_name = "ollama";

    // In development, try to use system Ollama
    if cfg!(debug_assertions) {
        return "ollama".to_string();
    }

    // In production, use the bundled binary
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
        .unwrap_or_default();

    #[cfg(target_os = "macos")]
    let binary_path = exe_dir.join("../Resources/binaries").join(binary_name);

    #[cfg(target_os = "windows")]
    let binary_path = exe_dir.join("binaries").join(binary_name);

    #[cfg(target_os = "linux")]
    let binary_path = exe_dir.join("binaries").join(binary_name);

    binary_path.to_string_lossy().to_string()
}

/// Start the Ollama server
fn start_ollama_server(state: &State<'_, OllamaProcess>) -> Result<(), String> {
    let mut process_guard = state.0.lock().map_err(|e| e.to_string())?;

    if process_guard.is_some() {
        return Ok(()); // Already running
    }

    let ollama_path = get_ollama_path();

    // Set OLLAMA_HOST to ensure it binds to localhost
    let child = Command::new(&ollama_path)
        .arg("serve")
        .env("OLLAMA_HOST", "127.0.0.1:11434")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("Failed to start Ollama: {}", e))?;

    *process_guard = Some(child);

    Ok(())
}

/// Stop the Ollama server
fn stop_ollama_server(state: &State<'_, OllamaProcess>) -> Result<(), String> {
    let mut process_guard = state.0.lock().map_err(|e| e.to_string())?;

    if let Some(mut child) = process_guard.take() {
        let _ = child.kill();
        let _ = child.wait();
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
