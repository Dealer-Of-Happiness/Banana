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

/// Copy DLLs from resources to the correct location for Ollama (Windows only)
/// Ollama expects DLLs in lib/ollama/ relative to its executable
#[cfg(target_os = "windows")]
fn setup_ollama_libraries(app: &tauri::App) -> Result<std::path::PathBuf, String> {
    use std::fs;

    eprintln!("=== Setting up Ollama libraries ===");

    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|e| format!("Failed to get resource dir: {}", e))?;

    let app_data_dir = app
        .path()
        .app_local_data_dir()
        .map_err(|e| format!("Failed to get app data dir: {}", e))?;

    // The sidecar (ollama.exe) is placed next to the main app executable
    let exe_dir = std::env::current_exe()
        .map_err(|e| format!("Failed to get exe path: {}", e))?
        .parent()
        .ok_or("Failed to get exe directory")?
        .to_path_buf();

    eprintln!("Resource dir: {:?}", resource_dir);
    eprintln!("App data dir: {:?}", app_data_dir);
    eprintln!("Exe dir: {:?}", exe_dir);

    // Target location: lib/ollama/ relative to the exe (where sidecar is)
    let target_lib_dir = exe_dir.join("lib").join("ollama");

    // Source locations to check for bundled DLLs
    let source_paths = vec![
        resource_dir.join("lib").join("ollama"),
        resource_dir.join("ollama"),
        resource_dir.clone(),
    ];

    // Find DLLs in resources
    let mut source_dll_dir: Option<std::path::PathBuf> = None;
    for path in &source_paths {
        eprintln!("Checking for DLLs at: {:?}", path);
        if path.exists() {
            if let Ok(entries) = fs::read_dir(path) {
                let dlls: Vec<_> = entries
                    .flatten()
                    .filter(|e| {
                        e.path()
                            .extension()
                            .map(|ext| ext == "dll")
                            .unwrap_or(false)
                    })
                    .collect();
                if !dlls.is_empty() {
                    eprintln!("Found {} DLLs at {:?}", dlls.len(), path);
                    source_dll_dir = Some(path.clone());
                    break;
                }
            }
        }
    }

    // Copy DLLs to the correct location if found
    if let Some(source_dir) = source_dll_dir {
        // Only copy if target doesn't exist or source is newer
        let should_copy = if target_lib_dir.exists() {
            // Check if we need to update (simple check: compare file counts)
            let source_count = fs::read_dir(&source_dir)
                .map(|e| e.count())
                .unwrap_or(0);
            let target_count = fs::read_dir(&target_lib_dir)
                .map(|e| e.count())
                .unwrap_or(0);
            source_count != target_count
        } else {
            true
        };

        if should_copy {
            eprintln!("Copying DLLs from {:?} to {:?}", source_dir, target_lib_dir);

            // Create target directory
            fs::create_dir_all(&target_lib_dir)
                .map_err(|e| format!("Failed to create lib dir: {}", e))?;

            // Copy all DLL files
            if let Ok(entries) = fs::read_dir(&source_dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.extension().map(|e| e == "dll").unwrap_or(false) {
                        let filename = path.file_name().unwrap();
                        let target_path = target_lib_dir.join(filename);
                        eprintln!("  Copying: {:?} -> {:?}", path, target_path);
                        if let Err(e) = fs::copy(&path, &target_path) {
                            eprintln!("  Warning: Failed to copy {:?}: {}", filename, e);
                        }
                    }
                }
            }
            eprintln!("DLL copy complete");
        } else {
            eprintln!("DLLs already in place at {:?}", target_lib_dir);
        }
    } else {
        eprintln!("WARNING: No bundled DLLs found in resources!");
        eprintln!("Searched paths:");
        for path in &source_paths {
            eprintln!("  - {:?} (exists: {})", path, path.exists());
        }
    }

    // Also copy downloaded GPU libraries if available
    let gpu_source = app_data_dir.join("gpu-runners");
    if gpu_source.exists() {
        eprintln!("Setting up GPU libraries from {:?}", gpu_source);
        if let Ok(entries) = fs::read_dir(&gpu_source) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    // GPU libraries are in subdirectories (cuda_v12, vulkan, etc.)
                    let dir_name = path.file_name().unwrap();
                    let target_gpu_dir = target_lib_dir.join(dir_name);

                    if !target_gpu_dir.exists() {
                        eprintln!("  Copying GPU dir: {:?}", dir_name);
                        copy_dir_recursive(&path, &target_gpu_dir)?;
                    }
                }
            }
        }
    }

    // List final contents of target lib dir
    eprintln!("Final lib directory contents ({:?}):", target_lib_dir);
    if let Ok(entries) = fs::read_dir(&target_lib_dir) {
        for entry in entries.flatten() {
            eprintln!("  {:?}", entry.path());
        }
    }

    Ok(target_lib_dir)
}

/// Recursively copy a directory
#[cfg(target_os = "windows")]
fn copy_dir_recursive(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    use std::fs;

    fs::create_dir_all(dst).map_err(|e| format!("Failed to create dir {:?}: {}", dst, e))?;

    for entry in fs::read_dir(src).map_err(|e| format!("Failed to read dir {:?}: {}", src, e))? {
        let entry = entry.map_err(|e| format!("Failed to read entry: {}", e))?;
        let path = entry.path();
        let target = dst.join(entry.file_name());

        if path.is_dir() {
            copy_dir_recursive(&path, &target)?;
        } else {
            fs::copy(&path, &target)
                .map_err(|e| format!("Failed to copy {:?}: {}", path, e))?;
        }
    }
    Ok(())
}

