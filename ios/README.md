# AI goodbye - iOS App

**Say goodbye to monthly subscriptions, sharing your private data, and requiring internet connection**

AI goodbye is a native iOS app that runs AI completely offline on your iPhone. Upload documents, analyze photos, and have voice conversations - all without internet. Optionally connect to cloud AI (ChatGPT, Claude, Google) using your own API keys.

## Why AI goodbye?

- **No Monthly Subscriptions** - Pay once, use forever
- **Your Data Stays Yours** - No cloud processing, no data collection
- **Works Offline** - Full AI power without internet

## Features

### Core Features
- **100% Offline AI** - Llama 3.2 runs locally on your device
- **Voice Conversations** - Speak naturally in 6 languages
- **Document Chat** - Upload PDFs, Word docs, text files
- **Photo Analysis** - Camera or photo library with OCR
- **Personal Knowledge Base** - Calendar, Health, Reminders integration

### Organization
- **Folders with Locks** - Secure sensitive conversations with 6-digit passwords
- **Chat History** - Full searchable history with iCloud sync
- **Export** - Save chats as TXT, PDF, or JSON

### Platform Support
- **iPhone** - Full-featured iOS 17+ app
- **Apple Watch** - Voice queries on your wrist
- **Home Screen Widgets** - Quick voice and text access

### Privacy
- All AI processing on-device
- No data collection or tracking
- Optional cloud AI with YOUR API keys
- iCloud sync is opt-in and encrypted

## Requirements

- **iPhone 12+** (A14 chip or later)
- **iOS 17.0+**
- **~2GB storage** for AI model
- **Xcode 15+** to build

## Quick Start

### 1. Clone Repository
```bash
git clone https://github.com/Dealer-Of-Happiness/Banana.git
cd Banana/ios
```

### 2. Open in Xcode
```bash
# Create new Xcode project (iOS App, SwiftUI)
# Add this package as dependency
open Package.swift
```

### 3. Configure Signing
- Select your Team in Signing & Capabilities
- Set Bundle ID: `com.aigoodbye`

### 4. Build & Run
- Select your iPhone
- Press Cmd+R

## Project Structure

```
ios/Sources/
├── DOHAI/
│   ├── App/
│   │   ├── AIGoodbyeApp.swift     # App entry point
│   │   └── MainView.swift          # Main container
│   ├── Models/
│   │   ├── Conversation.swift      # Data models
│   │   └── AppSettings.swift       # Settings enums
│   ├── Views/
│   │   ├── Chat/
│   │   │   ├── ChatView.swift      # Main chat UI
│   │   │   └── VoiceInputView.swift # Voice input
│   │   ├── Menu/
│   │   │   └── SideMenuView.swift  # Folders & history
│   │   ├── Settings/
│   │   │   └── SettingsView.swift  # All settings
│   │   └── Onboarding/
│   │       └── TermsView.swift     # Terms acceptance
│   └── Services/
│       ├── LlamaService.swift      # Local AI engine
│       ├── SpeechService.swift     # Text-to-speech
│       ├── DocumentService.swift   # PDF/doc processing
│       ├── ImageAnalysisService.swift # Photo analysis
│       ├── KnowledgeBaseService.swift # Calendar, Health
│       ├── CloudAIService.swift    # ChatGPT, Claude
│       ├── ICloudSyncService.swift # Sync & export
│       ├── ConversationManager.swift # Data management
│       └── SettingsManager.swift   # Preferences
├── DOHAIWidgets/
│   └── DOHAIWidgets.swift          # Home screen widgets
└── DOHAIWatch/
    └── DOHAIWatchApp.swift         # Apple Watch app
```

## Supported Languages

| Language | Voice Input | Voice Output | AI Responses |
|----------|-------------|--------------|--------------|
| English | ✅ | ✅ | ✅ |
| Spanish | ✅ | ✅ | ✅ |
| French | ✅ | ✅ | ✅ |
| Russian | ✅ | ✅ | ✅ |
| Korean | ✅ | ✅ | ✅ |
| Chinese | ✅ | ✅ | ✅ |

## Settings Overview

| Section | Options |
|---------|---------|
| AI Configuration | Temperature (0-2), Context Window (1K-8K) |
| Cloud Connections | ChatGPT, Claude, Google AI (API keys) |
| Language | Input/Output language selection |
| Voice & Sound | Haptic feedback, Voice mode, Speech rate |
| Knowledge Base | Calendar, Health, Fitness, Notes, Email, Reminders |
| Data & Privacy | iCloud sync, Export, Clear cache |

## App Store Checklist

- [x] Privacy manifest (no tracking)
- [x] Terms and Conditions
- [x] All required Info.plist keys
- [x] Non-exempt encryption declaration
- [x] Widget extensions
- [x] Watch app with complications

## Building for App Store

### 1. Set Version
In Xcode: Target > General
- Version: 1.0.0
- Build: 1

### 2. Archive
- Select "Any iOS Device (arm64)"
- Product → Archive

### 3. Upload
- Organizer → Distribute App → App Store Connect

### 4. App Store Connect
- Add screenshots (6.7", 6.5", 5.5")
- Write description
- Set pricing (Paid)
- Submit for review

## License

MIT License

## Contact

marketing@dealerofhappiness.com

Website: https://aigoodbye.ai
