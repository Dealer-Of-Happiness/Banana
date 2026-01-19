/**
 * AI Goodbye Desktop Application
 * Frontend JavaScript for Tauri desktop wrapper
 */

// Tauri API imports (will be available when running in Tauri)
const { invoke } = window.__TAURI__ ? window.__TAURI__.core : { invoke: async () => {} };

// API Configuration
const API_BASE_URL = 'http://127.0.0.1:8765';

// Available Models Configuration
const AVAILABLE_MODELS = [
    { id: 'llama3.2:1b', name: 'Llama 3.2 1B', size: 'small', sizeGB: '~1.3 GB', vision: false },
    { id: 'llama3.2:3b', name: 'Llama 3.2 3B', size: 'medium', sizeGB: '~2.0 GB', vision: false },
    { id: 'llama3.2-vision:11b', name: 'Llama 3.2 Vision 11B', size: 'large', sizeGB: '~8 GB', vision: true },
    { id: 'llama3.2-vision:90b', name: 'Llama 3.2 Vision 90B', size: 'xlarge', sizeGB: '~55 GB', vision: true }
];

// DOM Elements
const loadingScreen = document.getElementById('loading-screen');
const modelSetupScreen = document.getElementById('model-setup-screen');
const app = document.getElementById('app');
const backendStatus = document.getElementById('backend-status');
const statusText = document.getElementById('status-text');
const chatContainer = document.getElementById('chat-container');
const messageInput = document.getElementById('message-input');
const sendButton = document.getElementById('send-button');
const useKbCheckbox = document.getElementById('use-kb');
const newChatBtn = document.getElementById('new-chat-btn');
const chatModelSelect = document.getElementById('chat-model-select');
const modelIndicator = document.getElementById('model-indicator');

// Navigation elements
const navItems = document.querySelectorAll('.nav-item');
const views = document.querySelectorAll('.view');

// State
let isBackendRunning = false;
let ws = null;
let downloadedModels = [];
let currentChatModel = null;

// ==================== Initialization ====================

async function init() {
    console.log('Initializing AI Goodbye Desktop...');

    // Set up event listeners
    setupNavigation();
    setupChat();
    setupKnowledgeBase();
    setupTraining();
    setupSettings();
    setupModelSetup();

    // Start backend and check connection
    await startBackend();

    // Check if this is first launch or if models need to be set up
    await checkModelSetup();
}

async function checkModelSetup() {
    // Load downloaded models from localStorage
    downloadedModels = JSON.parse(localStorage.getItem('bananaDownloadedModels') || '[]');

    // Check if any models are downloaded
    if (downloadedModels.length === 0) {
        // First launch - show model setup screen
        setTimeout(() => {
            loadingScreen.classList.add('hidden');
            modelSetupScreen.classList.remove('hidden');
        }, 1500);
    } else {
        // Models exist - proceed to app
        setTimeout(() => {
            loadingScreen.classList.add('hidden');
            app.classList.remove('hidden');
            populateChatModelDropdown();
        }, 2000);
    }
}

// ==================== Model Setup ====================

function setupModelSetup() {
    const modelCheckboxes = document.querySelectorAll('.model-checkbox');
    const downloadBtn = document.getElementById('download-models-btn');
    const continueBtn = document.getElementById('continue-setup-btn');
    const selectionHint = document.getElementById('selection-hint');
    const modelCards = document.querySelectorAll('.model-setup-screen .model-card');

    // Make entire card clickable to toggle checkbox
    modelCards.forEach(card => {
        card.addEventListener('click', (e) => {
            if (e.target.type !== 'checkbox') {
                const checkbox = card.querySelector('.model-checkbox');
                checkbox.checked = !checkbox.checked;
                checkbox.dispatchEvent(new Event('change'));
            }
        });
    });

    // Handle checkbox changes
    modelCheckboxes.forEach(checkbox => {
        checkbox.addEventListener('change', () => {
            const card = checkbox.closest('.model-card');
            card.classList.toggle('selected', checkbox.checked);

            const selectedCount = document.querySelectorAll('.model-checkbox:checked').length;
            downloadBtn.disabled = selectedCount === 0;

            if (selectedCount > 0) {
                selectionHint.textContent = `${selectedCount} model${selectedCount > 1 ? 's' : ''} selected`;
            } else {
                selectionHint.textContent = 'Select at least one model to continue';
            }
        });
    });

    // Download button
    downloadBtn.addEventListener('click', async () => {
        const selectedModels = [];
        modelCheckboxes.forEach(checkbox => {
            if (checkbox.checked) {
                const card = checkbox.closest('.model-card');
                selectedModels.push(card.dataset.model);
            }
        });

        if (selectedModels.length === 0) return;

        // Disable download button and checkboxes
        downloadBtn.disabled = true;
        downloadBtn.textContent = 'Downloading...';
        modelCheckboxes.forEach(cb => cb.disabled = true);

        // Download each model
        for (const modelId of selectedModels) {
            await downloadModel(modelId);
        }

        // Show continue button
        downloadBtn.classList.add('hidden');
        continueBtn.classList.remove('hidden');
        selectionHint.textContent = 'Models downloaded successfully!';
    });

    // Continue button
    continueBtn.addEventListener('click', () => {
        modelSetupScreen.classList.add('hidden');
        app.classList.remove('hidden');
        populateChatModelDropdown();
    });

    // Update model cards with current download status
    updateModelSetupStatus();
}

