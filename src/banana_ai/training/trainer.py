"""
Trainer - Fine-tune models for specific tasks using LoRA.

This module provides easy-to-use training capabilities for customizing
local LLMs for your specific use cases.
"""

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Optional

from banana_ai.core.config import Config


class Trainer:
    """
    Trainer for fine-tuning local models.

    Uses LoRA (Low-Rank Adaptation) for efficient fine-tuning
    that requires less memory and time than full fine-tuning.
    """

    def __init__(self, config: Config):
        """Initialize the trainer."""
        self.config = config
        self.models_dir = config.models_dir
        self.device = "cuda" if config.use_gpu else "cpu"

    async def train(
        self,
        training_data: list[dict],
        task_name: str = "custom_task",
        base_model: str = "meta-llama/Llama-3.2-3B",
        epochs: Optional[int] = None,
        batch_size: Optional[int] = None,
        learning_rate: Optional[float] = None,
    ) -> dict:
        """
        Train/fine-tune a model for a specific task.

        Args:
            training_data: List of {"input": str, "output": str} examples
            task_name: Name for this training task
            base_model: Base model to fine-tune
            epochs: Number of training epochs
            batch_size: Batch size for training
            learning_rate: Learning rate

        Returns:
            Training results and model path
        """
        # Use config defaults if not specified
        epochs = epochs or self.config.training_epochs
        batch_size = batch_size or self.config.training_batch_size
        learning_rate = learning_rate or self.config.learning_rate

        # Validate training data
        if not training_data:
            raise ValueError("Training data cannot be empty")

        for i, example in enumerate(training_data):
            if "input" not in example or "output" not in example:
                raise ValueError(f"Example {i} missing 'input' or 'output' key")

        # Create task directory
        task_dir = self.models_dir / task_name
        task_dir.mkdir(parents=True, exist_ok=True)

        # Save training data for reference
        data_path = task_dir / "training_data.json"
        with open(data_path, "w") as f:
            json.dump(training_data, f, indent=2)

        # Import training libraries
        try:
            import torch
            from datasets import Dataset
            from peft import LoraConfig, get_peft_model, TaskType
            from transformers import (
                AutoModelForCausalLM,
                AutoTokenizer,
                TrainingArguments,
                Trainer as HFTrainer,
                DataCollatorForLanguageModeling,
            )
        except ImportError as e:
            raise RuntimeError(
                f"Training requires additional packages: {e}\n"
                "Install with: pip install torch transformers peft datasets"
            )

        print(f"Loading base model: {base_model}")

        # Load tokenizer and model
        tokenizer = AutoTokenizer.from_pretrained(base_model)
        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token

        # Load model with 8-bit quantization for efficiency
        model = AutoModelForCausalLM.from_pretrained(
            base_model,
            torch_dtype=torch.float16 if self.device == "cuda" else torch.float32,
            device_map="auto" if self.device == "cuda" else None,
            load_in_8bit=self.device == "cuda",
        )

        # Configure LoRA
        lora_config = LoraConfig(
            task_type=TaskType.CAUSAL_LM,
            r=self.config.lora_rank,
            lora_alpha=self.config.lora_alpha,
            lora_dropout=0.1,
            target_modules=["q_proj", "v_proj", "k_proj", "o_proj"],
        )

        model = get_peft_model(model, lora_config)
        model.print_trainable_parameters()

        # Prepare dataset
        def format_example(example):
            text = f"### Input:\n{example['input']}\n\n### Output:\n{example['output']}"
            return {"text": text}

        formatted_data = [format_example(ex) for ex in training_data]
        dataset = Dataset.from_list(formatted_data)

        def tokenize_function(examples):
            return tokenizer(
                examples["text"],
                truncation=True,
                max_length=self.config.max_context_length,
                padding="max_length",
            )

        tokenized_dataset = dataset.map(
            tokenize_function,
            batched=True,
            remove_columns=["text"],
        )

        # Training arguments
        training_args = TrainingArguments(
            output_dir=str(task_dir / "checkpoints"),
            num_train_epochs=epochs,
            per_device_train_batch_size=batch_size,
            learning_rate=learning_rate,
            logging_steps=10,
            save_steps=100,
            save_total_limit=2,
            fp16=self.device == "cuda",
            report_to=[],  # Disable wandb by default
        )

        # Data collator
        data_collator = DataCollatorForLanguageModeling(
            tokenizer=tokenizer,
            mlm=False,
        )

        # Train
        print(f"Starting training with {len(training_data)} examples...")
        trainer = HFTrainer(
            model=model,
            args=training_args,
            train_dataset=tokenized_dataset,
            data_collator=data_collator,
        )

        train_result = trainer.train()

        # Save the model
        model_path = task_dir / "model"
        model.save_pretrained(str(model_path))
        tokenizer.save_pretrained(str(model_path))

        # Save training metadata
        metadata = {
            "task_name": task_name,
            "base_model": base_model,
            "training_samples": len(training_data),
            "epochs": epochs,
            "batch_size": batch_size,
            "learning_rate": learning_rate,
            "lora_rank": self.config.lora_rank,
            "lora_alpha": self.config.lora_alpha,
            "trained_at": datetime.now().isoformat(),
            "train_loss": train_result.training_loss,
        }

        with open(task_dir / "metadata.json", "w") as f:
            json.dump(metadata, f, indent=2)

        print(f"Training complete! Model saved to: {model_path}")

        return {
            "success": True,
            "model_path": str(model_path),
            "metadata": metadata,
        }

    async def load_model(self, task_name: str):
        """
        Load a previously trained model.

        Args:
            task_name: Name of the trained task

        Returns:
            Loaded model and tokenizer
        """
        task_dir = self.models_dir / task_name
        model_path = task_dir / "model"

        if not model_path.exists():
            raise ValueError(f"No trained model found for task: {task_name}")

        try:
            import torch
            from peft import PeftModel
            from transformers import AutoModelForCausalLM, AutoTokenizer

            # Load metadata to get base model
            metadata_path = task_dir / "metadata.json"
            with open(metadata_path) as f:
                metadata = json.load(f)

            base_model = metadata["base_model"]

            # Load tokenizer
            tokenizer = AutoTokenizer.from_pretrained(str(model_path))

            # Load base model
            model = AutoModelForCausalLM.from_pretrained(
                base_model,
                torch_dtype=torch.float16 if self.device == "cuda" else torch.float32,
                device_map="auto" if self.device == "cuda" else None,
            )

            # Load LoRA weights
            model = PeftModel.from_pretrained(model, str(model_path))

            return model, tokenizer

        except ImportError as e:
            raise RuntimeError(f"Loading model requires: {e}")

    async def list_trained_models(self) -> list[dict]:
        """List all trained models."""
        models = []
        for task_dir in self.models_dir.iterdir():
            if task_dir.is_dir():
                metadata_path = task_dir / "metadata.json"
                if metadata_path.exists():
                    with open(metadata_path) as f:
                        metadata = json.load(f)
                    models.append(metadata)
        return models

    async def generate_with_trained_model(
        self,
        task_name: str,
        prompt: str,
        max_length: int = 512,
    ) -> str:
        """
        Generate text using a trained model.

        Args:
            task_name: Name of the trained task
            prompt: Input prompt
            max_length: Maximum generation length

        Returns:
            Generated text
        """
        model, tokenizer = await self.load_model(task_name)

        formatted_prompt = f"### Input:\n{prompt}\n\n### Output:\n"
        inputs = tokenizer(formatted_prompt, return_tensors="pt")

        if self.device == "cuda":
            inputs = inputs.to("cuda")

        outputs = model.generate(
            **inputs,
            max_new_tokens=max_length,
            do_sample=True,
            temperature=0.7,
            pad_token_id=tokenizer.pad_token_id,
        )

        response = tokenizer.decode(outputs[0], skip_special_tokens=True)

        # Extract just the output part
        if "### Output:" in response:
            response = response.split("### Output:")[-1].strip()

        return response


