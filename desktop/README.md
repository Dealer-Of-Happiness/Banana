# Banana AI Desktop

Desktop application for Windows and macOS, downloadable from [aigoodbye.ai](https://aigoodbye.ai).

**Price: $9.99** (one-time purchase)

## Overview

Banana AI Desktop is a native application that provides:

- **Offline AI Chat** - Run AI locally with Ollama
- **Internet AI Access** - Connect to ChatGPT and Claude
- **Hybrid Mode** - Automatic fallback between local and cloud
- **Knowledge Base** - Upload documents for RAG
- **Model Training** - Fine-tune models with LoRA

## Architecture

```
┌─────────────────────────────────────────────────┐
│              Banana AI Desktop                   │
├─────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────┐    │
│  │         Tauri (Native Wrapper)           │    │
│  │    - Window management                   │    │
│  │    - Auto-updates                        │    │
│  │    - System integration                  │    │
│  └─────────────────────────────────────────┘    │
│                      │                           │
│  ┌─────────────────────────────────────────┐    │
│  │         Frontend (HTML/CSS/JS)           │    │
│  │    - Modern UI                           │    │
│  │    - Chat interface                      │    │
│  │    - Settings management                 │    │
│  └─────────────────────────────────────────┘    │
│                      │                           │
│  ┌─────────────────────────────────────────┐    │
│  │      Python Backend (PyInstaller)        │    │
│  │    - FastAPI server                      │    │
│  │    - AI engine                           │    │
│  │    - Ollama integration                  │    │
│  └─────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
```

## Prerequisites

### For Building

- **Node.js** 18+ ([nodejs.org](https://nodejs.org))
- **Rust** 1.70+ ([rustup.rs](https://rustup.rs))
- **Python** 3.10+ ([python.org](https://python.org))
- **Tauri CLI** (`cargo install tauri-cli`)

### For Users

- **Ollama** (optional, for local AI) - [ollama.ai](https://ollama.ai)
- **API Keys** (optional, for cloud AI) - OpenAI, Anthropic

## Development

### Setup

```bash
cd desktop
npm install
```

### Run in Development Mode

```bash
npm run dev
```

This will:
1. Start the Python backend
2. Launch the Tauri development window
3. Enable hot-reload for the frontend

### Build for Production

**Windows:**
```powershell
.\scripts\build-windows.ps1
```

**macOS:**
```bash
chmod +x scripts/build-macos.sh
./scripts/build-macos.sh
```

**All platforms (using npm):**
```bash
npm run package:all
```

## Build Outputs

After building, installers are located at:

| Platform | Location | Format |
|----------|----------|--------|
| Windows | `src-tauri/target/release/bundle/nsis/` | `.exe` installer |
| Windows | `src-tauri/target/release/bundle/msi/` | `.msi` installer |
| macOS | `src-tauri/target/release/bundle/dmg/` | `.dmg` disk image |
| macOS | `src-tauri/target/release/bundle/macos/` | `.app` bundle |

## Selling on aigoodbye.ai

### 1. Payment Integration

Recommended payment providers:
- **Stripe** - Best for subscriptions and one-time purchases
- **Gumroad** - Easy setup, handles everything
- **Paddle** - Handles taxes globally
- **LemonSqueezy** - Modern alternative to Gumroad

### 2. Download Delivery

After payment, redirect users to a secure download page:

```
https://aigoodbye.ai/download?token=UNIQUE_TOKEN
```

Options:
- **Time-limited links** (expire after 24 hours)
- **Download count limits** (3-5 downloads per purchase)
- **License key system** (for future updates)

### 3. Suggested Pricing Page Layout

```
┌─────────────────────────────────────┐
│         Banana AI Desktop           │
│                                     │
│  Your Offline AI with Internet      │
│         Connectivity                │
│                                     │
│         $9.99                       │
│      One-time purchase              │
│                                     │
│  ✓ Windows & macOS                  │
│  ✓ Lifetime updates                 │
│  ✓ Local AI (Ollama)                │
│  ✓ ChatGPT & Claude access          │
│  ✓ Knowledge base & RAG             │
│  ✓ Model training                   │
│                                     │
│  [Buy Now - $9.99]                  │
│                                     │
│  ────────────────────────────────   │
│                                     │
│  Try the iOS app free first:        │
│  [Download on App Store]            │
│                                     │
└─────────────────────────────────────┘
```

## Code Signing

### Windows

1. Purchase a code signing certificate from:
   - DigiCert
   - Sectigo
   - GlobalSign

2. Sign during build:
   ```powershell
   $env:TAURI_SIGNING_PRIVATE_KEY = Get-Content cert.key
   npm run build:windows
   ```

### macOS

1. Enroll in Apple Developer Program ($99/year)

2. Create a "Developer ID Application" certificate

3. Sign and notarize:
   ```bash
   # Sign
   codesign --deep --force --sign "Developer ID Application: Your Name" \
     "target/release/bundle/macos/Banana AI.app"

   # Notarize
   xcrun notarytool submit "Banana AI.dmg" \
     --apple-id "your@email.com" \
     --password "app-specific-password" \
     --team-id "YOUR_TEAM_ID" \
     --wait

   # Staple
   xcrun stapler staple "Banana AI.dmg"
   ```

## Auto-Updates

The app supports automatic updates via Tauri's updater plugin.

See `update-server/README.md` for setup instructions.

## File Structure

```
desktop/
├── package.json           # npm configuration
├── vite.config.js         # Vite bundler config
├── banana-backend.spec    # PyInstaller config
├── LICENSE                # Proprietary license
│
├── src/                   # Frontend source
│   ├── index.html         # Main HTML
│   ├── styles.css         # Styles
│   └── app.js             # Application logic
│
├── src-tauri/             # Tauri/Rust source
│   ├── Cargo.toml         # Rust dependencies
│   ├── tauri.conf.json    # Tauri configuration
│   ├── src/
│   │   └── main.rs        # Rust backend
│   ├── binaries/          # Bundled Python backend
│   └── icons/             # App icons
│
├── scripts/               # Build scripts
│   ├── bundle-python.js   # Python bundler
│   ├── build-windows.ps1  # Windows build
│   └── build-macos.sh     # macOS build
│
└── update-server/         # Auto-update config
    ├── update-config.json
    └── README.md
```

## Troubleshooting

### "Backend not starting"

1. Check if port 8765 is available
2. Ensure Ollama is installed for local AI
3. Check the console for error messages

### "Build fails on Windows"

1. Install Visual Studio Build Tools
2. Ensure Windows SDK is installed
3. Run from Developer Command Prompt

### "macOS app is damaged"

The app needs to be signed and notarized. For testing:
```bash
xattr -cr "/Applications/Banana AI.app"
```

## Support

- Email: marketing@dealerofhappiness.com
- Website: https://aigoodbye.ai
- GitHub Issues: Report bugs and feature requests

## License

Proprietary - See LICENSE file for terms.
