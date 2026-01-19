#!/usr/bin/env node
/**
 * Bundle Python Backend for Tauri
 *
 * This script uses PyInstaller to create a standalone executable
 * from the Python backend that can be bundled with the Tauri app.
 */

const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const projectRoot = path.resolve(__dirname, '../..');
const desktopDir = path.resolve(__dirname, '..');
const tauriDir = path.join(desktopDir, 'src-tauri');

// Determine platform-specific settings
const platform = process.platform;
const arch = process.arch;

const binaryName = platform === 'win32' ? 'aigoodbye-backend.exe' : 'aigoodbye-backend';

// Support explicit target via environment variable (useful for CI)
// This allows overriding auto-detection when needed
const targetTriple = process.env.TAURI_TARGET || getTargetTriple();

console.log('='.repeat(60));
console.log('AI Goodbye - Python Backend Bundler');
console.log('='.repeat(60));
console.log(`Platform: ${platform}`);
console.log(`Architecture: ${arch}`);
console.log(`Target: ${targetTriple}${process.env.TAURI_TARGET ? ' (from TAURI_TARGET env)' : ''}`);
console.log('');

function getTargetTriple() {
    if (platform === 'win32') {
        return arch === 'x64' ? 'x86_64-pc-windows-msvc' : 'i686-pc-windows-msvc';
    } else if (platform === 'darwin') {
        return arch === 'arm64' ? 'aarch64-apple-darwin' : 'x86_64-apple-darwin';
    } else {
        return arch === 'x64' ? 'x86_64-unknown-linux-gnu' : 'aarch64-unknown-linux-gnu';
    }
}

function ensureBinariesDir() {
    const binDir = path.join(tauriDir, 'binaries');
    if (!fs.existsSync(binDir)) {
        fs.mkdirSync(binDir, { recursive: true });
    }
    return binDir;
}

function checkPythonDependencies() {
    console.log('Checking Python dependencies...');

    try {
        execSync('python --version', { stdio: 'pipe' });
    } catch (e) {
        console.error('ERROR: Python is not installed or not in PATH');
        process.exit(1);
    }

    try {
        execSync('python -c "import PyInstaller"', { stdio: 'pipe' });
    } catch (e) {
        console.log('Installing PyInstaller...');
        execSync('pip install pyinstaller', { stdio: 'inherit' });
    }

    console.log('Python dependencies OK\n');
}

function installProjectDependencies() {
    console.log('Installing project dependencies...');

    // Create a minimal requirements file for the backend-only build
    const minimalReqs = `
fastapi>=0.104.0
uvicorn>=0.24.0
httpx>=0.25.0
openai>=1.3.0
anthropic>=0.7.0
chromadb>=0.4.0
ollama>=0.1.0
python-dotenv>=1.0.0
pydantic>=2.5.0
pydantic-settings>=2.1.0
rich>=13.7.0
click>=8.1.0
PyYAML>=6.0.0
websockets>=12.0
python-multipart>=0.0.6
aiohttp>=3.9.0
    `.trim();

    const reqsPath = path.join(desktopDir, 'requirements-minimal.txt');
    fs.writeFileSync(reqsPath, minimalReqs);

    try {
        execSync(`pip install -r "${reqsPath}"`, { stdio: 'inherit', cwd: projectRoot });
    } catch (e) {
        console.warn('Some dependencies may have failed to install');
    }

    console.log('Dependencies installed\n');
}

function buildBackend() {
    console.log('Building Python backend with PyInstaller...');

    const specFile = path.join(desktopDir, 'aigoodbye-backend.spec');
    const distDir = path.join(desktopDir, 'dist');

    // Clean previous build
    if (fs.existsSync(distDir)) {
        fs.rmSync(distDir, { recursive: true });
    }

    // Run PyInstaller
    try {
        execSync(
            `python -m PyInstaller "${specFile}" --distpath "${distDir}" --workpath "${path.join(desktopDir, 'build')}" --clean`,
            { stdio: 'inherit', cwd: projectRoot }
        );
    } catch (e) {
        console.error('PyInstaller build failed');
        process.exit(1);
    }

    console.log('Backend built successfully\n');
    return distDir;
}

function copyToTauri(distDir) {
    console.log('Copying binary to Tauri binaries directory...');

    const binDir = ensureBinariesDir();
    const sourceBinary = path.join(distDir, binaryName);
    const targetBinary = path.join(binDir, `aigoodbye-backend-${targetTriple}${platform === 'win32' ? '.exe' : ''}`);

    if (!fs.existsSync(sourceBinary)) {
        console.error(`ERROR: Built binary not found at ${sourceBinary}`);
        process.exit(1);
    }

    fs.copyFileSync(sourceBinary, targetBinary);

    // Make executable on Unix
    if (platform !== 'win32') {
        fs.chmodSync(targetBinary, 0o755);
    }

    console.log(`Binary copied to: ${targetBinary}\n`);
}

function createDefaultIcons() {
    console.log('Creating default icons...');

    const iconsDir = path.join(tauriDir, 'icons');
    if (!fs.existsSync(iconsDir)) {
        fs.mkdirSync(iconsDir, { recursive: true });
    }

    // Create a simple placeholder message
    const placeholderContent = `
Icon files should be placed here:
- 32x32.png
- 128x128.png
- 128x128@2x.png
- icon.icns (macOS)
- icon.ico (Windows)

Use a tool like https://icon.kitchen/ to generate icons from your logo.
    `.trim();

    const placeholderPath = path.join(iconsDir, 'README.txt');
    if (!fs.existsSync(placeholderPath)) {
        fs.writeFileSync(placeholderPath, placeholderContent);
    }

    console.log('Icons directory ready\n');
}

// Main execution
async function main() {
    try {
        checkPythonDependencies();
        installProjectDependencies();
        const distDir = buildBackend();
        copyToTauri(distDir);
        createDefaultIcons();

        console.log('='.repeat(60));
        console.log('SUCCESS! Python backend bundled for Tauri');
        console.log('='.repeat(60));
        console.log('');
        console.log('Next steps:');
        console.log('1. Add your app icons to desktop/src-tauri/icons/');
        console.log('2. Run: npm run build');
        console.log('');

    } catch (error) {
        console.error('Build failed:', error.message);
        process.exit(1);
    }
}

main();
