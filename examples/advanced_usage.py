#!/usr/bin/env python3
"""
Advanced usage example for Banana AI.

This script demonstrates advanced features including:
- Knowledge base management
- Training custom models
- Internet connectivity
- Different AI modes
"""

import asyncio
import json
from banana_ai import BananaAI, Config
from banana_ai.core.engine import AIMode


async def knowledge_base_example(ai: BananaAI):
    """Demonstrate knowledge base features."""
    print("\n=== Knowledge Base Example ===\n")

    # Add some documents
    documents = [
        "Banana AI is a local AI system that can work offline.",
        "The system supports multiple models through Ollama.",
        "You can train custom models using LoRA fine-tuning.",
        "Internet connectivity allows access to ChatGPT and Claude.",
    ]

    for doc in documents:
        await ai.add_document(doc)
    print(f"Added {len(documents)} documents to knowledge base")

    # Search the knowledge base
    results = await ai.knowledge_base.search("How does training work?", top_k=2)
    print(f"\nSearch results for 'How does training work?':")
    for i, result in enumerate(results, 1):
        print(f"  {i}. {result[:100]}...")

    # Chat with knowledge base context
    response = await ai.chat("What are the main features of this system?")
    print(f"\nAI (with KB context): {response.content}")


async def training_example(ai: BananaAI):
    """Demonstrate training/simple task creation."""
    print("\n=== Training Example ===\n")

    # Create a simple task (no GPU required)
    from banana_ai.training.trainer import SimpleTrainer

    simple_trainer = SimpleTrainer(ai.config)

    # Create a translation task
    task = await simple_trainer.create_task(
        task_name="spanish-translator",
        description="Translate English to Spanish",
        examples=[
            {"input": "Hello", "output": "Hola"},
            {"input": "Goodbye", "output": "Adiós"},
            {"input": "Thank you", "output": "Gracias"},
            {"input": "Please", "output": "Por favor"},
            {"input": "How are you?", "output": "¿Cómo estás?"},
        ],
        system_prompt="You are a translator. Translate the given English text to Spanish.",
    )

    print(f"Created task: {task['name']}")
    print(f"Examples: {len(task['examples'])}")

    # Build a prompt with the task
    prompt = simple_trainer.build_prompt(task, "Good morning")
    print(f"\nGenerated prompt:\n{prompt[:200]}...")


async def internet_example(ai: BananaAI):
    """Demonstrate internet connectivity features."""
    print("\n=== Internet Connectivity Example ===\n")

    # Check if APIs are configured
    status = await ai.check_status()

    if status["internet"]["openai"]:
        print("Querying ChatGPT...")
        try:
            response = await ai.ask_chatgpt("What is 2+2? Reply in one word.")
            print(f"ChatGPT: {response.content}")
        except Exception as e:
            print(f"ChatGPT error: {e}")
    else:
        print("OpenAI not configured (set BANANA_OPENAI_API_KEY)")

    if status["internet"]["anthropic"]:
        print("\nQuerying Claude...")
        try:
            response = await ai.ask_claude("What is 2+2? Reply in one word.")
            print(f"Claude: {response.content}")
        except Exception as e:
            print(f"Claude error: {e}")
    else:
        print("Anthropic not configured (set BANANA_ANTHROPIC_API_KEY)")


async def mode_example(ai: BananaAI):
    """Demonstrate different AI modes."""
    print("\n=== AI Modes Example ===\n")

    question = "What is the meaning of life?"

    # Local mode
    print("Testing LOCAL mode...")
    ai.set_mode(AIMode.LOCAL)
    try:
        response = await ai.chat(question)
        print(f"Local: {response.content[:100]}...")
    except Exception as e:
        print(f"Local failed: {e}")

    ai.clear_history()

    # Hybrid mode (default)
    print("\nTesting HYBRID mode...")
    ai.set_mode(AIMode.HYBRID)
    try:
        response = await ai.chat(question)
        print(f"Hybrid ({response.source}): {response.content[:100]}...")
    except Exception as e:
        print(f"Hybrid failed: {e}")


async def main():
    # Initialize
    config = Config()
    ai = BananaAI(config)

    print("=== Banana AI Advanced Examples ===")

    # Run examples
    await knowledge_base_example(ai)
    await training_example(ai)
    await internet_example(ai)
    await mode_example(ai)

    print("\n=== Examples Complete ===")


if __name__ == "__main__":
    asyncio.run(main())
