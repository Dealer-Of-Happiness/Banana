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

        // Get the executable's directory - DLLs might be relative to this
        let exe_dir = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|p| p.to_path_buf()));

        eprintln!("Resource dir: {:?}", resource_dir);
        eprintln!("App data dir: {:?}", app_data_dir);
        eprintln!("Exe dir: {:?}", exe_dir);

        // Debug: List contents of resource directory to find where DLLs actually are
        eprintln!("Resource directory contents:");
        if let Ok(entries) = std::fs::read_dir(&resource_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                eprintln!("  {:?} (is_dir: {})", path, path.is_dir());
                // If it's a directory, list its contents recursively (2 levels)
                if path.is_dir() {
                    if let Ok(sub_entries) = std::fs::read_dir(&path) {
                        for sub_entry in sub_entries.flatten() {
                            let sub_path = sub_entry.path();
                            eprintln!("    {:?}", sub_path);
                            if sub_path.is_dir() {
                                if let Ok(sub_sub_entries) = std::fs::read_dir(&sub_path) {
                                    for sub_sub_entry in sub_sub_entries.flatten() {
                                        eprintln!("      {:?}", sub_sub_entry.path());
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Try multiple possible paths for bundled libraries
        // Resources are bundled as lib/ollama/*.dll and placed in resource_dir
        let mut possible_lib_paths = vec![
            // Primary location - resources bundled from src-tauri/lib/
            resource_dir.join("lib").join("ollama"),
            // Fallback locations
            resource_dir.join("ollama"),
        ];

        // Also check relative to the executable (for dev mode or alternative bundling)
        if let Some(ref exe) = exe_dir {
            possible_lib_paths.push(exe.join("lib").join("ollama"));
            possible_lib_paths.push(exe.join("ollama"));
            // Check parent directory too (in case exe is in a subdirectory)
            if let Some(parent) = exe.parent() {
                possible_lib_paths.push(parent.join("lib").join("ollama"));
            }
        }

        let mut lib_paths = Vec::new();

        // Find bundled CPU libraries
        for path in &possible_lib_paths {
            eprintln!("Checking for libs at: {:?} (exists: {})", path, path.exists());
            if path.exists() {
                // Check if this directory has DLLs
                if let Ok(entries) = std::fs::read_dir(path) {
                    let dlls: Vec<_> = entries
                        .flatten()
                        .filter(|e| e.path().extension().map(|ext| ext == "dll").unwrap_or(false))
                        .collect();

                    if !dlls.is_empty() {
                        eprintln!("Found {} DLLs at {:?}:", dlls.len(), path);
                        for dll in &dlls {
                            eprintln!("  - {:?}", dll.path());
                        }
                        lib_paths.push(path.to_string_lossy().to_string());
                        break; // Found the right directory
                    }
                }
            }
        }

        // Downloaded GPU libraries (fetched on demand by the app)
        let gpu_lib = app_data_dir.join("gpu-runners");
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
            eprintln!("WARNING: No library directories found! Ollama may not start.");
            eprintln!("Searched paths:");
            for path in &possible_lib_paths {
                eprintln!("  - {:?}", path);
            }
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

/// Download and install GPU libraries (Windows only) with progress tracking
#[tauri::command]
async fn download_gpu_runners(app: tauri::AppHandle, download_url: String) -> Result<String, String> {
    use futures_util::StreamExt;
    use std::io::Write;
    use tauri::Emitter;

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

    // Emit initial progress
    let _ = app.emit("gpu-download-progress", serde_json::json!({
        "phase": "connecting",
        "percent": 0,
        "message": "Connecting to server..."
    }));

    // Download the file using reqwest with streaming
    let client = reqwest::Client::new();
    let response = client
        .get(&download_url)
        .send()
        .await
        .map_err(|e| format!("Download failed: {}", e))?;

    if !response.status().is_success() {
        return Err(format!("Download failed with status: {}", response.status()));
    }

    // Get content length if available
    let total_size = response.content_length().unwrap_or(0);
    eprintln!("Total download size: {} bytes ({:.1} MB)", total_size, total_size as f64 / 1024.0 / 1024.0);

    // Create file for writing
    let mut file = std::fs::File::create(&zip_path)
        .map_err(|e| format!("Failed to create zip file: {}", e))?;

    // Stream the response body and track progress
    let mut downloaded: u64 = 0;
    let mut last_percent: u64 = 0;
    let mut stream = response.bytes_stream();

    while let Some(chunk_result) = stream.next().await {
        let chunk = chunk_result.map_err(|e| format!("Download error: {}", e))?;
        file.write_all(&chunk)
            .map_err(|e| format!("Failed to write chunk: {}", e))?;

        downloaded += chunk.len() as u64;

        // Calculate and emit progress (only when percent changes to avoid spam)
        if total_size > 0 {
            let percent = (downloaded * 100 / total_size).min(99); // Cap at 99% until extraction
            if percent != last_percent {
                last_percent = percent;
                let downloaded_mb = downloaded as f64 / 1024.0 / 1024.0;
                let total_mb = total_size as f64 / 1024.0 / 1024.0;
                let _ = app.emit("gpu-download-progress", serde_json::json!({
                    "phase": "downloading",
                    "percent": percent,
                    "downloaded": downloaded,
                    "total": total_size,
                    "message": format!("Downloading... {:.1} MB / {:.1} MB", downloaded_mb, total_mb)
                }));
                eprintln!("Download progress: {}% ({:.1} MB / {:.1} MB)", percent, downloaded_mb, total_mb);
            }
        }
    }

    drop(file);
    eprintln!("Download complete, {} bytes saved", downloaded);

    // Emit extracting phase
    let _ = app.emit("gpu-download-progress", serde_json::json!({
        "phase": "extracting",
        "percent": 99,
        "message": "Extracting files..."
    }));

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

        // Emit completion
        let _ = app.emit("gpu-download-progress", serde_json::json!({
            "phase": "complete",
            "percent": 100,
            "message": "Installation complete!"
        }));

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
