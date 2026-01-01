# Banana AI

**Your Offline AI with Internet Connectivity**

Banana AI is a local AI system that runs on your computer or iPhone, can be trained for specific tasks, and has the ability to connect to the internet when needed (Google, ChatGPT, Claude).

## Platforms

| Platform | Status | Description |
|----------|--------|-------------|
| **Desktop** (Python) | ✅ Ready | Full-featured CLI and Web UI |
| **iOS** (iPhone) | ✅ Ready | Native SwiftUI app for App Store |

## Features

- **Offline Operation**: Run AI models locally - no internet required
- **iOS App**: Native iPhone app using llama.cpp
- **Internet Connectivity**: Connect to ChatGPT, Claude, and Google when you need additional capabilities
- **Document Knowledge**: Upload PDFs/documents to give AI specialized knowledge (RAG)
- **Custom Training**: Fine-tune models for your specific tasks using LoRA (desktop)
- **Multiple Interfaces**: CLI, Web UI, and native iOS app
- **Hybrid Mode**: Automatically use local AI first, fallback to internet when needed
- **Privacy First**: All processing happens on your device

## Quick Start

### 1. Install Ollama (for local AI)

```bash
# macOS/Linux
curl -fsSL https://ollama.ai/install.sh | sh

# Start Ollama
ollama serve
```

### 2. Install Banana AI

```bash
# Clone the repository
git clone https://github.com/your-repo/Banana.git
cd Banana

# Create virtual environment
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -e .
```

### 3. Pull a local model

```bash
# Pull a lightweight model (recommended for most computers)
ollama pull llama3.2:3b

# Or a more capable model (requires more RAM)
ollama pull llama3.2:8b
```

### 4. Start chatting!

```bash
# CLI mode
banana chat

# Or start the web server
banana serve
# Then open http://localhost:8000
```

## Configuration

Create a `.env` file in the project root:

```env
# Local AI Settings
BANANA_LOCAL_MODEL_NAME=llama3.2:3b
BANANA_OLLAMA_HOST=http://localhost:11434
BANANA_USE_GPU=true

# Internet API Keys (optional - for internet mode)
BANANA_OPENAI_API_KEY=sk-...
BANANA_ANTHROPIC_API_KEY=sk-ant-...
BANANA_GOOGLE_API_KEY=...
BANANA_GOOGLE_CSE_ID=...

# Training Settings
BANANA_TRAINING_EPOCHS=3
BANANA_TRAINING_BATCH_SIZE=4
BANANA_LORA_RANK=16
```

## Usage

### CLI Commands

```bash
# Start interactive chat
banana chat

# Chat with specific mode
banana chat --mode local      # Only use local models
banana chat --mode internet   # Only use internet APIs
banana chat --mode hybrid     # Use local first, fallback to internet

# Check system status
banana status

# List available models
banana models

# Pull a new model
banana pull mistral:7b

# Start web server
banana serve --port 8000
```

### In-Chat Commands

While chatting, you can use these commands:

- `/help` - Show available commands
- `/quit` - Exit the chat
- `/clear` - Clear conversation history
- `/status` - Show AI status
- `/mode <local|internet|hybrid>` - Change operating mode
- `/system <prompt>` - Set system prompt
- `/search <query>` - Search the web
- `/chatgpt <message>` - Query ChatGPT directly
- `/claude <message>` - Query Claude directly

### Knowledge Base

Add your own documents for context-aware responses:

```bash
# Add a file
banana kb add ./my-document.txt

# Search the knowledge base
banana kb search "how to configure"

# View stats
banana kb stats
```

### Training Custom Models

Train the AI for your specific tasks:

1. Create a training data file (`training_data.json`):

```json
[
  {"input": "Translate to French: Hello", "output": "Bonjour"},
  {"input": "Translate to French: Goodbye", "output": "Au revoir"},
  {"input": "Translate to French: Thank you", "output": "Merci"}
]
```

2. Train the model:

```bash
banana train task my-translator training_data.json
```

3. Use the trained model:

```python
from banana_ai import BananaAI

ai = BananaAI()
response = await ai.trainer.generate_with_trained_model(
    task_name="my-translator",
    prompt="Translate to French: Good morning"
)
```

## Python API

```python
import asyncio
from banana_ai import BananaAI, Config

async def main():
    # Initialize
    config = Config()
    ai = BananaAI(config)

    # Simple chat
    response = await ai.chat("What is the capital of France?")
    print(response.content)

    # Stream response
    async for chunk in await ai.chat("Tell me a story", stream=True):
        print(chunk, end="")

    # Direct API queries
    gpt_response = await ai.ask_chatgpt("Explain quantum computing")
    claude_response = await ai.ask_claude("Write a haiku about AI")

    # Web search
    results = await ai.search_web("latest AI news")

    # Add to knowledge base
    await ai.add_document("My company policy is...")
    await ai.add_file("./documents/handbook.pdf")

asyncio.run(main())
```

## Architecture

```
banana_ai/
├── core/
│   ├── config.py      # Configuration management
│   └── engine.py      # Main AI engine orchestration
├── local/
│   └── ollama_engine.py   # Local LLM via Ollama
├── internet/
│   └── connector.py   # ChatGPT, Claude, Google APIs
├── knowledge/
│   └── vector_store.py    # RAG with ChromaDB
├── training/
│   └── trainer.py     # LoRA fine-tuning
├── web/
│   └── app.py         # FastAPI web interface
└── cli.py             # Command-line interface
```

## Requirements

- Python 3.10+
- Ollama (for local AI)
- 8GB+ RAM (16GB recommended for larger models)
- GPU optional but recommended for training

## Models

Recommended local models:

| Model | Size | RAM Required | Best For |
|-------|------|--------------|----------|
| llama3.2:3b | 2GB | 8GB | Quick responses, low resources |
| llama3.2:8b | 5GB | 16GB | Better quality, general use |
| codellama:7b | 4GB | 16GB | Code generation |
| mistral:7b | 4GB | 16GB | Balanced quality/speed |

## Troubleshooting

### "Cannot connect to Ollama"

Make sure Ollama is running:
```bash
ollama serve
```

### "No models available"

Pull a model first:
```bash
ollama pull llama3.2:3b
```

### "Out of memory"

Use a smaller model or enable 8-bit quantization in config.

## iOS App

Banana AI is also available as a native iOS app! See the [ios/README.md](ios/README.md) for details.

### Features
- Run AI completely offline on iPhone 12+
- Upload documents (Tesla manuals, etc.) for specialized knowledge
- Optional ChatGPT/Claude integration
- Privacy-focused - data never leaves your device

### Building
```bash
cd ios
# Open in Xcode
open Package.swift
```

### App Store
The iOS app is designed for App Store distribution with:
- Privacy manifest included
- No tracking or analytics
- Standard encryption compliance

## License

MIT License - feel free to use and modify!
