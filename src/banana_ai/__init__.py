"""
Banana AI - Your Offline AI with Internet Connectivity

Train and run your own AI locally with the ability to connect to
external services (Google, ChatGPT, Claude) when needed.
"""

__version__ = "1.0.0"
__author__ = "Banana AI Team"

from banana_ai.core.engine import BananaAI
from banana_ai.core.config import Config

__all__ = ["BananaAI", "Config"]
