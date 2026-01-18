# -*- mode: python ; coding: utf-8 -*-
"""
PyInstaller spec file for Banana AI Backend

This creates a standalone executable that can be bundled with the Tauri desktop app.
"""

import sys
from pathlib import Path

# Get the project root
project_root = Path('.').parent.resolve()
src_path = project_root / 'src'

a = Analysis(
    [str(src_path / 'banana_ai' / 'cli.py')],
    pathex=[str(src_path)],
    binaries=[],
    datas=[
        # Include any data files needed
        (str(project_root / 'pyproject.toml'), '.'),
    ],
    hiddenimports=[
        'banana_ai',
        'banana_ai.cli',
        'banana_ai.core',
        'banana_ai.core.config',
        'banana_ai.core.engine',
        'banana_ai.web',
        'banana_ai.web.app',
        'banana_ai.local',
        'banana_ai.local.ollama_engine',
        'banana_ai.internet',
        'banana_ai.internet.connector',
        'banana_ai.knowledge',
        'banana_ai.knowledge.vector_store',
        'banana_ai.training',
        'banana_ai.training.trainer',
        # FastAPI and dependencies
        'fastapi',
        'uvicorn',
        'uvicorn.logging',
        'uvicorn.loops',
        'uvicorn.loops.auto',
        'uvicorn.protocols',
        'uvicorn.protocols.http',
        'uvicorn.protocols.http.auto',
        'uvicorn.protocols.websockets',
        'uvicorn.protocols.websockets.auto',
        'uvicorn.lifespan',
        'uvicorn.lifespan.on',
        'starlette',
        'starlette.routing',
        'starlette.middleware',
        'starlette.middleware.cors',
        'pydantic',
        'pydantic_settings',
        # HTTP clients
        'httpx',
        'aiohttp',
        'websockets',
        # AI libraries
        'openai',
        'anthropic',
        'chromadb',
        'ollama',
        # Other dependencies
        'click',
        'rich',
        'rich.console',
        'rich.panel',
        'rich.table',
        'dotenv',
        'yaml',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # Exclude heavy ML libraries for the backend-only build
        # Users will need Ollama separately for local inference
        'torch',
        'transformers',
        'accelerate',
        'peft',
        'bitsandbytes',
        'tensorboard',
        'wandb',
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=None,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=None)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='banana-backend',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,  # Set to False for production if you don't want console window
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon='src-tauri/icons/icon.ico' if sys.platform == 'win32' else 'src-tauri/icons/icon.icns',
)
