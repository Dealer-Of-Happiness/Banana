"""
Internet Connector - Connect to external AI services.

Provides unified access to:
- OpenAI (ChatGPT)
- Anthropic (Claude)
- Google Search
"""

import asyncio
from typing import AsyncGenerator, Optional

import httpx

from banana_ai.core.config import Config
from banana_ai.core.engine import AIResponse


class InternetConnector:
    """
    Unified connector for external AI services.

    Handles authentication and API calls to OpenAI, Anthropic, and Google.
    """

    def __init__(self, config: Config):
        """Initialize the internet connector."""
        self.config = config
        self._client: Optional[httpx.AsyncClient] = None

        # Default models
        self.default_openai_model = "gpt-4o"
        self.default_anthropic_model = "claude-3-5-sonnet-20241022"

        # API endpoints
        self.openai_base = "https://api.openai.com/v1"
        self.anthropic_base = "https://api.anthropic.com/v1"

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

    def _format_messages(self, prompt: str, history: list) -> list[dict]:
        """Format conversation history for API calls."""
        messages = []
        for msg in history:
            messages.append({"role": msg.role, "content": msg.content})
        messages.append({"role": "user", "content": prompt})
        return messages

    # ==================== OpenAI (ChatGPT) ====================

    async def query_openai(
        self,
        prompt: str,
        model: Optional[str] = None,
        history: Optional[list] = None,
        temperature: float = 0.7,
        max_tokens: int = 2048,
    ) -> AIResponse:
        """
        Query OpenAI's ChatGPT.

        Args:
            prompt: The user's prompt
            model: Model to use (default: gpt-4o)
            history: Conversation history
            temperature: Sampling temperature
            max_tokens: Maximum tokens to generate

        Returns:
            AIResponse with the result
        """
        if not self.config.has_openai():
            raise RuntimeError("OpenAI API key not configured. Set BANANA_OPENAI_API_KEY")

        model = model or self.default_openai_model
        messages = self._format_messages(prompt, history or [])

        response = await self.client.post(
            f"{self.openai_base}/chat/completions",
            headers={
                "Authorization": f"Bearer {self.config.openai_api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": model,
                "messages": messages,
                "temperature": temperature,
                "max_tokens": max_tokens,
            },
        )

        if response.status_code == 200:
            data = response.json()
            content = data["choices"][0]["message"]["content"]
            tokens = data.get("usage", {}).get("total_tokens", 0)
            return AIResponse(
                content=content,
                source="openai",
                model=model,
                tokens_used=tokens,
            )
        else:
            raise RuntimeError(f"OpenAI API error: {response.status_code} - {response.text}")

    async def stream_openai(
        self,
        prompt: str,
        model: Optional[str] = None,
        history: Optional[list] = None,
        temperature: float = 0.7,
        max_tokens: int = 2048,
    ) -> AsyncGenerator[str, None]:
        """Stream response from OpenAI."""
        if not self.config.has_openai():
            raise RuntimeError("OpenAI API key not configured")

        model = model or self.default_openai_model
        messages = self._format_messages(prompt, history or [])

        async with self.client.stream(
            "POST",
            f"{self.openai_base}/chat/completions",
            headers={
                "Authorization": f"Bearer {self.config.openai_api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": model,
                "messages": messages,
                "temperature": temperature,
                "max_tokens": max_tokens,
                "stream": True,
            },
        ) as response:
            async for line in response.aiter_lines():
                if line.startswith("data: ") and line != "data: [DONE]":
                    import json

                    data = json.loads(line[6:])
                    content = data["choices"][0].get("delta", {}).get("content", "")
                    if content:
                        yield content

    # ==================== Anthropic (Claude) ====================

    async def query_anthropic(
        self,
        prompt: str,
        model: Optional[str] = None,
        history: Optional[list] = None,
        temperature: float = 0.7,
        max_tokens: int = 2048,
        system_prompt: Optional[str] = None,
    ) -> AIResponse:
        """
        Query Anthropic's Claude.

        Args:
            prompt: The user's prompt
            model: Model to use (default: claude-3-5-sonnet)
            history: Conversation history
            temperature: Sampling temperature
            max_tokens: Maximum tokens to generate
            system_prompt: Optional system prompt

        Returns:
            AIResponse with the result
        """
        if not self.config.has_anthropic():
            raise RuntimeError("Anthropic API key not configured. Set BANANA_ANTHROPIC_API_KEY")

        model = model or self.default_anthropic_model
        messages = self._format_messages(prompt, history or [])

        request_body = {
            "model": model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
        }

        if system_prompt:
            request_body["system"] = system_prompt

        response = await self.client.post(
            f"{self.anthropic_base}/messages",
            headers={
                "x-api-key": self.config.anthropic_api_key,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json",
            },
            json=request_body,
        )

        if response.status_code == 200:
            data = response.json()
            content = data["content"][0]["text"]
            input_tokens = data.get("usage", {}).get("input_tokens", 0)
            output_tokens = data.get("usage", {}).get("output_tokens", 0)
            return AIResponse(
                content=content,
                source="anthropic",
                model=model,
                tokens_used=input_tokens + output_tokens,
            )
        else:
            raise RuntimeError(f"Anthropic API error: {response.status_code} - {response.text}")

    async def stream_anthropic(
        self,
        prompt: str,
        model: Optional[str] = None,
        history: Optional[list] = None,
        temperature: float = 0.7,
        max_tokens: int = 2048,
        system_prompt: Optional[str] = None,
    ) -> AsyncGenerator[str, None]:
        """Stream response from Anthropic Claude."""
        if not self.config.has_anthropic():
            raise RuntimeError("Anthropic API key not configured")

        model = model or self.default_anthropic_model
        messages = self._format_messages(prompt, history or [])

        request_body = {
            "model": model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": True,
        }

        if system_prompt:
            request_body["system"] = system_prompt

        async with self.client.stream(
            "POST",
            f"{self.anthropic_base}/messages",
            headers={
                "x-api-key": self.config.anthropic_api_key,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json",
            },
            json=request_body,
        ) as response:
            async for line in response.aiter_lines():
                if line.startswith("data: "):
                    import json

                    try:
                        data = json.loads(line[6:])
                        if data.get("type") == "content_block_delta":
                            content = data.get("delta", {}).get("text", "")
                            if content:
                                yield content
                    except json.JSONDecodeError:
                        continue

    # ==================== Google Search ====================

    async def search_google(self, query: str, num_results: int = 5) -> list[dict]:
        """
        Search Google for information.

        Args:
            query: Search query
            num_results: Number of results to return

        Returns:
            List of search results with title, link, and snippet
        """
        if not self.config.has_google():
            # Fallback to simple web scraping if no API key
            return await self._search_google_fallback(query, num_results)

        response = await self.client.get(
            "https://www.googleapis.com/customsearch/v1",
            params={
                "key": self.config.google_api_key,
                "cx": self.config.google_cse_id,
                "q": query,
                "num": num_results,
            },
        )

        if response.status_code == 200:
            data = response.json()
            results = []
            for item in data.get("items", []):
                results.append(
                    {
                        "title": item.get("title", ""),
                        "link": item.get("link", ""),
                        "snippet": item.get("snippet", ""),
                    }
                )
            return results
        else:
            raise RuntimeError(f"Google API error: {response.status_code}")

    async def _search_google_fallback(self, query: str, num_results: int = 5) -> list[dict]:
        """Fallback search using googlesearch-python library."""
        try:
            from googlesearch import search

            results = []
            for url in search(query, num_results=num_results):
                results.append(
                    {
                        "title": "",
                        "link": url,
                        "snippet": "",
                    }
                )
            return results
        except ImportError:
            raise RuntimeError(
                "Google search requires either API keys or googlesearch-python package"
            )
        except Exception as e:
            raise RuntimeError(f"Google search error: {e}")

    # ==================== Unified Generate ====================

    async def generate(
        self,
        prompt: str,
        history: Optional[list] = None,
        prefer_provider: Optional[str] = None,
    ) -> AIResponse:
        """
        Generate response using the best available provider.

        Args:
            prompt: The user's prompt
            history: Conversation history
            prefer_provider: Preferred provider ("openai" or "anthropic")

        Returns:
            AIResponse from the selected provider
        """
        providers = []

        # Build provider priority list
        if prefer_provider == "openai" and self.config.has_openai():
            providers.append(("openai", self.query_openai))
        elif prefer_provider == "anthropic" and self.config.has_anthropic():
            providers.append(("anthropic", self.query_anthropic))

        # Add remaining providers
        if self.config.has_anthropic() and prefer_provider != "anthropic":
            providers.append(("anthropic", self.query_anthropic))
        if self.config.has_openai() and prefer_provider != "openai":
            providers.append(("openai", self.query_openai))

        if not providers:
            raise RuntimeError(
                "No internet AI providers configured. "
                "Set BANANA_OPENAI_API_KEY or BANANA_ANTHROPIC_API_KEY"
            )

        # Try providers in order
        last_error = None
        for name, provider in providers:
            try:
                return await provider(prompt, history=history)
            except Exception as e:
                last_error = e
                continue

        raise RuntimeError(f"All providers failed. Last error: {last_error}")

    async def stream(
        self,
        prompt: str,
        history: Optional[list] = None,
        prefer_provider: Optional[str] = None,
    ) -> AsyncGenerator[str, None]:
        """
        Stream response using the best available provider.

        Args:
            prompt: The user's prompt
            history: Conversation history
            prefer_provider: Preferred provider

        Yields:
            Response chunks
        """
        if prefer_provider == "openai" and self.config.has_openai():
            async for chunk in self.stream_openai(prompt, history=history):
                yield chunk
            return

        if self.config.has_anthropic():
            async for chunk in self.stream_anthropic(prompt, history=history):
                yield chunk
            return

        if self.config.has_openai():
            async for chunk in self.stream_openai(prompt, history=history):
                yield chunk
            return

        raise RuntimeError("No streaming providers available")
