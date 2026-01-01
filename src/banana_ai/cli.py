"""
Banana AI Command Line Interface.

Provides an interactive terminal for chatting with your AI,
managing the knowledge base, and training custom models.
"""

import asyncio
import sys
from pathlib import Path
from typing import Optional

import click
from rich.console import Console
from rich.live import Live
from rich.markdown import Markdown
from rich.panel import Panel
from rich.prompt import Prompt
from rich.table import Table

from banana_ai.core.config import Config
from banana_ai.core.engine import AIMode, BananaAI

console = Console()


def run_async(coro):
    """Run async function in sync context."""
    return asyncio.get_event_loop().run_until_complete(coro)


@click.group(invoke_without_command=True)
@click.pass_context
@click.option("--config", "-c", type=click.Path(), help="Path to config file")
def main(ctx, config):
    """Banana AI - Your Offline AI with Internet Connectivity"""
    ctx.ensure_object(dict)

    if config:
        import os

        os.environ["BANANA_CONFIG"] = config

    ctx.obj["config"] = Config()

    if ctx.invoked_subcommand is None:
        # Default to chat mode
        ctx.invoke(chat)


@main.command()
@click.option("--mode", type=click.Choice(["local", "internet", "hybrid"]), default="hybrid")
@click.option("--model", "-m", help="Model to use")
@click.option("--stream/--no-stream", default=True, help="Stream responses")
@click.pass_context
def chat(ctx, mode, model, stream):
    """Start an interactive chat session."""
    config = ctx.obj["config"]
    if model:
        config.local_model_name = model

    ai = BananaAI(config)
    ai.set_mode(AIMode(mode))

    console.print(
        Panel.fit(
            "[bold green]Banana AI[/bold green] - Interactive Chat\n"
            f"Mode: [cyan]{mode}[/cyan] | Model: [cyan]{config.local_model_name}[/cyan]\n"
            "Type [bold]/help[/bold] for commands, [bold]/quit[/bold] to exit",
            title="Welcome",
        )
    )

    async def chat_loop():
        while True:
            try:
                user_input = Prompt.ask("\n[bold blue]You[/bold blue]")

                if not user_input.strip():
                    continue

                # Handle commands
                if user_input.startswith("/"):
                    cmd = user_input[1:].lower().split()[0]

                    if cmd in ("quit", "exit", "q"):
                        console.print("[yellow]Goodbye![/yellow]")
                        break
                    elif cmd == "help":
                        show_help()
                        continue
                    elif cmd == "clear":
                        ai.clear_history()
                        console.print("[green]Conversation cleared[/green]")
                        continue
                    elif cmd == "status":
                        status = await ai.check_status()
                        show_status(status)
                        continue
                    elif cmd == "mode":
                        parts = user_input.split()
                        if len(parts) > 1:
                            new_mode = parts[1]
                            if new_mode in ("local", "internet", "hybrid"):
                                ai.set_mode(AIMode(new_mode))
                                console.print(f"[green]Mode set to: {new_mode}[/green]")
                            else:
                                console.print("[red]Invalid mode. Use: local, internet, hybrid[/red]")
                        else:
                            console.print(f"[cyan]Current mode: {ai.mode.value}[/cyan]")
                        continue
                    elif cmd == "system":
                        prompt = " ".join(user_input.split()[1:])
                        if prompt:
                            ai.set_system_prompt(prompt)
                            console.print("[green]System prompt set[/green]")
                        else:
                            console.print("[red]Usage: /system <prompt>[/red]")
                        continue
                    elif cmd == "search":
                        query = " ".join(user_input.split()[1:])
                        if query:
                            await handle_search(ai, query)
                        else:
                            console.print("[red]Usage: /search <query>[/red]")
                        continue
                    elif cmd in ("chatgpt", "gpt"):
                        message = " ".join(user_input.split()[1:])
                        if message:
                            await handle_chatgpt(ai, message)
                        else:
                            console.print("[red]Usage: /chatgpt <message>[/red]")
                        continue
                    elif cmd == "claude":
                        message = " ".join(user_input.split()[1:])
                        if message:
                            await handle_claude(ai, message)
                        else:
                            console.print("[red]Usage: /claude <message>[/red]")
                        continue
                    else:
                        console.print(f"[red]Unknown command: {cmd}[/red]")
                        continue

                # Regular chat
                console.print("\n[bold green]AI[/bold green]: ", end="")

                if stream:
                    response_gen = await ai.chat(user_input, stream=True)
                    full_response = ""
                    async for chunk in response_gen:
                        console.print(chunk, end="")
                        full_response += chunk
                    console.print()
                else:
                    response = await ai.chat(user_input)
                    console.print(Markdown(response.content))
                    console.print(f"\n[dim]({response.source} - {response.tokens_used} tokens)[/dim]")

            except KeyboardInterrupt:
                console.print("\n[yellow]Use /quit to exit[/yellow]")
            except Exception as e:
                console.print(f"[red]Error: {e}[/red]")

    run_async(chat_loop())


