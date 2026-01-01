#!/usr/bin/env python3
"""
Simple usage example for Banana AI.

This script demonstrates the basic features of Banana AI.
"""

import asyncio
from banana_ai import BananaAI, Config


async def main():
    # Initialize with default config
    config = Config()
    ai = BananaAI(config)

    print("=== Banana AI Simple Example ===\n")

    # Check status
    status = await ai.check_status()
    print(f"Mode: {status['mode']}")
    print(f"Local AI available: {status['local']['available']}")
    print(f"Internet enabled: {status['internet']['enabled']}\n")

    # Simple chat
    print("--- Simple Chat ---")
    response = await ai.chat("Hello! What can you do?")
    print(f"AI: {response.content}")
    print(f"Source: {response.source}, Tokens: {response.tokens_used}\n")

    # Follow-up (uses conversation history)
    print("--- Follow-up Question ---")
    response = await ai.chat("Can you give me an example?")
    print(f"AI: {response.content}\n")

    # Streaming response
    print("--- Streaming Response ---")
    print("AI: ", end="", flush=True)
    stream = await ai.chat("Tell me a very short story about a robot.", stream=True)
    async for chunk in stream:
        print(chunk, end="", flush=True)
    print("\n")

    # Clear history and set system prompt
    ai.clear_history()
    ai.set_system_prompt("You are a helpful coding assistant. Always provide code examples.")

    print("--- With System Prompt ---")
    response = await ai.chat("How do I read a file in Python?")
    print(f"AI: {response.content}\n")


if __name__ == "__main__":
    asyncio.run(main())
