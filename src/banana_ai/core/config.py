"""Configuration management for Banana AI."""

import os
from pathlib import Path
from typing import Optional

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Config(BaseSettings):
    """Main configuration for Banana AI."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        env_prefix="BANANA_",
        extra="ignore",
    )

    # Paths
    data_dir: Path = Field(default=Path("./data"), description="Directory for data storage")
    models_dir: Path = Field(default=Path("./models"), description="Directory for saved models")
    cache_dir: Path = Field(default=Path("./cache"), description="Directory for cache")

    # Local AI Settings
    local_model_name: str = Field(
        default="llama3.2:3b",
        description="Default local model to use with Ollama",
    )
    ollama_host: str = Field(
        default="http://localhost:11434",
        description="Ollama server address",
    )
    use_gpu: bool = Field(default=True, description="Use GPU acceleration if available")
    max_context_length: int = Field(default=4096, description="Maximum context length")

    # Internet Mode
    internet_enabled: bool = Field(
        default=True,
        description="Enable internet connectivity for external AI services",
    )
    prefer_local: bool = Field(
        default=True,
        description="Prefer local model over internet when possible",
    )

    # API Keys (for internet mode)
    openai_api_key: Optional[str] = Field(default=None, description="OpenAI API key for ChatGPT")
    anthropic_api_key: Optional[str] = Field(default=None, description="Anthropic API key for Claude")
    google_api_key: Optional[str] = Field(default=None, description="Google API key")
    google_cse_id: Optional[str] = Field(default=None, description="Google Custom Search Engine ID")

    # Training Settings
    training_batch_size: int = Field(default=4, description="Batch size for training")
    training_epochs: int = Field(default=3, description="Number of training epochs")
    learning_rate: float = Field(default=2e-4, description="Learning rate for training")
    lora_rank: int = Field(default=16, description="LoRA rank for fine-tuning")
    lora_alpha: int = Field(default=32, description="LoRA alpha for fine-tuning")

    # Vector Store (for RAG)
    vector_store_path: Path = Field(
        default=Path("./data/vectorstore"),
        description="Path to vector store",
    )
    embedding_model: str = Field(
        default="all-MiniLM-L6-v2",
        description="Embedding model for vector store",
    )

    # Server Settings
    server_host: str = Field(default="127.0.0.1", description="Server host")
    server_port: int = Field(default=8000, description="Server port")

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._ensure_directories()

    def _ensure_directories(self):
        """Create necessary directories if they don't exist."""
        for path in [self.data_dir, self.models_dir, self.cache_dir, self.vector_store_path]:
            path.mkdir(parents=True, exist_ok=True)

    @classmethod
    def from_env(cls) -> "Config":
        """Load configuration from environment variables."""
        return cls()

    def has_openai(self) -> bool:
        """Check if OpenAI API is configured."""
        return self.openai_api_key is not None and len(self.openai_api_key) > 0

    def has_anthropic(self) -> bool:
        """Check if Anthropic API is configured."""
        return self.anthropic_api_key is not None and len(self.anthropic_api_key) > 0

    def has_google(self) -> bool:
        """Check if Google API is configured."""
        return (
            self.google_api_key is not None
            and len(self.google_api_key) > 0
            and self.google_cse_id is not None
        )
