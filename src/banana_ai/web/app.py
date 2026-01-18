"""
AIGoodbye Web Application.

Provides a web interface for interacting with your AI.
"""

import json
from typing import Optional

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from banana_ai.core.config import Config
from banana_ai.core.engine import AIMode, BananaAI


class ChatRequest(BaseModel):
    """Chat request model."""

    message: str
    use_knowledge_base: bool = True
    mode: Optional[str] = None


class ChatResponse(BaseModel):
    """Chat response model."""

    content: str
    source: str
    model: str
    tokens_used: int


class TrainRequest(BaseModel):
    """Training request model."""

    task_name: str
    training_data: list[dict]
    base_model: str = "meta-llama/Llama-3.2-3B"


class DocumentRequest(BaseModel):
    """Document add request model."""

    content: str
    metadata: Optional[dict] = None


def create_app(config: Optional[Config] = None) -> FastAPI:
    """Create and configure the FastAPI application."""
    config = config or Config()
    ai = BananaAI(config)

    app = FastAPI(
        title="AIGoodbye",
        description="Your Offline AI with Internet Connectivity",
        version="1.0.0",
    )

    # CORS middleware
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # ==================== API Routes ====================

    @app.get("/")
    async def home():
        """Serve the main chat interface."""
        return HTMLResponse(get_chat_html())

    @app.get("/api/status")
    async def status():
        """Get AI system status."""
        return await ai.check_status()

    @app.post("/api/chat", response_model=ChatResponse)
    async def chat(request: ChatRequest):
        """Send a chat message and get a response."""
        if request.mode:
            ai.set_mode(AIMode(request.mode))

        response = await ai.chat(
            message=request.message,
            use_knowledge_base=request.use_knowledge_base,
        )

        return ChatResponse(
            content=response.content,
            source=response.source,
            model=response.model,
            tokens_used=response.tokens_used,
        )

    @app.websocket("/ws/chat")
    async def websocket_chat(websocket: WebSocket):
        """WebSocket endpoint for streaming chat."""
        await websocket.accept()

        try:
            while True:
                data = await websocket.receive_text()
                message = json.loads(data)

                user_message = message.get("message", "")
                use_kb = message.get("use_knowledge_base", True)

                response_gen = await ai.chat(
                    message=user_message,
                    use_knowledge_base=use_kb,
                    stream=True,
                )

                async for chunk in response_gen:
                    await websocket.send_text(json.dumps({"chunk": chunk}))

                await websocket.send_text(json.dumps({"done": True}))

        except WebSocketDisconnect:
            pass

    @app.post("/api/search")
    async def web_search(query: str):
        """Search the web."""
        try:
            results = await ai.search_web(query)
            return {"results": results}
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))

    @app.post("/api/chatgpt")
    async def query_chatgpt(message: str, model: str = "gpt-4o"):
        """Query ChatGPT directly."""
        try:
            response = await ai.ask_chatgpt(message, model)
            return {
                "content": response.content,
                "model": response.model,
                "tokens": response.tokens_used,
            }
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))

    @app.post("/api/claude")
    async def query_claude(message: str, model: str = "claude-3-5-sonnet-20241022"):
        """Query Claude directly."""
        try:
            response = await ai.ask_claude(message, model)
            return {
                "content": response.content,
                "model": response.model,
                "tokens": response.tokens_used,
            }
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))

    # ==================== Knowledge Base Routes ====================

    @app.post("/api/kb/add")
    async def add_document(request: DocumentRequest):
        """Add a document to the knowledge base."""
        await ai.add_document(request.content, request.metadata)
        return {"success": True}

    @app.get("/api/kb/search")
    async def search_kb(query: str, top_k: int = 5):
        """Search the knowledge base."""
        results = await ai.knowledge_base.search(query, top_k=top_k)
        return {"results": results}

    @app.get("/api/kb/stats")
    async def kb_stats():
        """Get knowledge base statistics."""
        return await ai.knowledge_base.get_stats()

    # ==================== Training Routes ====================

    @app.post("/api/train")
    async def train_model(request: TrainRequest):
        """Train a model for a specific task."""
        try:
            result = await ai.train(
                training_data=request.training_data,
                task_name=request.task_name,
                base_model=request.base_model,
            )
            return result
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))

    @app.get("/api/models")
    async def list_models():
        """List trained models."""
        models = await ai.trainer.list_trained_models()
        return {"models": models}

    # ==================== Settings Routes ====================

    @app.post("/api/mode/{mode}")
    async def set_mode(mode: str):
        """Set the AI operating mode."""
        if mode not in ("local", "internet", "hybrid"):
            raise HTTPException(status_code=400, detail="Invalid mode")
        ai.set_mode(AIMode(mode))
        return {"mode": mode}

    @app.post("/api/system-prompt")
    async def set_system_prompt(prompt: str):
        """Set the system prompt."""
        ai.set_system_prompt(prompt)
        return {"success": True}

    @app.post("/api/clear")
    async def clear_history():
        """Clear conversation history."""
        ai.clear_history()
        return {"success": True}

    return app