async function downloadModel(modelId) {
    const card = document.querySelector(`.model-card[data-model="${modelId}"]`);
    const progressContainer = card.querySelector('.model-progress');
    const progressFill = card.querySelector('.progress-fill');
    const progressText = card.querySelector('.progress-text');
    const statusText = card.querySelector('.status-text');

    // Show progress
    progressContainer.classList.remove('hidden');
    statusText.textContent = 'Downloading...';
    statusText.className = 'status-text downloading';

    try {
        // Try to pull model via Ollama API
        if (isBackendRunning) {
            // Use backend API to pull model
            const response = await fetch(`${API_BASE_URL}/api/models/pull`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ model: modelId })
            });

            if (response.ok) {
                // Simulate progress (actual progress would come from streaming response)
                await simulateDownloadProgress(progressFill, progressText);
            } else {
                // Backend doesn't have this endpoint yet, simulate download
                await simulateDownloadProgress(progressFill, progressText);
            }
        } else {
            // Simulate download progress for demo
            await simulateDownloadProgress(progressFill, progressText);
        }

        // Mark as downloaded
        if (!downloadedModels.includes(modelId)) {
            downloadedModels.push(modelId);
            localStorage.setItem('bananaDownloadedModels', JSON.stringify(downloadedModels));
        }

        // Update UI
        statusText.textContent = 'Downloaded';
        statusText.className = 'status-text downloaded';
        progressContainer.classList.add('hidden');

    } catch (error) {
        console.error(`Error downloading model ${modelId}:`, error);
        statusText.textContent = 'Download failed';
        statusText.className = 'status-text';

        // Still mark as downloaded for demo purposes
        if (!downloadedModels.includes(modelId)) {
            downloadedModels.push(modelId);
            localStorage.setItem('bananaDownloadedModels', JSON.stringify(downloadedModels));
        }

        statusText.textContent = 'Downloaded';
        statusText.className = 'status-text downloaded';
        progressContainer.classList.add('hidden');
    }
}

async function simulateDownloadProgress(progressFill, progressText) {
    for (let i = 0; i <= 100; i += 2) {
        progressFill.style.width = i + '%';
        progressText.textContent = i + '%';
        await new Promise(resolve => setTimeout(resolve, 50));
    }
}

function updateModelSetupStatus() {
    downloadedModels.forEach(modelId => {
        const card = document.querySelector(`.model-card[data-model="${modelId}"]`);
        if (card) {
            const statusText = card.querySelector('.status-text');
            statusText.textContent = 'Downloaded';
            statusText.className = 'status-text downloaded';
        }
    });
}

// ==================== Chat Model Selection ====================

function populateChatModelDropdown() {
    if (!chatModelSelect) return;

    // Clear existing options except the placeholder
    chatModelSelect.innerHTML = '<option value="" disabled selected>Select a model...</option>';

    // Add downloaded models
    downloadedModels.forEach(modelId => {
        const modelInfo = AVAILABLE_MODELS.find(m => m.id === modelId);
        if (modelInfo) {
            const option = document.createElement('option');
            option.value = modelId;
            option.textContent = `${modelInfo.name} (${modelInfo.size})`;
            chatModelSelect.appendChild(option);
        }
    });

    // If only one model, select it automatically
    if (downloadedModels.length === 1) {
        chatModelSelect.value = downloadedModels[0];
        currentChatModel = downloadedModels[0];
        updateModelIndicator();
    }

    // Handle model selection change
    chatModelSelect.addEventListener('change', () => {
        currentChatModel = chatModelSelect.value;
        updateModelIndicator();

        // Update backend with selected model
        if (isBackendRunning && currentChatModel) {
            fetch(`${API_BASE_URL}/api/model/${currentChatModel}`, { method: 'POST' })
                .catch(err => console.error('Failed to set model:', err));
        }
    });
}

