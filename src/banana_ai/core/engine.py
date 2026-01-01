"""
Main Banana AI Engine - Orchestrates local and remote AI capabilities.
"""

import asyncio
from dataclasses import dataclass, field
from enum import Enum
from typing import AsyncGenerator, Optional

from banana_ai.core.config import Config


class AIMode(Enum):
    """Operating mode for the AI."""

    LOCAL = "local"  # Use only local models
    INTERNET = "internet"  # Use only internet services
    HYBRID = "hybrid"  # Use local first, fallback to internet


@dataclass
class Message:
    """A chat message."""

    role: str  # "user", "assistant", "system"
    content: str
    metadata: dict = field(default_factory=dict)


@dataclass
class AIResponse:
    """Response from the AI."""

    content: str
    source: str  # "local", "openai", "anthropic", "google"
    model: str
    tokens_used: int = 0
    metadata: dict = field(default_factory=dict)


class BananaAI:
    """
    Main AI Engine for Banana AI.

    Provides a unified interface to local and remote AI capabilities.
    """

    def __init__(self, config: Optional[Config] = None):
        """Initialize the Banana AI engine."""
        self.config = config or Config()
        self.mode = AIMode.HYBRID if self.config.internet_enabled else AIMode.LOCAL
        self.conversation_history: list[Message] = []
        self.system_prompt: Optional[str] = None

        # Lazy-loaded components
        self._local_engine = None
        self._internet_connector = None
        self._knowledge_base = None
        self._trainer = None

    @property
    def local_engine(self):
        """Lazy-load local AI engine."""
        if self._local_engine is None:
            from banana_ai.local.ollama_engine import OllamaEngine

            self._local_engine = OllamaEngine(self.config)
        return self._local_engine

    @property
    def internet_connector(self):
        """Lazy-load internet connector."""
        if self._internet_connector is None:
            from banana_ai.internet.connector import InternetConnector

            self._internet_connector = InternetConnector(self.config)
        return self._internet_connector

    @property
    def knowledge_base(self):
        """Lazy-load knowledge base."""
        if self._knowledge_base is None:
            from banana_ai.knowledge.vector_store import KnowledgeBase

            self._knowledge_base = KnowledgeBase(self.config)
        return self._knowledge_base

    @property
    def trainer(self):
        """Lazy-load trainer."""
        if self._trainer is None:
            from banana_ai.training.trainer import Trainer

            self._trainer = Trainer(self.config)
        return self._trainer

    def set_system_prompt(self, prompt: str):
        """Set the system prompt for the AI."""
        self.system_prompt = prompt

    def set_mode(self, mode: AIMode):
        """Set the operating mode."""
        self.mode = mode

    def clear_history(self):
        """Clear conversation history."""
        self.conversation_history = []

    async def chat(
        self,
        message: str,
        use_knowledge_base: bool = True,
        stream: bool = False,
    ) -> AIResponse | AsyncGenerator[str, None]:
        """
        Send a message and get a response.

        Args:
            message: The user's message
            use_knowledge_base: Whether to augment with knowledge base
            stream: Whether to stream the response

        Returns:
            AIResponse or async generator of string chunks if streaming
        """
        # Add user message to history
        self.conversation_history.append(Message(role="user", content=message))

        # Build context
        context = await self._build_context(message, use_knowledge_base)

        # Get response based on mode
        if stream:
            return self._stream_response(context, message)
        else:
            response = await self._get_response(context, message)
            self.conversation_history.append(Message(role="assistant", content=response.content))
            return response

    async def _build_context(self, message: str, use_knowledge_base: bool) -> str:
        """Build context for the AI request."""
        context_parts = []

        # Add system prompt
        if self.system_prompt:
            context_parts.append(f"System: {self.system_prompt}")

        # Add knowledge base context if available
        if use_knowledge_base and self._knowledge_base is not None:
            try:
                relevant_docs = await self.knowledge_base.search(message, top_k=3)
                if relevant_docs:
                    context_parts.append("Relevant knowledge:")
                    for doc in relevant_docs:
                        context_parts.append(f"- {doc}")
            except Exception:
                pass  # Knowledge base not available

        return "\n".join(context_parts) if context_parts else ""

    async def _get_response(self, context: str, message: str) -> AIResponse:
        """Get response from AI based on current mode."""
        if self.mode == AIMode.LOCAL:
            return await self._get_local_response(context, message)
        elif self.mode == AIMode.INTERNET:
            return await self._get_internet_response(context, message)
        else:  # HYBRID
            try:
                # Try local first
                if await self.local_engine.is_available():
                    return await self._get_local_response(context, message)
            except Exception:
                pass

            # Fallback to internet
            if self.config.internet_enabled:
                return await self._get_internet_response(context, message)

            raise RuntimeError("No AI backend available. Please start Ollama or configure API keys.")

    async def _get_local_response(self, context: str, message: str) -> AIResponse:
        """Get response from local AI."""
        full_prompt = f"{context}\n\nUser: {message}" if context else message

        response = await self.local_engine.generate(
            prompt=full_prompt,
            history=self.conversation_history[:-1],  # Exclude current message
        )

        return AIResponse(
            content=response["content"],
            source="local",
            model=self.config.local_model_name,
            tokens_used=response.get("tokens", 0),
        )

    async def _get_internet_response(self, context: str, message: str) -> AIResponse:
        """Get response from internet AI services."""
        full_prompt = f"{context}\n\nUser: {message}" if context else message

        response = await self.internet_connector.generate(
            prompt=full_prompt,
            history=self.conversation_history[:-1],
        )

        return response

    async def _stream_response(self, context: str, message: str) -> AsyncGenerator[str, None]:
        """Stream response from AI."""
        full_prompt = f"{context}\n\nUser: {message}" if context else message
        full_response = ""

        if self.mode in [AIMode.LOCAL, AIMode.HYBRID]:
            try:
                if await self.local_engine.is_available():
                    async for chunk in self.local_engine.stream(
                        prompt=full_prompt,
                        history=self.conversation_history[:-1],
                    ):
                        full_response += chunk
                        yield chunk
                    self.conversation_history.append(
                        Message(role="assistant", content=full_response)
                    )
                    return
            except Exception:
                if self.mode == AIMode.LOCAL:
                    raise

        # Fallback to internet streaming
        if self.config.internet_enabled:
            async for chunk in self.internet_connector.stream(
                prompt=full_prompt,
                history=self.conversation_history[:-1],
            ):
                full_response += chunk
                yield chunk
            self.conversation_history.append(Message(role="assistant", content=full_response))

    async def search_web(self, query: str) -> list[dict]:
        """Search the web for information."""
        if not self.config.internet_enabled:
            raise RuntimeError("Internet mode is disabled")
        return await self.internet_connector.search_google(query)

    async def ask_chatgpt(self, message: str, model: str = "gpt-4") -> AIResponse:
        """Directly query ChatGPT."""
        if not self.config.has_openai():
            raise RuntimeError("OpenAI API key not configured")
        return await self.internet_connector.query_openai(message, model)

    async def ask_claude(self, message: str, model: str = "claude-3-sonnet-20240229") -> AIResponse:
        """Directly query Claude."""
        if not self.config.has_anthropic():
            raise RuntimeError("Anthropic API key not configured")
        return await self.internet_connector.query_anthropic(message, model)

    # Knowledge Base Methods
    async def add_document(self, content: str, metadata: Optional[dict] = None):
        """Add a document to the knowledge base."""
        await self.knowledge_base.add_document(content, metadata)

    async def add_file(self, file_path: str):
        """Add a file to the knowledge base."""
        await self.knowledge_base.add_file(file_path)

    # Training Methods
    async def train(
        self,
        training_data: list[dict],
        task_name: str = "custom_task",
        base_model: str = "meta-llama/Llama-3.2-3B",
    ):
        """
        Train/fine-tune the model for a specific task.

        Args:
            training_data: List of {"input": str, "output": str} examples
            task_name: Name for this training task
            base_model: Base model to fine-tune
        """
        return await self.trainer.train(
            training_data=training_data,
            task_name=task_name,
            base_model=base_model,
        )

    async def load_trained_model(self, task_name: str):
        """Load a previously trained model."""
        return await self.trainer.load_model(task_name)

    # Utility Methods
    async def check_status(self) -> dict:
        """Check the status of all AI backends."""
        status = {
            "mode": self.mode.value,
            "local": {"available": False, "model": None},
            "internet": {
                "enabled": self.config.internet_enabled,
                "openai": self.config.has_openai(),
                "anthropic": self.config.has_anthropic(),
                "google": self.config.has_google(),
            },
            "knowledge_base": {"initialized": self._knowledge_base is not None},
        }

        try:
            if await self.local_engine.is_available():
                status["local"]["available"] = True
                status["local"]["model"] = self.config.local_model_name
        except Exception:
            pass

        return status