def get_chat_html() -> str:
    """Return the chat interface HTML."""
    return """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AIGoodbye</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: #fff;
            height: 100vh;
            display: flex;
            flex-direction: column;
        }

        .header {
            padding: 20px;
            text-align: center;
            border-bottom: 1px solid #333;
        }

        .header h1 {
            color: #f7d716;
            font-size: 2rem;
        }

        .header .subtitle {
            color: #888;
            font-size: 0.9rem;
        }

        .controls {
            display: flex;
            gap: 10px;
            justify-content: center;
            padding: 15px;
            background: rgba(0,0,0,0.2);
        }

        .controls select, .controls button {
            padding: 8px 16px;
            border: none;
            border-radius: 5px;
            background: #333;
            color: #fff;
            cursor: pointer;
        }

        .controls button:hover {
            background: #444;
        }

        .controls button.active {
            background: #f7d716;
            color: #000;
        }

        .chat-container {
            flex: 1;
            overflow-y: auto;
            padding: 20px;
            display: flex;
            flex-direction: column;
            gap: 15px;
        }

        .message {
            max-width: 80%;
            padding: 15px 20px;
            border-radius: 15px;
            line-height: 1.5;
        }

        .message.user {
            background: #0066cc;
            align-self: flex-end;
            border-bottom-right-radius: 5px;
        }

        .message.assistant {
            background: #333;
            align-self: flex-start;
            border-bottom-left-radius: 5px;
        }

        .message .source {
            font-size: 0.75rem;
            color: #888;
            margin-top: 8px;
        }

        .input-container {
            padding: 20px;
            border-top: 1px solid #333;
            display: flex;
            gap: 10px;
        }

        #message-input {
            flex: 1;
            padding: 15px;
            border: none;
            border-radius: 10px;
            background: #333;
            color: #fff;
            font-size: 1rem;
        }

        #message-input:focus {
            outline: 2px solid #f7d716;
        }

        #send-button {
            padding: 15px 30px;
            border: none;
            border-radius: 10px;
            background: #f7d716;
            color: #000;
            font-weight: bold;
            cursor: pointer;
            transition: transform 0.1s;
        }

        #send-button:hover {
            transform: scale(1.05);
        }

        #send-button:disabled {
            background: #666;
            cursor: not-allowed;
        }

        .typing {
            display: flex;
            gap: 5px;
            padding: 10px;
        }

        .typing span {
            width: 8px;
            height: 8px;
            background: #f7d716;
            border-radius: 50%;
            animation: bounce 1.4s infinite ease-in-out;
        }

        .typing span:nth-child(1) { animation-delay: -0.32s; }
        .typing span:nth-child(2) { animation-delay: -0.16s; }

        @keyframes bounce {
            0%, 80%, 100% { transform: scale(0); }
            40% { transform: scale(1); }
        }

        .status-indicator {
            display: inline-block;
            width: 10px;
            height: 10px;
            border-radius: 50%;
            margin-right: 5px;
        }

        .status-indicator.online { background: #4caf50; }
        .status-indicator.offline { background: #f44336; }
    </style>
</head>
<body>
    <div class="header">
        <h1>AIGoodbye</h1>
        <p class="subtitle">Your Offline AI with Internet Connectivity</p>
    </div>

    <div class="controls">
        <select id="mode-select">
            <option value="hybrid">Hybrid Mode</option>
            <option value="local">Local Only</option>
            <option value="internet">Internet Only</option>
        </select>
        <button id="clear-btn">Clear Chat</button>
        <button id="status-btn">
            <span id="status-indicator" class="status-indicator offline"></span>
            Status
        </button>
    </div>

    <div class="chat-container" id="chat-container">
        <div class="message assistant">
            <p>Hello! I'm AIGoodbye, your local AI assistant. I can work offline and connect to the internet when needed.</p>
            <p style="margin-top: 10px;">Try asking me anything!</p>
        </div>
    </div>

    <div class="input-container">
        <input type="text" id="message-input" placeholder="Type your message..." autocomplete="off">
        <button id="send-button">Send</button>
    </div>

    <script>
        const chatContainer = document.getElementById('chat-container');
        const messageInput = document.getElementById('message-input');
        const sendButton = document.getElementById('send-button');
        const modeSelect = document.getElementById('mode-select');
        const clearBtn = document.getElementById('clear-btn');
        const statusBtn = document.getElementById('status-btn');
        const statusIndicator = document.getElementById('status-indicator');

        let ws = null;

        function connectWebSocket() {
            const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
            ws = new WebSocket(`${protocol}//${window.location.host}/ws/chat`);

            ws.onopen = () => {
                statusIndicator.className = 'status-indicator online';
            };

            ws.onclose = () => {
                statusIndicator.className = 'status-indicator offline';
                setTimeout(connectWebSocket, 3000);
            };

            ws.onmessage = (event) => {
                const data = JSON.parse(event.data);
                if (data.chunk) {
                    appendToLastMessage(data.chunk);
                }
                if (data.done) {
                    sendButton.disabled = false;
                }
            };
        }

        function addMessage(content, isUser = false, source = '') {
            const msgDiv = document.createElement('div');
            msgDiv.className = `message ${isUser ? 'user' : 'assistant'}`;
            msgDiv.innerHTML = `<p>${content}</p>`;
            if (source) {
                msgDiv.innerHTML += `<div class="source">${source}</div>`;
            }
            chatContainer.appendChild(msgDiv);
            chatContainer.scrollTop = chatContainer.scrollHeight;
            return msgDiv;
        }

        function appendToLastMessage(chunk) {
            const messages = chatContainer.querySelectorAll('.message.assistant');
            const lastMsg = messages[messages.length - 1];
            if (lastMsg) {
                const p = lastMsg.querySelector('p');
                p.textContent += chunk;
                chatContainer.scrollTop = chatContainer.scrollHeight;
            }
        }

        async function sendMessage() {
            const message = messageInput.value.trim();
            if (!message) return;

            addMessage(message, true);
            messageInput.value = '';
            sendButton.disabled = true;

            // Add empty assistant message for streaming
            addMessage('');

            if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({
                    message: message,
                    use_knowledge_base: true
                }));
            } else {
                // Fallback to REST API
                try {
                    const response = await fetch('/api/chat', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({
                            message: message,
                            mode: modeSelect.value,
                            use_knowledge_base: true
                        })
                    });
                    const data = await response.json();
                    const messages = chatContainer.querySelectorAll('.message.assistant');
                    const lastMsg = messages[messages.length - 1];
                    lastMsg.innerHTML = `<p>${data.content}</p><div class="source">${data.source} - ${data.tokens_used} tokens</div>`;
                } catch (error) {
                    addMessage(`Error: ${error.message}`);
                }
                sendButton.disabled = false;
            }
        }

        messageInput.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') sendMessage();
        });

        sendButton.addEventListener('click', sendMessage);

        modeSelect.addEventListener('change', async () => {
            await fetch(`/api/mode/${modeSelect.value}`, { method: 'POST' });
        });

        clearBtn.addEventListener('click', async () => {
            await fetch('/api/clear', { method: 'POST' });
            chatContainer.innerHTML = '';
            addMessage('Chat cleared. How can I help you?');
        });

        statusBtn.addEventListener('click', async () => {
            const response = await fetch('/api/status');
            const status = await response.json();
            alert(JSON.stringify(status, null, 2));
        });

        connectWebSocket();
    </script>
</body>
</html>
    """