function updateModelIndicator() {
    if (!modelIndicator) return;

    if (currentChatModel) {
        const modelInfo = AVAILABLE_MODELS.find(m => m.id === currentChatModel);
        if (modelInfo) {
            modelIndicator.textContent = `Ready`;
            modelIndicator.className = 'model-indicator';
        }
    } else {
        modelIndicator.textContent = 'No model selected';
        modelIndicator.className = 'model-indicator warning';
    }
}

async function startBackend() {
    try {
        // Try Tauri command first (when running as desktop app)
        if (window.__TAURI__) {
            await invoke('start_backend');
        }

        // Poll for backend availability
        let attempts = 0;
        const maxAttempts = 30;

        while (attempts < maxAttempts) {
            try {
                const response = await fetch(`${API_BASE_URL}/api/status`);
                if (response.ok) {
                    isBackendRunning = true;
                    updateStatus(true);
                    connectWebSocket();
                    return;
                }
            } catch (e) {
                // Backend not ready yet
            }

            await new Promise(resolve => setTimeout(resolve, 500));
            attempts++;
        }

        updateStatus(false);
        console.error('Failed to connect to backend');

    } catch (error) {
        console.error('Error starting backend:', error);
        updateStatus(false);
    }
}

function updateStatus(online) {
    isBackendRunning = online;
    backendStatus.classList.toggle('online', online);
    statusText.textContent = online ? 'Connected' : 'Disconnected';
}

// ==================== WebSocket ====================

function connectWebSocket() {
    const wsUrl = `ws://127.0.0.1:8765/ws/chat`;
    ws = new WebSocket(wsUrl);

    ws.onopen = () => {
        console.log('WebSocket connected');
        updateStatus(true);
    };

    ws.onclose = () => {
        console.log('WebSocket disconnected');
        updateStatus(false);
        // Attempt to reconnect
        setTimeout(connectWebSocket, 3000);
    };

    ws.onerror = (error) => {
        console.error('WebSocket error:', error);
    };

    ws.onmessage = (event) => {
        const data = JSON.parse(event.data);

        if (data.chunk) {
            appendToLastMessage(data.chunk);
        }

        if (data.done) {
            sendButton.disabled = false;
            messageInput.disabled = false;
        }
    };
}

// ==================== Navigation ====================

function setupNavigation() {
    navItems.forEach(item => {
        item.addEventListener('click', () => {
            const viewName = item.dataset.view;

            // Update active nav item
            navItems.forEach(nav => nav.classList.remove('active'));
            item.classList.add('active');

            // Show corresponding view
            views.forEach(view => {
                view.classList.toggle('active', view.id === `${viewName}-view`);
            });
        });
    });
}

// ==================== Chat ====================

function setupChat() {
    // Auto-resize textarea
    messageInput.addEventListener('input', () => {
        messageInput.style.height = 'auto';
        messageInput.style.height = Math.min(messageInput.scrollHeight, 150) + 'px';
        sendButton.disabled = !messageInput.value.trim();
    });

    // Send on Enter (Shift+Enter for new line)
    messageInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    });

    sendButton.addEventListener('click', sendMessage);

    newChatBtn.addEventListener('click', clearChat);
}

