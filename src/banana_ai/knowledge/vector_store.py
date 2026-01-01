"""
Knowledge Base - Vector store for document retrieval.

Provides RAG (Retrieval Augmented Generation) capabilities
to enhance AI responses with your own documents.
"""

import hashlib
import json
from pathlib import Path
from typing import Optional

from banana_ai.core.config import Config


class KnowledgeBase:
    """
    Vector-based knowledge base for document storage and retrieval.

    Uses ChromaDB for efficient similarity search.
    """

    def __init__(self, config: Config):
        """Initialize the knowledge base."""
        self.config = config
        self.store_path = config.vector_store_path
        self._collection = None
        self._client = None

    @property
    def client(self):
        """Lazy-load ChromaDB client."""
        if self._client is None:
            try:
                import chromadb
                from chromadb.config import Settings

                self._client = chromadb.Client(
                    Settings(
                        chroma_db_impl="duckdb+parquet",
                        persist_directory=str(self.store_path),
                        anonymized_telemetry=False,
                    )
                )
            except ImportError:
                raise RuntimeError(
                    "Knowledge base requires chromadb. Install with: pip install chromadb"
                )
        return self._client

    @property
    def collection(self):
        """Get or create the main collection."""
        if self._collection is None:
            self._collection = self.client.get_or_create_collection(
                name="banana_knowledge",
                metadata={"description": "Banana AI Knowledge Base"},
            )
        return self._collection

    def _generate_id(self, content: str) -> str:
        """Generate a unique ID for content."""
        return hashlib.md5(content.encode()).hexdigest()

    async def add_document(
        self,
        content: str,
        metadata: Optional[dict] = None,
        doc_id: Optional[str] = None,
    ):
        """
        Add a document to the knowledge base.

        Args:
            content: The document content
            metadata: Optional metadata (source, date, etc.)
            doc_id: Optional custom document ID
        """
        doc_id = doc_id or self._generate_id(content)
        metadata = metadata or {}

        self.collection.add(
            documents=[content],
            metadatas=[metadata],
            ids=[doc_id],
        )

    async def add_documents(
        self,
        documents: list[str],
        metadatas: Optional[list[dict]] = None,
    ):
        """
        Add multiple documents to the knowledge base.

        Args:
            documents: List of document contents
            metadatas: Optional list of metadata dicts
        """
        ids = [self._generate_id(doc) for doc in documents]
        metadatas = metadatas or [{} for _ in documents]

        self.collection.add(
            documents=documents,
            metadatas=metadatas,
            ids=ids,
        )

    async def add_file(self, file_path: str, chunk_size: int = 1000):
        """
        Add a file to the knowledge base.

        Automatically chunks large files for better retrieval.

        Args:
            file_path: Path to the file
            chunk_size: Size of chunks in characters
        """
        path = Path(file_path)
        if not path.exists():
            raise FileNotFoundError(f"File not found: {file_path}")

        # Read file content
        content = path.read_text(encoding="utf-8", errors="ignore")

        # Chunk the content
        chunks = self._chunk_text(content, chunk_size)

        # Add each chunk
        for i, chunk in enumerate(chunks):
            metadata = {
                "source": str(path),
                "filename": path.name,
                "chunk_index": i,
                "total_chunks": len(chunks),
            }
            await self.add_document(chunk, metadata)

    def _chunk_text(self, text: str, chunk_size: int) -> list[str]:
        """Split text into chunks, trying to preserve sentences."""
        chunks = []
        current_chunk = ""

        sentences = text.replace("\n", " ").split(". ")

        for sentence in sentences:
            if len(current_chunk) + len(sentence) > chunk_size:
                if current_chunk:
                    chunks.append(current_chunk.strip())
                current_chunk = sentence
            else:
                current_chunk += ". " + sentence if current_chunk else sentence

        if current_chunk:
            chunks.append(current_chunk.strip())

        return chunks

    async def search(
        self,
        query: str,
        top_k: int = 5,
        filter_metadata: Optional[dict] = None,
    ) -> list[str]:
        """
        Search the knowledge base for relevant documents.

        Args:
            query: Search query
            top_k: Number of results to return
            filter_metadata: Optional metadata filter

        Returns:
            List of relevant document contents
        """
        results = self.collection.query(
            query_texts=[query],
            n_results=top_k,
            where=filter_metadata,
        )

        return results.get("documents", [[]])[0]

    async def search_with_metadata(
        self,
        query: str,
        top_k: int = 5,
    ) -> list[dict]:
        """
        Search and return documents with their metadata.

        Args:
            query: Search query
            top_k: Number of results

        Returns:
            List of dicts with 'content' and 'metadata'
        """
        results = self.collection.query(
            query_texts=[query],
            n_results=top_k,
        )

        documents = results.get("documents", [[]])[0]
        metadatas = results.get("metadatas", [[]])[0]

        return [
            {"content": doc, "metadata": meta} for doc, meta in zip(documents, metadatas)
        ]

    async def delete_document(self, doc_id: str):
        """Delete a document by ID."""
        self.collection.delete(ids=[doc_id])

    async def clear(self):
        """Clear all documents from the knowledge base."""
        self.client.delete_collection("banana_knowledge")
        self._collection = None

    async def get_stats(self) -> dict:
        """Get statistics about the knowledge base."""
        return {
            "total_documents": self.collection.count(),
            "storage_path": str(self.store_path),
        }


class SimpleKnowledgeBase:
    """
    Simple file-based knowledge base without vector embeddings.

    Useful when you don't have ChromaDB or want simpler storage.
    Uses keyword matching for retrieval.
    """

    def __init__(self, config: Config):
        """Initialize simple knowledge base."""
        self.config = config
        self.data_file = config.data_dir / "knowledge.json"
        self._documents: list[dict] = []
        self._load()

    def _load(self):
        """Load documents from file."""
        if self.data_file.exists():
            with open(self.data_file) as f:
                self._documents = json.load(f)

    def _save(self):
        """Save documents to file."""
        with open(self.data_file, "w") as f:
            json.dump(self._documents, f, indent=2)

    async def add_document(self, content: str, metadata: Optional[dict] = None):
        """Add a document."""
        self._documents.append(
            {
                "content": content,
                "metadata": metadata or {},
            }
        )
        self._save()

    async def search(self, query: str, top_k: int = 5) -> list[str]:
        """Search using simple keyword matching."""
        query_words = set(query.lower().split())

        scored = []
        for doc in self._documents:
            content_words = set(doc["content"].lower().split())
            score = len(query_words & content_words)
            if score > 0:
                scored.append((score, doc["content"]))

        scored.sort(key=lambda x: x[0], reverse=True)
        return [doc for _, doc in scored[:top_k]]