/// Start the Ollama server using Tauri's sidecar API
fn start_ollama_server(app: &tauri::App) -> Result<CommandChild, String> {
    eprintln!("=== Starting Ollama via Tauri Sidecar ===");

    // Build the base sidecar command
    // Set OLLAMA_ORIGINS to allow Tauri's localhost origin
    // Set OLLAMA_KEEP_ALIVE=0 to unload models immediately after use (saves RAM)
    let mut sidecar_command = app
        .shell()
        .sidecar("ollama")
        .map_err(|e| format!("Failed to create sidecar command: {}", e))?
        .args(["serve"])
        .env("OLLAMA_HOST", "127.0.0.1:11434")
        .env("OLLAMA_ORIGINS", "*")  // Allow all origins for Tauri
        .env("OLLAMA_KEEP_ALIVE", "0");  // Unload models immediately after use to free RAM

    // On Windows, set up libraries and environment
    #[cfg(target_os = "windows")]
    {
        // Set up libraries (copy DLLs to correct location)
        match setup_ollama_libraries(app) {
            Ok(lib_dir) => {
                eprintln!("Libraries set up at: {:?}", lib_dir);

                // Add library directory to PATH as a fallback
                let current_path = std::env::var("PATH").unwrap_or_default();
                let lib_dir_str = lib_dir.to_string_lossy();
                let new_path = format!("{};{}", lib_dir_str, current_path);

                sidecar_command = sidecar_command.env("PATH", &new_path);
                eprintln!("Added {:?} to PATH", lib_dir);
            }
            Err(e) => {
                eprintln!("Warning: Failed to set up libraries: {}", e);
            }
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

/// Unload all loaded models to free RAM (with timeout)
async fn unload_all_models() {
    use std::time::Duration;

    eprintln!("Attempting to unload all models...");

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap_or_default();

    // Try to get list of loaded models
    if let Ok(response) = client.get("http://127.0.0.1:11434/api/ps").send().await {
        if let Ok(data) = response.json::<serde_json::Value>().await {
            if let Some(models) = data.get("models").and_then(|m| m.as_array()) {
                for model in models {
                    if let Some(name) = model.get("name").and_then(|n| n.as_str()) {
                        eprintln!("Unloading model: {}", name);
                        // Send a request with keep_alive=0 to force unload
                        let _ = client
                            .post("http://127.0.0.1:11434/api/generate")
                            .json(&serde_json::json!({
                                "model": name,
                                "keep_alive": 0
                            }))
                            .send()
                            .await;
                    }
                }
            }
        }
    }
    eprintln!("Model unload complete");
}

/// Kill all Ollama processes (including child processes like GPU runners)
fn kill_all_ollama_processes() {
    eprintln!("Killing all Ollama processes...");

    #[cfg(target_os = "macos")]
    {
        // On macOS, use pkill to kill all ollama processes
        let _ = std::process::Command::new("pkill")
            .args(["-9", "-f", "ollama"])
            .output();

        // Also try to kill any llama runner processes
        let _ = std::process::Command::new("pkill")
            .args(["-9", "-f", "llama"])
            .output();

        eprintln!("Sent SIGKILL to all ollama/llama processes");
    }

    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("pkill")
            .args(["-9", "-f", "ollama"])
            .output();
        let _ = std::process::Command::new("pkill")
            .args(["-9", "-f", "llama"])
            .output();
        eprintln!("Sent SIGKILL to all ollama/llama processes");
    }

    #[cfg(target_os = "windows")]
    {
        // On Windows, use taskkill to forcefully terminate
        let _ = std::process::Command::new("taskkill")
            .args(["/F", "/IM", "ollama.exe"])
            .output();

        // Also kill any runner processes
        let _ = std::process::Command::new("taskkill")
            .args(["/F", "/IM", "ollama_llama_server.exe"])
            .output();

        eprintln!("Sent taskkill to ollama processes");
    }
}

/// Stop the Ollama server
fn stop_ollama_server(state: &State<'_, OllamaProcess>) {
    let mut process_guard = state.0.lock().unwrap();

    if let Some(child) = process_guard.take() {
        eprintln!("Stopping Ollama server (PID: {:?})...", child.pid());
        let _ = child.kill();
    }

    // Always try to kill any remaining Ollama processes
    kill_all_ollama_processes();

    eprintln!("Ollama cleanup complete");
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

                // Try to unload models gracefully first (with short timeout)
                // This is best-effort - we'll force kill processes regardless
                let unload_result = std::panic::catch_unwind(|| {
                    tauri::async_runtime::block_on(async {
                        tokio::time::timeout(
                            std::time::Duration::from_secs(3),
                            unload_all_models()
                        ).await
                    })
                });

                if unload_result.is_err() {
                    eprintln!("Model unload timed out or failed, proceeding with force kill");
                }

                // Force stop all Ollama processes
                let state: State<OllamaProcess> = handle.state();
                stop_ollama_server(&state);
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