def show_help():
    """Display help information."""
    table = Table(title="Available Commands")
    table.add_column("Command", style="cyan")
    table.add_column("Description")

    commands = [
        ("/help", "Show this help message"),
        ("/quit", "Exit the chat"),
        ("/clear", "Clear conversation history"),
        ("/status", "Show AI status"),
        ("/mode <mode>", "Set mode (local/internet/hybrid)"),
        ("/system <prompt>", "Set system prompt"),
        ("/search <query>", "Search the web"),
        ("/chatgpt <msg>", "Query ChatGPT directly"),
        ("/claude <msg>", "Query Claude directly"),
    ]

    for cmd, desc in commands:
        table.add_row(cmd, desc)

    console.print(table)


def show_status(status: dict):
    """Display AI status."""
    table = Table(title="AI Status")
    table.add_column("Component", style="cyan")
    table.add_column("Status")

    table.add_row("Mode", status["mode"])
    table.add_row(
        "Local AI",
        f"[green]Available[/green] ({status['local']['model']})"
        if status["local"]["available"]
        else "[red]Not Available[/red]",
    )
    table.add_row(
        "Internet",
        "[green]Enabled[/green]" if status["internet"]["enabled"] else "[red]Disabled[/red]",
    )
    table.add_row(
        "OpenAI",
        "[green]Configured[/green]" if status["internet"]["openai"] else "[dim]Not Configured[/dim]",
    )
    table.add_row(
        "Anthropic",
        "[green]Configured[/green]"
        if status["internet"]["anthropic"]
        else "[dim]Not Configured[/dim]",
    )
    table.add_row(
        "Google",
        "[green]Configured[/green]" if status["internet"]["google"] else "[dim]Not Configured[/dim]",
    )

    console.print(table)


async def handle_search(ai: BananaAI, query: str):
    """Handle web search."""
    console.print(f"[dim]Searching for: {query}[/dim]")
    try:
        results = await ai.search_web(query)
        if results:
            for i, result in enumerate(results, 1):
                console.print(f"\n[bold]{i}. {result.get('title', 'No title')}[/bold]")
                console.print(f"   [link]{result.get('link', '')}[/link]")
                if result.get("snippet"):
                    console.print(f"   [dim]{result['snippet']}[/dim]")
        else:
            console.print("[yellow]No results found[/yellow]")
    except Exception as e:
        console.print(f"[red]Search error: {e}[/red]")


async def handle_chatgpt(ai: BananaAI, message: str):
    """Handle direct ChatGPT query."""
    console.print("[dim]Querying ChatGPT...[/dim]")
    try:
        response = await ai.ask_chatgpt(message)
        console.print(f"\n[bold green]ChatGPT[/bold green]: {response.content}")
        console.print(f"[dim]({response.tokens_used} tokens)[/dim]")
    except Exception as e:
        console.print(f"[red]ChatGPT error: {e}[/red]")


async def handle_claude(ai: BananaAI, message: str):
    """Handle direct Claude query."""
    console.print("[dim]Querying Claude...[/dim]")
    try:
        response = await ai.ask_claude(message)
        console.print(f"\n[bold purple]Claude[/bold purple]: {response.content}")
        console.print(f"[dim]({response.tokens_used} tokens)[/dim]")
    except Exception as e:
        console.print(f"[red]Claude error: {e}[/red]")


@main.command()
@click.pass_context
def status(ctx):
    """Check AI system status."""
    config = ctx.obj["config"]
    ai = BananaAI(config)

    async def check():
        s = await ai.check_status()
        show_status(s)

    run_async(check())


@main.command()
@click.option("--model", "-m", default="llama3.2:3b", help="Model to pull")
def pull(model):
    """Pull/download a model for local use."""
    from banana_ai.local.ollama_engine import OllamaEngine

    config = Config()
    engine = OllamaEngine(config)

    console.print(f"[yellow]Pulling model: {model}[/yellow]")
    console.print("[dim]This may take a while...[/dim]")

    async def do_pull():
        success = await engine.pull_model(model)
        if success:
            console.print(f"[green]Successfully pulled: {model}[/green]")
        else:
            console.print(f"[red]Failed to pull: {model}[/red]")

    run_async(do_pull())


