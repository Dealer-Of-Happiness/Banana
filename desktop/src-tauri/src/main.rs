//! AI Goodbye Desktop Application
//!
//! This is the main entry point for the Tauri desktop wrapper.
//! It manages the embedded Ollama process and provides the native desktop experience.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Mutex;
use tauri::{Manager, State};
use tauri_plugin_shell::ShellExt;
use tauri_plugin_shell::process::{CommandChild, CommandEvent};

/// State to manage the Ollama process
struct OllamaProcess(Mutex<Option<CommandChild>>);

/// Start the Ollama server using Tauri's sidecar API
fn start_ollama_server(app: &tauri::App) -> Result<CommandChild, String> {
    eprintln!("=== Starting Ollama via Tauri Sidecar ===");

    // Build the sidecar command
    let mut sidecar_command = app
        .shell()
        .sidecar("ollama")
        .map_err(|e| format!("Failed to create sidecar command: {}", e))?
        .args(["serve"])
        .env("OLLAMA_HOST", "127.0.0.1:11434");

    // On Windows, we need to add the lib folder to PATH for DLL dependencies
    #[cfg(target_os = "windows")]
    {
        eprintln!("Windows detected - setting up library path...");

        // Get the resource directory where lib folder is bundled
        if let Ok(resource_dir) = app.path().resource_dir() {
            let lib_path = resource_dir.join("lib").join("ollama");
            eprintln!("Library path: {:?}", lib_path);

            if lib_path.exists() {
                // Get current PATH and prepend the lib path
                let current_path = std::env::var("PATH").unwrap_or_default();
                let new_path = format!("{};{}", lib_path.display(), current_path);
                eprintln!("Setting PATH to include: {}", lib_path.display());
                sidecar_command = sidecar_command.env("PATH", new_path);
            } else {
                eprintln!("Warning: lib/ollama folder not found at {:?}", lib_path);
                // Try alternative locations
                let app_dir = app.path().app_local_data_dir().ok();
                eprintln!("App local data dir: {:?}", app_dir);
            }
        } else {
            eprintln!("Warning: Could not get resource directory");
        }
    }

    eprintln!("Spawning Ollama sidecar...");

    let (mut rx, child) = sidecar_command
        .spawn()
        .map_err(|e| format!("Failed to spawn Ollama sidecar: {}", e))?;

    eprintln!("Ollama sidecar spawned with PID: {:?}", child.pid());

    // Spawn a task to log Ollama output for debugging
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(line) => {
                    eprintln!("[Ollama stdout] {}", String::from_utf8_lossy(&line));
                }
                CommandEvent::Stderr(line) => {
                    eprintln!("[Ollama stderr] {}", String::from_utf8_lossy(&line));
                }
                CommandEvent::Error(err) => {
                    eprintln!("[Ollama error] {}", err);
                }
                CommandEvent::Terminated(payload) => {
                    eprintln!("[Ollama terminated] code: {:?}, signal: {:?}", payload.code, payload.signal);
                    break;
                }
                _ => {}
            }
        }
    });

    Ok(child)
}

/// Stop the Ollama server
fn stop_ollama_server(state: &State<'_, OllamaProcess>) {
    let mut process_guard = state.0.lock().unwrap();

    if let Some(child) = process_guard.take() {
        eprintln!("Stopping Ollama server (PID: {:?})...", child.pid());
        let _ = child.kill();
        eprintln!("Ollama server stopped");
    }
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
            eprintln!("=== AIGoodbye App Setup ===");

            // Log paths for debugging
            if let Ok(resource_dir) = app.path().resource_dir() {
                eprintln!("Resource dir: {:?}", resource_dir);
            }
            if let Ok(app_dir) = app.path().app_local_data_dir() {
                eprintln!("App local data dir: {:?}", app_dir);
            }

            // Start Ollama when the app launches
            match start_ollama_server(app) {
                Ok(child) => {
                    eprintln!("Ollama started successfully");
                    let state: State<OllamaProcess> = app.state();
                    *state.0.lock().unwrap() = Some(child);
                }
                Err(e) => {
                    eprintln!("Warning: Could not start Ollama: {}", e);
                }
            }

            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                // Stop Ollama when the window closes
                let handle = window.app_handle();
                let state: State<OllamaProcess> = handle.state();
                stop_ollama_server(&state);
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
