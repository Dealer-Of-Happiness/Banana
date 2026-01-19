# AI Goodbye Desktop - Windows Build Script
# Run this on a Windows machine to build the Windows installer

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "AI Goodbye - Windows Build" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor Yellow

# Check Node.js
try {
    $nodeVersion = node --version
    Write-Host "Node.js: $nodeVersion" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Node.js is not installed" -ForegroundColor Red
    Write-Host "Please install Node.js from https://nodejs.org/" -ForegroundColor Yellow
    exit 1
}

# Check Rust
try {
    $rustVersion = rustc --version
    Write-Host "Rust: $rustVersion" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Rust is not installed" -ForegroundColor Red
    Write-Host "Please install Rust from https://rustup.rs/" -ForegroundColor Yellow
    exit 1
}

# Check Python
try {
    $pythonVersion = python --version
    Write-Host "Python: $pythonVersion" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Python is not installed" -ForegroundColor Red
    Write-Host "Please install Python from https://python.org/" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "Installing npm dependencies..." -ForegroundColor Yellow
npm install

Write-Host ""
Write-Host "Bundling Python backend..." -ForegroundColor Yellow
npm run bundle:python

Write-Host ""
Write-Host "Building Tauri application..." -ForegroundColor Yellow
npm run build:windows

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Installer location:" -ForegroundColor Yellow
Write-Host "  src-tauri/target/release/bundle/nsis/" -ForegroundColor White
Write-Host ""
Write-Host "MSI location:" -ForegroundColor Yellow
Write-Host "  src-tauri/target/release/bundle/msi/" -ForegroundColor White