@main.command()
def models():
    """List available local models."""
    from banana_ai.local.ollama_engine import OllamaEngine

    config = Config()
    engine = OllamaEngine(config)

    async def list_models():
        available = await engine.list_models()
        if available:
            console.print("\n[bold]Available Models:[/bold]")
            for model in available:
                console.print(f"  - {model}")
        else:
            console.print("[yellow]No models found. Use 'banana pull <model>' to download.[/yellow]")

    run_async(list_models())


# Knowledge Base Commands
@main.group()
def kb():
    """Knowledge base management commands."""
    pass


@kb.command("add")
@click.argument("file_path", type=click.Path(exists=True))
@click.pass_context
def kb_add(ctx, file_path):
    """Add a file to the knowledge base."""
    config = ctx.obj["config"]
    ai = BananaAI(config)

    async def add_file():
        console.print(f"[yellow]Adding file: {file_path}[/yellow]")
        await ai.add_file(file_path)
        console.print("[green]File added successfully[/green]")

    run_async(add_file())


@kb.command("search")
@click.argument("query")
@click.option("--top", "-n", default=5, help="Number of results")
@click.pass_context
def kb_search(ctx, query, top):
    """Search the knowledge base."""
    config = ctx.obj["config"]
    ai = BananaAI(config)

    async def search():
        results = await ai.knowledge_base.search(query, top_k=top)
        if results:
            console.print(f"\n[bold]Found {len(results)} results:[/bold]\n")
            for i, doc in enumerate(results, 1):
                console.print(f"[cyan]{i}.[/cyan] {doc[:200]}...")
        else:
            console.print("[yellow]No results found[/yellow]")

    run_async(search())


@kb.command("stats")
@click.pass_context
def kb_stats(ctx):
    """Show knowledge base statistics."""
    config = ctx.obj["config"]
    ai = BananaAI(config)

    async def show_stats():
        stats = await ai.knowledge_base.get_stats()
        console.print(f"\n[bold]Knowledge Base Stats:[/bold]")
        console.print(f"  Documents: {stats['total_documents']}")
        console.print(f"  Storage: {stats['storage_path']}")

    run_async(show_stats())


# Training Commands
@main.group()
def train():
    """Training and fine-tuning commands."""
    pass


@train.command("task")
@click.argument("name")
@click.argument("data_file", type=click.Path(exists=True))
@click.option("--base-model", default="meta-llama/Llama-3.2-3B", help="Base model")
@click.pass_context
def train_task(ctx, name, data_file, base_model):
    """Train a model for a specific task."""
    import json

    config = ctx.obj["config"]
    ai = BananaAI(config)

    with open(data_file) as f:
        training_data = json.load(f)

    console.print(f"[yellow]Training task: {name}[/yellow]")
    console.print(f"[dim]Examples: {len(training_data)} | Base: {base_model}[/dim]")

    async def do_train():
        result = await ai.train(
            training_data=training_data,
            task_name=name,
            base_model=base_model,
        )
        if result["success"]:
            console.print(f"[green]Training complete![/green]")
            console.print(f"Model saved to: {result['model_path']}")
        else:
            console.print("[red]Training failed[/red]")

    run_async(do_train())


@train.command("list")
@click.pass_context
def train_list(ctx):
    """List trained models."""
    config = ctx.obj["config"]
    ai = BananaAI(config)

    async def list_trained():
        models = await ai.trainer.list_trained_models()
        if models:
            table = Table(title="Trained Models")
            table.add_column("Task", style="cyan")
            table.add_column("Base Model")
            table.add_column("Samples")
            table.add_column("Trained At")

            for m in models:
                table.add_row(
                    m["task_name"],
                    m["base_model"],
                    str(m["training_samples"]),
                    m["trained_at"][:10],
                )
            console.print(table)
        else:
            console.print("[yellow]No trained models found[/yellow]")

    run_async(list_trained())


@main.command()
@click.option("--host", default="127.0.0.1", help="Server host")
@click.option("--port", default=8000, help="Server port")
@click.pass_context
def serve(ctx, host, port):
    """Start the web server."""
    console.print(f"[green]Starting Banana AI server at http://{host}:{port}[/green]")

    import uvicorn

    from banana_ai.web.app import create_app

    config = ctx.obj["config"]
    config.server_host = host
    config.server_port = port

    app = create_app(config)
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    main(obj={})