class SimpleTrainer:
    """
    Simplified trainer for creating custom prompts and examples.

    This is a lighter-weight option that doesn't require GPU or
    heavy ML libraries. It works by storing examples and using
    them for few-shot learning with the local model.
    """

    def __init__(self, config: Config):
        """Initialize the simple trainer."""
        self.config = config
        self.tasks_dir = config.data_dir / "tasks"
        self.tasks_dir.mkdir(parents=True, exist_ok=True)

    async def create_task(
        self,
        task_name: str,
        description: str,
        examples: list[dict],
        system_prompt: Optional[str] = None,
    ) -> dict:
        """
        Create a task with examples for few-shot learning.

        Args:
            task_name: Name of the task
            description: Description of what the task does
            examples: List of {"input": str, "output": str} examples
            system_prompt: Optional system prompt

        Returns:
            Task configuration
        """
        task = {
            "name": task_name,
            "description": description,
            "system_prompt": system_prompt or f"You are an AI assistant trained for: {description}",
            "examples": examples,
            "created_at": datetime.now().isoformat(),
        }

        task_path = self.tasks_dir / f"{task_name}.json"
        with open(task_path, "w") as f:
            json.dump(task, f, indent=2)

        return task

    async def get_task(self, task_name: str) -> dict:
        """Load a task configuration."""
        task_path = self.tasks_dir / f"{task_name}.json"
        if not task_path.exists():
            raise ValueError(f"Task not found: {task_name}")

        with open(task_path) as f:
            return json.load(f)

    async def list_tasks(self) -> list[str]:
        """List all available tasks."""
        return [p.stem for p in self.tasks_dir.glob("*.json")]

    def build_prompt(self, task: dict, user_input: str) -> str:
        """Build a prompt with few-shot examples."""
        parts = [task["system_prompt"], "", "Here are some examples:", ""]

        for ex in task["examples"]:
            parts.append(f"Input: {ex['input']}")
            parts.append(f"Output: {ex['output']}")
            parts.append("")

        parts.append(f"Input: {user_input}")
        parts.append("Output:")

        return "\n".join(parts)