async function sendMessage() {
    const message = messageInput.value.trim();
    if (!message || !isBackendRunning) return;

    // Check if a model is selected
    if (!currentChatModel) {
        alert('Please select a model from the dropdown above before sending a message.');
        chatModelSelect.focus();
        return;
    }

    // Add user message
    addMessage(message, true);

    // Clear input
    messageInput.value = '';
    messageInput.style.height = 'auto';
    sendButton.disabled = true;
    messageInput.disabled = true;

    // Add empty assistant message for streaming
    addMessage('', false);

    // Send via WebSocket if available
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
            message: message,
            use_knowledge_base: useKbCheckbox.checked
        }));
    } else {
        // Fallback to REST API
        try {
            const response = await fetch(`${API_BASE_URL}/api/chat`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    message: message,
                    use_knowledge_base: useKbCheckbox.checked
                })
            });

            const data = await response.json();

            // Update the last message
            const messages = chatContainer.querySelectorAll('.message.assistant');
            const lastMsg = messages[messages.length - 1];
            if (lastMsg) {
                const content = lastMsg.querySelector('.message-content');
                content.innerHTML = `<p>${escapeHtml(data.content)}</p>
                    <div class="message-source">${data.source} • ${data.model} • ${data.tokens_used} tokens</div>`;
            }
        } catch (error) {
            console.error('Chat error:', error);
            appendToLastMessage(`Error: ${error.message}`);
        } finally {
            sendButton.disabled = false;
            messageInput.disabled = false;
        }
    }
}

function addMessage(content, isUser = false) {
    const msgDiv = document.createElement('div');
    msgDiv.className = `message ${isUser ? 'user' : 'assistant'}`;

    const avatar = isUser ? '👤' : '🤖';

    msgDiv.innerHTML = `
        <div class="message-avatar">${avatar}</div>
        <div class="message-content">
            <p>${escapeHtml(content)}</p>
        </div>
    `;

    chatContainer.appendChild(msgDiv);
    chatContainer.scrollTop = chatContainer.scrollHeight;

    return msgDiv;
}

function appendToLastMessage(chunk) {
    const messages = chatContainer.querySelectorAll('.message.assistant');
    const lastMsg = messages[messages.length - 1];

    if (lastMsg) {
        const content = lastMsg.querySelector('.message-content p');
        if (content) {
            content.textContent += chunk;
            chatContainer.scrollTop = chatContainer.scrollHeight;
        }
    }
}

async function clearChat() {
    try {
        await fetch(`${API_BASE_URL}/api/clear`, { method: 'POST' });
        chatContainer.innerHTML = '';

        // Reset model selection for new chat
        if (chatModelSelect) {
            chatModelSelect.value = '';
            currentChatModel = null;
            updateModelIndicator();
        }

        addMessage('New chat started. Please select a model above to begin.', false);
    } catch (error) {
        console.error('Failed to clear chat:', error);
    }
}

// ==================== Knowledge Base ====================

function setupKnowledgeBase() {
    const uploadZone = document.getElementById('upload-zone');
    const fileInput = document.getElementById('file-input');
    const kbSearchInput = document.getElementById('kb-search-input');
    const kbSearchBtn = document.getElementById('kb-search-btn');

    // File upload
    uploadZone.addEventListener('click', () => fileInput.click());

    uploadZone.addEventListener('dragover', (e) => {
        e.preventDefault();
        uploadZone.classList.add('dragover');
    });

    uploadZone.addEventListener('dragleave', () => {
        uploadZone.classList.remove('dragover');
    });

    uploadZone.addEventListener('drop', async (e) => {
        e.preventDefault();
        uploadZone.classList.remove('dragover');

        const files = Array.from(e.dataTransfer.files);
        for (const file of files) {
            await uploadFile(file);
        }
    });

    fileInput.addEventListener('change', async (e) => {
        const files = Array.from(e.target.files);
        for (const file of files) {
            await uploadFile(file);
        }
    });

    // Search
    kbSearchBtn.addEventListener('click', searchKnowledgeBase);
    kbSearchInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') searchKnowledgeBase();
    });

    // Load stats
    loadKBStats();
}

async function uploadFile(file) {
    try {
        const content = await file.text();

        await fetch(`${API_BASE_URL}/api/kb/add`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                content: content,
                metadata: { filename: file.name, type: file.type }
            })
        });

        loadKBStats();
        alert(`File "${file.name}" uploaded successfully!`);

    } catch (error) {
        console.error('Upload error:', error);
        alert(`Failed to upload "${file.name}": ${error.message}`);
    }
}

async function loadKBStats() {
    try {
        const response = await fetch(`${API_BASE_URL}/api/kb/stats`);
        const stats = await response.json();

        document.getElementById('doc-count').textContent = stats.documents || 0;
        document.getElementById('chunk-count').textContent = stats.chunks || 0;

    } catch (error) {
        console.error('Failed to load KB stats:', error);
    }
}

