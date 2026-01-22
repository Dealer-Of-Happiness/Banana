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

    // Build the base sidecar command
    let mut sidecar_command = app
        .shell()
        .sidecar("ollama")
        .map_err(|e| format!("Failed to create sidecar command: {}", e))?
        .args(["serve"])
        .env("OLLAMA_HOST", "127.0.0.1:11434");

    // On Windows, we need to tell Ollama where to find its runtime libraries
    // macOS Ollama binary is self-contained and doesn't need this
    #[cfg(target_os = "windows")]
    {
        let resource_dir = app
            .path()
            .resource_dir()
            .map_err(|e| format!("Failed to get resource dir: {}", e))?;

        let app_data_dir = app
            .path()
            .app_local_data_dir()
            .map_err(|e| format!("Failed to get app data dir: {}", e))?;

        // Bundled CPU libraries (included in installer) - new structure: lib/ollama/*.dll
        let bundled_lib = resource_dir.join("binaries").join("lib").join("ollama");

        // Downloaded GPU libraries (fetched on demand by the app)
        let gpu_lib = app_data_dir.join("gpu-runners");

        eprintln!("Resource dir: {:?}", resource_dir);
        eprintln!("Bundled lib: {:?}", bundled_lib);
        eprintln!("GPU lib dir: {:?}", gpu_lib);

        // Build library paths - include both bundled and downloaded libraries
        // Ollama will use whichever libraries are available
        let mut lib_paths = Vec::new();

        if bundled_lib.exists() {
            eprintln!("Bundled libraries found:");
            if let Ok(entries) = std::fs::read_dir(&bundled_lib) {
                for entry in entries.flatten() {
                    eprintln!("  - {:?}", entry.path());
                }
            }
            lib_paths.push(bundled_lib.to_string_lossy().to_string());
        }

        if gpu_lib.exists() {
            eprintln!("GPU libraries found (downloaded):");
            if let Ok(entries) = std::fs::read_dir(&gpu_lib) {
                for entry in entries.flatten() {
                    eprintln!("  - {:?}", entry.path());
                }
            }
            lib_paths.push(gpu_lib.to_string_lossy().to_string());
        }

        if lib_paths.is_empty() {
            eprintln!("WARNING: No library directories found!");
        } else {
            // Join paths with semicolon for Windows
            let lib_dir_str = lib_paths.join(";");
            eprintln!("OLLAMA_LIB_DIR: {}", lib_dir_str);

            // Get current PATH and prepend our library paths
            // This is crucial for Windows DLL loading - the DLLs must be in PATH
            let current_path = std::env::var("PATH").unwrap_or_default();
            let new_path = format!("{};{}", lib_dir_str, current_path);
            eprintln!("Updated PATH with library directories");

            sidecar_command = sidecar_command
                .env("OLLAMA_LIB_DIR", &lib_dir_str)
                .env("PATH", &new_path);
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

/// Get the path where GPU runners should be downloaded (Windows only)
#[tauri::command]
fn get_gpu_runners_path(app: tauri::AppHandle) -> Result<String, String> {
    let app_data_dir = app
        .path()
        .app_local_data_dir()
        .map_err(|e| format!("Failed to get app data dir: {}", e))?;

    let gpu_runners = app_data_dir.join("gpu-runners");
    Ok(gpu_runners.to_string_lossy().to_string())
}

/// Check if GPU libraries are installed
#[tauri::command]
fn check_gpu_runners(app: tauri::AppHandle) -> Result<bool, String> {
    let app_data_dir = app
        .path()
        .app_local_data_dir()
        .map_err(|e| format!("Failed to get app data dir: {}", e))?;

    let gpu_lib = app_data_dir.join("gpu-runners");

    // Check if directory exists and has cuda, rocm, or vulkan subdirectories
    if gpu_lib.exists() {
        if let Ok(entries) = std::fs::read_dir(&gpu_lib) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name_str = name.to_string_lossy();
                if name_str.starts_with("cuda") || name_str.starts_with("rocm") || name_str.starts_with("vulkan") {
                    return Ok(true);
                }
            }
        }
    }
    Ok(false)
}

/// Download and install GPU libraries (Windows only)
#[tauri::command]
async fn download_gpu_runners(app: tauri::AppHandle, download_url: String) -> Result<String, String> {
    use std::io::Write;

    let app_data_dir = app
        .path()
        .app_local_data_dir()
        .map_err(|e| format!("Failed to get app data dir: {}", e))?;

    let gpu_runners_path = app_data_dir.join("gpu-runners");
    let zip_path = app_data_dir.join("gpu-runners.zip");

    eprintln!("Downloading GPU runners from: {}", download_url);
    eprintln!("Target path: {:?}", gpu_runners_path);

    // Create directory if needed
    if !gpu_runners_path.exists() {
        std::fs::create_dir_all(&gpu_runners_path)
            .map_err(|e| format!("Failed to create directory: {}", e))?;
    }

    // Download the file using reqwest
    let response = reqwest::get(&download_url)
        .await
        .map_err(|e| format!("Download failed: {}", e))?;

    if !response.status().is_success() {
        return Err(format!("Download failed with status: {}", response.status()));
    }

    let bytes = response
        .bytes()
        .await
        .map_err(|e| format!("Failed to read response: {}", e))?;

    eprintln!("Downloaded {} bytes", bytes.len());

    // Save to zip file
    let mut file = std::fs::File::create(&zip_path)
        .map_err(|e| format!("Failed to create zip file: {}", e))?;
    file.write_all(&bytes)
        .map_err(|e| format!("Failed to write zip file: {}", e))?;
    drop(file);

    eprintln!("Saved zip file, extracting...");

    // Extract using PowerShell (Windows)
    #[cfg(target_os = "windows")]
    {
        let zip_path_str = zip_path.to_string_lossy();
        let dest_path_str = gpu_runners_path.to_string_lossy();

        let output = std::process::Command::new("powershell")
            .args([
                "-Command",
                &format!(
                    "Expand-Archive -Path '{}' -DestinationPath '{}' -Force",
                    zip_path_str, dest_path_str
                ),
            ])
            .output()
            .map_err(|e| format!("Failed to run PowerShell: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("Extraction failed: {}", stderr));
        }

        // Clean up zip file
        let _ = std::fs::remove_file(&zip_path);

        eprintln!("GPU runners installed successfully");
        Ok("GPU acceleration installed successfully".to_string())
    }

    #[cfg(not(target_os = "windows"))]
    {
        Err("GPU download is only supported on Windows".to_string())
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_fs::init())
        .manage(OllamaProcess(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            check_ollama_status,
            get_ollama_url,
            get_gpu_runners_path,
            check_gpu_runners,
            download_gpu_runners
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
