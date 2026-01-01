"""
Ollama Engine - Local LLM integration using Ollama.

Ollama provides an easy way to run open-source LLMs locally.
Supports models like Llama, Mistral, CodeLlama, and more.
"""

import asyncio
from typing import AsyncGenerator, Optional

import httpx

from banana_ai.core.config import Config


class OllamaEngine:
    """
    Engine for running local LLMs via Ollama.

    Ollama must be installed and running on the system.
    Install from: https://ollama.ai
    """

    def __init__(self, config: Config):
        """Initialize the Ollama engine."""
        self.config = config
        self.base_url = config.ollama_host
        self.model = config.local_model_name
        self._client: Optional[httpx.AsyncClient] = None

    @property
    def client(self) -> httpx.AsyncClient:
        """Get or create HTTP client."""
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=120.0)
        return self._client

    async def close(self):
        """Close the HTTP client."""
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    async def is_available(self) -> bool:
        """Check if Ollama is running and the model is available."""
        try:
            response = await self.client.get(f"{self.base_url}/api/tags")
            if response.status_code == 200:
                models = response.json().get("models", [])
                model_names = [m.get("name", "") for m in models]
                # Check if our model is available (with or without tag)
                base_model = self.model.split(":")[0]
                return any(base_model in name for name in model_names)
            return False
        except Exception:
            return False

    async def list_models(self) -> list[str]:
        """List available models in Ollama."""
        try:
            response = await self.client.get(f"{self.base_url}/api/tags")
            if response.status_code == 200:
                models = response.json().get("models", [])
                return [m.get("name", "") for m in models]
            return []
        except Exception:
            return []

    async def pull_model(self, model_name: Optional[str] = None) -> bool:
        """
        Pull/download a model from Ollama registry.

        Args:
            model_name: Model to pull (default: configured model)

        Returns:
            True if successful
        """
        model = model_name or self.model
        try:
            response = await self.client.post(
                f"{self.base_url}/api/pull",
                json={"name": model},
                timeout=None,  # Model downloads can take a while
            )
            return response.status_code == 200
        except Exception as e:
            print(f"Error pulling model: {e}")
            return False

    def _format_messages(self, prompt: str, history: list) -> list[dict]:
        """Format conversation history for Ollama."""
        messages = []

        # Add history
        for msg in history:
            messages.append({"role": msg.role, "content": msg.content})

        # Add current prompt
        messages.append({"role": "user", "content": prompt})

        return messages

    async def generate(
        self,
        prompt: str,
        history: Optional[list] = None,
        system_prompt: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 2048,
    ) -> dict:
        """
        Generate a response from the local model.

        Args:
            prompt: The user's prompt
            history: Conversation history
            system_prompt: Optional system prompt
            temperature: Sampling temperature
            max_tokens: Maximum tokens to generate

        Returns:
            Dict with 'content' and 'tokens' keys
        """
        messages = self._format_messages(prompt, history or [])

        if system_prompt:
            messages.insert(0, {"role": "system", "content": system_prompt})

        try:
            response = await self.client.post(
                f"{self.base_url}/api/chat",
                json={
                    "model": self.model,
                    "messages": messages,
                    "stream": False,
                    "options": {
                        "temperature": temperature,
                        "num_predict": max_tokens,
                        "num_ctx": self.config.max_context_length,
                    },
                },
            )

            if response.status_code == 200:
                data = response.json()
                return {
                    "content": data.get("message", {}).get("content", ""),
                    "tokens": data.get("eval_count", 0) + data.get("prompt_eval_count", 0),
                }
            else:
                raise RuntimeError(f"Ollama error: {response.status_code} - {response.text}")

        except httpx.ConnectError:
            raise RuntimeError(
                "Cannot connect to Ollama. Please ensure Ollama is running.\n"
                "Install from: https://ollama.ai\n"
                "Start with: ollama serve"
            )

    async def stream(
        self,
        prompt: str,
        history: Optional[list] = None,
        system_prompt: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 2048,
    ) -> AsyncGenerator[str, None]:
        """
        Stream a response from the local model.

        Args:
            prompt: The user's prompt
            history: Conversation history
            system_prompt: Optional system prompt
            temperature: Sampling temperature
            max_tokens: Maximum tokens to generate

        Yields:
            Response chunks as they're generated
        """
        messages = self._format_messages(prompt, history or [])

        if system_prompt:
            messages.insert(0, {"role": "system", "content": system_prompt})

        try:
            async with self.client.stream(
                "POST",
                f"{self.base_url}/api/chat",
                json={
                    "model": self.model,
                    "messages": messages,
                    "stream": True,
                    "options": {
                        "temperature": temperature,
                        "num_predict": max_tokens,
                        "num_ctx": self.config.max_context_length,
                    },
                },
            ) as response:
                async for line in response.aiter_lines():
                    if line:
                        import json

                        data = json.loads(line)
                        content = data.get("message", {}).get("content", "")
                        if content:
                            yield content

        except httpx.ConnectError:
            raise RuntimeError(
                "Cannot connect to Ollama. Please ensure Ollama is running.\n"
                "Install from: https://ollama.ai\n"
                "Start with: ollama serve"
            )

    async def embed(self, text: str) -> list[float]:
        """
        Generate embeddings for text.

        Args:
            text: Text to embed

        Returns:
            Embedding vector
        """
        try:
            response = await self.client.post(
                f"{self.base_url}/api/embeddings",
                json={
                    "model": self.model,
                    "prompt": text,
                },
            )

            if response.status_code == 200:
                return response.json().get("embedding", [])
            else:
                raise RuntimeError(f"Embedding error: {response.status_code}")

        except httpx.ConnectError:
            raise RuntimeError("Cannot connect to Ollama for embeddings")
