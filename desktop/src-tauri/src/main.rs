//! AI Goodbye Desktop Application
//!
//! This is the main entry point for the Tauri desktop wrapper.
//! It manages the Python backend process and provides the native desktop experience.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::process::{Child, Command};
use std::sync::Mutex;
use tauri::{Manager, State};

/// State to manage the backend process
struct BackendProcess(Mutex<Option<Child>>);

/// Start the Python backend server
#[tauri::command]
async fn start_backend(state: State<'_, BackendProcess>) -> Result<String, String> {
    let mut process_guard = state.0.lock().map_err(|e| e.to_string())?;

    if process_guard.is_some() {
        return Ok("Backend already running".to_string());
    }

    // Get the path to the bundled Python backend
    let backend_path = get_backend_path();

    let child = Command::new(&backend_path)
        .args(["serve", "--host", "127.0.0.1", "--port", "8765"])
        .spawn()
        .map_err(|e| format!("Failed to start backend: {}", e))?;

    *process_guard = Some(child);

    // Wait a moment for the server to start
    std::thread::sleep(std::time::Duration::from_secs(2));

    Ok("Backend started successfully".to_string())
}

/// Stop the Python backend server
#[tauri::command]
async fn stop_backend(state: State<'_, BackendProcess>) -> Result<String, String> {
    let mut process_guard = state.0.lock().map_err(|e| e.to_string())?;

    if let Some(mut child) = process_guard.take() {
        child.kill().map_err(|e| format!("Failed to stop backend: {}", e))?;
        Ok("Backend stopped".to_string())
    } else {
        Ok("Backend was not running".to_string())
    }
}

/// Check if the backend is running
#[tauri::command]
async fn check_backend_status() -> Result<bool, String> {
    // Try to connect to the backend
    match reqwest::get("http://127.0.0.1:8765/api/status").await {
        Ok(response) => Ok(response.status().is_success()),
        Err(_) => Ok(false),
    }
}

/// Get the backend API URL
#[tauri::command]
fn get_backend_url() -> String {
    "http://127.0.0.1:8765".to_string()
}

/// Get the path to the backend executable
fn get_backend_path() -> String {
    #[cfg(target_os = "windows")]
    let binary_name = "aigoodbye-backend.exe";

    #[cfg(not(target_os = "windows"))]
    let binary_name = "aigoodbye-backend";

    // In development, use the local Python installation
    if cfg!(debug_assertions) {
        return "python".to_string();
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

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(BackendProcess(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            start_backend,
            stop_backend,
            check_backend_status,
            get_backend_url
        ])
        .setup(|app| {
            // Start the backend when the app launches
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let state: State<BackendProcess> = handle.state();
                let _ = start_backend(state).await;
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                // Stop the backend when the window closes
                let handle = window.app_handle();
                let state: State<BackendProcess> = handle.state();
                let _ = tauri::async_runtime::block_on(stop_backend(state));
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