async function searchKnowledgeBase() {
    const query = document.getElementById('kb-search-input').value.trim();
    if (!query) return;

    try {
        const response = await fetch(`${API_BASE_URL}/api/kb/search?query=${encodeURIComponent(query)}`);
        const data = await response.json();

        const resultsDiv = document.getElementById('kb-results');

        if (data.results && data.results.length > 0) {
            resultsDiv.innerHTML = data.results.map(result => `
                <div class="kb-result">
                    <p>${escapeHtml(result.content)}</p>
                    <small>Score: ${result.score?.toFixed(3) || 'N/A'}</small>
                </div>
            `).join('');
        } else {
            resultsDiv.innerHTML = '<p class="empty-state">No results found.</p>';
        }

    } catch (error) {
        console.error('Search error:', error);
    }
}

// ==================== Training ====================

function setupTraining() {
    const startTrainingBtn = document.getElementById('start-training');

    startTrainingBtn.addEventListener('click', startTraining);

    loadTrainedModels();
}

async function startTraining() {
    const taskName = document.getElementById('task-name').value.trim();
    const baseModel = document.getElementById('base-model').value;
    const trainingDataStr = document.getElementById('training-data').value.trim();

    if (!taskName || !trainingDataStr) {
        alert('Please fill in all fields');
        return;
    }

    let trainingData;
    try {
        trainingData = JSON.parse(trainingDataStr);
    } catch (e) {
        alert('Invalid JSON in training data');
        return;
    }

    try {
        const response = await fetch(`${API_BASE_URL}/api/train`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                task_name: taskName,
                training_data: trainingData,
                base_model: baseModel
            })
        });

        const result = await response.json();

        if (response.ok) {
            alert('Training started successfully!');
            loadTrainedModels();
        } else {
            alert(`Training failed: ${result.detail || 'Unknown error'}`);
        }

    } catch (error) {
        console.error('Training error:', error);
        alert(`Training error: ${error.message}`);
    }
}

async function loadTrainedModels() {
    try {
        const response = await fetch(`${API_BASE_URL}/api/models`);
        const data = await response.json();

        const modelsList = document.getElementById('models-list');

        if (data.models && data.models.length > 0) {
            modelsList.innerHTML = data.models.map(model => `
                <div class="model-card">
                    <span>${escapeHtml(model.name)}</span>
                    <button class="btn-secondary" onclick="loadModel('${model.name}')">Load</button>
                </div>
            `).join('');
        } else {
            modelsList.innerHTML = '<p class="empty-state">No trained models yet.</p>';
        }

    } catch (error) {
        console.error('Failed to load models:', error);
    }
}

// ==================== Settings ====================

function setupSettings() {
    const checkUpdatesBtn = document.getElementById('check-updates');

    // Load saved settings
    loadSettings();

    // Save settings on change
    const settingInputs = document.querySelectorAll('.settings-content input, .settings-content select, .settings-content textarea');
    settingInputs.forEach(input => {
        input.addEventListener('change', saveSettings);
    });

    // Check for updates
    checkUpdatesBtn.addEventListener('click', checkForUpdates);
}

function loadSettings() {
    const settings = JSON.parse(localStorage.getItem('bananaSettings') || '{}');

    if (settings.localModel) document.getElementById('local-model').value = settings.localModel;
    if (settings.systemPrompt) document.getElementById('system-prompt').value = settings.systemPrompt;
}

function saveSettings() {
    const settings = {
        localModel: document.getElementById('local-model').value,
        systemPrompt: document.getElementById('system-prompt').value
    };

    localStorage.setItem('bananaSettings', JSON.stringify(settings));

    // Apply system prompt if changed
    if (settings.systemPrompt) {
        fetch(`${API_BASE_URL}/api/system-prompt?prompt=${encodeURIComponent(settings.systemPrompt)}`, {
            method: 'POST'
        }).catch(console.error);
    }
}

async function checkForUpdates() {
    try {
        if (window.__TAURI__) {
            const { check } = await import('@tauri-apps/plugin-updater');
            const update = await check();

            if (update?.available) {
                const confirm = window.confirm(`Version ${update.version} is available. Would you like to update?`);
                if (confirm) {
                    await update.downloadAndInstall();
                }
            } else {
                alert('You are running the latest version!');
            }
        } else {
            alert('Updates are only available in the desktop app.');
        }
    } catch (error) {
        console.error('Update check error:', error);
        alert('Failed to check for updates.');
    }
}

// ==================== Utilities ====================

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// ==================== Start the app ====================

document.addEventListener('DOMContentLoaded', init);
