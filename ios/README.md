# Banana AI for iOS

**Run AI completely offline on your iPhone with document knowledge**

Banana AI is a native iOS app that runs large language models directly on your device. Upload documents like Tesla service manuals, and the AI will use that knowledge to answer your questions - all without internet.

## Features

- **100% Offline Operation** - AI runs entirely on your iPhone
- **Document Upload** - Add PDFs, text files to give AI specific knowledge
- **RAG (Retrieval Augmented Generation)** - AI searches your documents for relevant info
- **Optional Internet** - Connect to ChatGPT/Claude when you need more power
- **Privacy First** - Your data never leaves your device

## How It Works

### Local AI
The app uses **llama.cpp** to run quantized language models directly on your iPhone's Neural Engine. We use small, efficient models (1-3B parameters) that fit in iPhone's memory.

### Document Knowledge (RAG)
Instead of "training" (which requires massive compute), we use RAG:
1. Documents are split into chunks
2. Each chunk gets an embedding (semantic fingerprint)
3. When you ask a question, we find relevant chunks
4. Those chunks are included in the AI's context

This means the AI "knows" your Tesla manual without actually retraining!

## Requirements

- iOS 16.0+
- iPhone 12 or newer (A14 chip or later recommended)
- ~2GB free storage for the AI model
- ~4GB RAM (handled automatically by iOS)

## Building the App

### Prerequisites
- Xcode 15+
- macOS Sonoma or later
- Apple Developer account (for device testing)

### Steps

1. **Open in Xcode**
   ```bash
   cd ios
   open Package.swift
   # Or create a new Xcode project and add this as a Swift Package
   ```

2. **Create Xcode Project**
   - File > New > Project
   - Choose "App" under iOS
   - Add this package as a dependency

3. **Configure Signing**
   - Select your Team in Signing & Capabilities
   - Update Bundle Identifier

4. **Build & Run**
   - Select your iPhone as destination
   - Press Cmd+R to build and run

### Including the Model

For App Store distribution, you have two options:

**Option A: Download on First Launch (Recommended)**
- App is small (~50MB)
- Model downloads on first use (~1.8GB)
- Better user experience for App Store

**Option B: Bundle with App**
- Add the GGUF model to the app bundle
- Larger initial download but works immediately offline
- Good for enterprise distribution

## Project Structure

```
ios/
├── Sources/BananaAI/
│   ├── App/
│   │   └── BananaAIApp.swift       # App entry point
│   ├── Views/
│   │   ├── ContentView.swift       # Main container
│   │   ├── ChatView.swift          # Chat interface
│   │   ├── DocumentsView.swift     # Document management
│   │   └── SettingsView.swift      # Settings
│   └── Core/
│       ├── LocalAIEngine.swift     # LLM inference
│       ├── KnowledgeBase.swift     # Vector storage
│       ├── DocumentProcessor.swift # PDF/text processing
│       ├── SettingsManager.swift   # Settings persistence
│       └── OnlineAIConnector.swift # ChatGPT/Claude APIs
├── Package.swift                    # Swift Package config
└── README.md                        # This file
```

## Supported Models

| Model | Size | Quality | Speed |
|-------|------|---------|-------|
| Llama 3.2 1B | 0.9GB | Good | Fastest |
| Llama 3.2 3B | 1.8GB | Better | Fast |
| Phi-3 Mini | 2.3GB | Great for code | Medium |
| Gemma 2 2B | 1.4GB | Balanced | Fast |

## App Store Submission

### Requirements
1. **Privacy Manifest** - Already included (no tracking)
2. **Export Compliance** - Standard encryption only
3. **Age Rating** - 4+ (no objectionable content)

### Tips
- Test on real devices before submission
- Include clear privacy policy
- Emphasize on-device processing
- Consider offering model download as "additional content"

## Limitations

- **No Training**: You can't actually train/fine-tune models on iPhone. We use RAG instead.
- **Context Length**: Limited to ~4K tokens due to memory
- **Speed**: Slower than cloud AI but fully private
- **Model Size**: Limited to ~3B parameter models

## Privacy

- All AI processing happens on-device
- Documents stored locally with encryption
- No analytics or tracking
- Optional internet mode requires explicit user consent

## License

MIT License - Free to use and modify for App Store or personal use.
