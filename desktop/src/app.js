/**
 * AI Goodbye Desktop Application
 * Frontend JavaScript for Tauri desktop wrapper
 */

// Tauri API imports (will be available when running in Tauri)
const { invoke } = window.__TAURI__ ? window.__TAURI__.core : { invoke: async () => {} };

// Ollama API Configuration (Ollama runs on localhost:11434 by default)
const OLLAMA_API_URL = 'http://127.0.0.1:11434';

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
const chatContainer = document.getElementById('chat-container');
const messageInput = document.getElementById('message-input');
const sendButton = document.getElementById('send-button');
const attachButton = document.getElementById('attach-button');
const imageInput = document.getElementById('image-input');
const imagePreviewContainer = document.getElementById('image-preview-container');
const useKbCheckbox = document.getElementById('use-kb');
const newChatBtn = document.getElementById('new-chat-btn');
const chatModelSelect = document.getElementById('chat-model-select');
const modelIndicator = document.getElementById('model-indicator');

// Navigation elements
const navItems = document.querySelectorAll('.nav-item');
const views = document.querySelectorAll('.view');

// State
let downloadedModels = [];
let currentChatModel = null;
let pendingImages = []; // Base64 encoded images for vision models
let conversationHistory = [];

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
    setupImageAttachment();

    // Check for installed models
    await syncWithOllama();

    // Check if this is first launch or if models need to be set up
    await checkModelSetup();
}

// Check if Ollama is running and get installed models
async function syncWithOllama() {
    try {
        const response = await fetch(`${OLLAMA_API_URL}/api/tags`, {
            method: 'GET',
            signal: AbortSignal.timeout(3000)
        });

        if (response.ok) {
            const data = await response.json();
            if (data.models) {
                const ollamaModels = data.models.map(m => m.name);
                updateDownloadedModelsFromOllama(ollamaModels);
            }
            return true;
        }
    } catch (error) {
        console.log('Ollama not available:', error.message);
    }
    return false;
}

function updateDownloadedModelsFromOllama(ollamaModels) {
    const installedModels = [];

    AVAILABLE_MODELS.forEach(model => {
        const isInstalled = ollamaModels.some(om => {
            const normalizedOllama = om.replace(':latest', '');
            const normalizedModel = model.id.replace(':latest', '');
            return normalizedOllama === normalizedModel ||
                   normalizedOllama.startsWith(normalizedModel.split(':')[0]);
        });

        if (isInstalled) {
            installedModels.push(model.id);
        }
    });

    downloadedModels = installedModels;
    localStorage.setItem('aigoodbyeDownloadedModels', JSON.stringify(downloadedModels));

    updateModelSetupStatus();
    populateChatModelDropdown();
    renderModelList();
}

async function checkModelSetup() {
    downloadedModels = JSON.parse(localStorage.getItem('aigoodbyeDownloadedModels') || '[]');

    await new Promise(resolve => setTimeout(resolve, 1000));

    if (downloadedModels.length === 0) {
        setTimeout(() => {
            loadingScreen.classList.add('hidden');
            modelSetupScreen.classList.remove('hidden');
        }, 500);
    } else {
        setTimeout(() => {
            loadingScreen.classList.add('hidden');
            app.classList.remove('hidden');
            populateChatModelDropdown();
            renderModelList();
        }, 1000);
    }
}

// ==================== Image Attachment ====================

function setupImageAttachment() {
    if (!attachButton || !imageInput) return;

    attachButton.addEventListener('click', () => {
        imageInput.click();
    });

    imageInput.addEventListener('change', (e) => {
        const files = Array.from(e.target.files);
        files.forEach(file => {
            if (file.type.startsWith('image/')) {
                const reader = new FileReader();
                reader.onload = (event) => {
                    const base64 = event.target.result.split(',')[1];
                    pendingImages.push({
                        base64: base64,
                        preview: event.target.result,
                        name: file.name
                    });
                    renderImagePreviews();
                    updateSendButtonState();
                };
                reader.readAsDataURL(file);
            }
        });
        imageInput.value = '';
    });
}

function renderImagePreviews() {
    if (!imagePreviewContainer) return;
    imagePreviewContainer.innerHTML = pendingImages.map((img, index) => `
        <div class="image-preview">
            <img src="${img.preview}" alt="${img.name}">
            <button class="remove-image" onclick="removeImage(${index})">×</button>
        </div>
    `).join('');
}

window.removeImage = function(index) {
    pendingImages.splice(index, 1);
    renderImagePreviews();
    updateSendButtonState();
};

function updateAttachButtonVisibility() {
    if (!attachButton) return;
    const modelInfo = AVAILABLE_MODELS.find(m => m.id === currentChatModel);
    if (modelInfo && modelInfo.vision) {
        attachButton.classList.remove('hidden');
    } else {
        attachButton.classList.add('hidden');
        pendingImages = [];
        renderImagePreviews();
    }
}

// ==================== Model Setup ====================

function setupModelSetup() {
    const modelCheckboxes = document.querySelectorAll('.model-checkbox');
    const downloadBtn = document.getElementById('download-models-btn');
    const continueBtn = document.getElementById('continue-setup-btn');
    const selectionHint = document.getElementById('selection-hint');
    const modelCards = document.querySelectorAll('.model-setup-screen .model-card');

    if (!downloadBtn) return;

    // Make entire card clickable
    modelCards.forEach(card => {
        card.addEventListener('click', (e) => {
            if (e.target.type !== 'checkbox' && !e.target.classList.contains('remove-image')) {
                const checkbox = card.querySelector('.model-checkbox');
                if (checkbox && !checkbox.disabled) {
                    checkbox.checked = !checkbox.checked;
                    checkbox.dispatchEvent(new Event('change'));
                }
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

    // Download button click handler
    downloadBtn.addEventListener('click', async () => {
        const selectedModels = [];
        modelCheckboxes.forEach(checkbox => {
            if (checkbox.checked) {
                const card = checkbox.closest('.model-card');
                selectedModels.push(card.dataset.model);
            }
        });

        if (selectedModels.length === 0) return;

        // Check if Ollama is running first
        const ollamaAvailable = await checkOllamaAvailable();
        if (!ollamaAvailable) {
            alert('Ollama is required to run AI models locally.\n\n' +
                  'Please install Ollama first:\n' +
                  '1. Visit https://ollama.ai\n' +
                  '2. Download and install Ollama\n' +
                  '3. Start Ollama\n' +
                  '4. Come back and try again');
            return;
        }

        // Disable UI during download
        downloadBtn.disabled = true;
        downloadBtn.textContent = 'Downloading...';
        modelCheckboxes.forEach(cb => cb.disabled = true);

        // Download each selected model
        let successCount = 0;
        for (const modelId of selectedModels) {
            const success = await downloadModelFromOllama(modelId);
            if (success) successCount++;
        }

        if (successCount > 0) {
            downloadBtn.classList.add('hidden');
            continueBtn.classList.remove('hidden');
            selectionHint.textContent = `${successCount} model${successCount > 1 ? 's' : ''} downloaded successfully!`;
        } else {
            downloadBtn.disabled = false;
            downloadBtn.textContent = 'Download Selected Models';
            modelCheckboxes.forEach(cb => cb.disabled = false);
            selectionHint.textContent = 'Download failed. Make sure Ollama is running.';
        }
    });

    // Continue button
    continueBtn.addEventListener('click', () => {
        modelSetupScreen.classList.add('hidden');
        app.classList.remove('hidden');
        populateChatModelDropdown();
        renderModelList();
    });

    updateModelSetupStatus();
}

async function checkOllamaAvailable() {
    try {
        const response = await fetch(`${OLLAMA_API_URL}/api/tags`, {
            method: 'GET',
            signal: AbortSignal.timeout(5000)
        });
        return response.ok;
    } catch (error) {
        return false;
    }
}

async function downloadModelFromOllama(modelId) {
    const card = document.querySelector(`.model-card[data-model="${modelId}"]`);
    const progressContainer = card?.querySelector('.model-progress');
    const progressFill = card?.querySelector('.progress-fill');
    const progressText = card?.querySelector('.progress-text');
    const statusTextEl = card?.querySelector('.status-text');

    if (progressContainer) progressContainer.classList.remove('hidden');
    if (statusTextEl) {
        statusTextEl.textContent = 'Connecting...';
        statusTextEl.className = 'status-text downloading';
    }

    try {
        const response = await fetch(`${OLLAMA_API_URL}/api/pull`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name: modelId, stream: true })
        });

        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder();

        if (statusTextEl) statusTextEl.textContent = 'Downloading...';

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            const text = decoder.decode(value);
            const lines = text.split('\n').filter(line => line.trim());

            for (const line of lines) {
                try {
                    const data = JSON.parse(line);
                    if (data.total && data.completed) {
                        const percent = Math.round((data.completed / data.total) * 100);
                        if (progressFill) progressFill.style.width = percent + '%';
                        if (progressText) progressText.textContent = percent + '%';
                    }
                    if (data.status === 'success') {
                        if (progressFill) progressFill.style.width = '100%';
                        if (progressText) progressText.textContent = '100%';
                    }
                } catch (e) {}
            }
        }

        // Mark as downloaded
        if (!downloadedModels.includes(modelId)) {
            downloadedModels.push(modelId);
            localStorage.setItem('aigoodbyeDownloadedModels', JSON.stringify(downloadedModels));
        }

        if (statusTextEl) {
            statusTextEl.textContent = 'Downloaded';
            statusTextEl.className = 'status-text downloaded';
        }
        if (progressContainer) progressContainer.classList.add('hidden');

        return true;

    } catch (error) {
        console.error(`Download error for ${modelId}:`, error);
        if (statusTextEl) {
            statusTextEl.textContent = 'Failed';
            statusTextEl.className = 'status-text';
        }
        if (progressContainer) progressContainer.classList.add('hidden');
        return false;
    }
}

async function deleteModelFromOllama(modelId) {
    if (!confirm(`Delete ${modelId}? This will free up disk space.`)) {
        return false;
    }

    try {
        const response = await fetch(`${OLLAMA_API_URL}/api/delete`, {
            method: 'DELETE',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name: modelId })
        });

        if (response.ok) {
            downloadedModels = downloadedModels.filter(m => m !== modelId);
            localStorage.setItem('aigoodbyeDownloadedModels', JSON.stringify(downloadedModels));
            renderModelList();
            populateChatModelDropdown();
            updateModelSetupStatus();
            return true;
        }
    } catch (error) {
        console.error('Delete error:', error);
    }
    alert('Failed to delete model.');
    return false;
}

function updateModelSetupStatus() {
    downloadedModels.forEach(modelId => {
        const card = document.querySelector(`.model-card[data-model="${modelId}"]`);
        if (card) {
            const statusTextEl = card.querySelector('.status-text');
            if (statusTextEl) {
                statusTextEl.textContent = 'Downloaded';
                statusTextEl.className = 'status-text downloaded';
            }
        }
    });
}

// ==================== Model Management in Settings ====================

function renderModelList() {
    const modelListEl = document.getElementById('model-list');
    if (!modelListEl) return;

    modelListEl.innerHTML = AVAILABLE_MODELS.map(model => {
        const isDownloaded = downloadedModels.includes(model.id);
        const visionBadge = model.vision ? ' (Vision)' : '';

        return `
            <div class="model-item" data-model="${model.id}">
                <div class="model-item-info">
                    <div class="model-item-name">${model.name}${visionBadge}</div>
                    <div class="model-item-size">${model.sizeGB}</div>
                </div>
                <div class="model-item-actions">
                    ${isDownloaded ?
                        `<span class="model-item-status downloaded">Downloaded</span>
                         <button class="btn-delete-small" onclick="handleDeleteModel('${model.id}')">Delete</button>` :
                        `<span class="model-item-status not-downloaded">Not Downloaded</span>
                         <button class="btn-download-small" onclick="handleDownloadModel('${model.id}')">Download</button>`
                    }
                </div>
            </div>
        `;
    }).join('');
}

window.handleDownloadModel = async function(modelId) {
    const ollamaAvailable = await checkOllamaAvailable();
    if (!ollamaAvailable) {
        alert('Ollama is required.\n\nPlease install from https://ollama.ai and start it.');
        return;
    }

    const modelItem = document.querySelector(`.model-item[data-model="${modelId}"]`);
    if (modelItem) {
        const actionsDiv = modelItem.querySelector('.model-item-actions');
        actionsDiv.innerHTML = `<span class="model-item-status downloading">Downloading...</span>`;
    }

    await downloadModelFromOllama(modelId);
    renderModelList();
    populateChatModelDropdown();
};

window.handleDeleteModel = async function(modelId) {
    await deleteModelFromOllama(modelId);
};

// ==================== Chat Model Selection ====================

function populateChatModelDropdown() {
    if (!chatModelSelect) return;

    chatModelSelect.innerHTML = '<option value="" disabled selected>Select a model...</option>';

    downloadedModels.forEach(modelId => {
        const modelInfo = AVAILABLE_MODELS.find(m => m.id === modelId);
        if (modelInfo) {
            const visionTag = modelInfo.vision ? ' [Vision]' : '';
            const option = document.createElement('option');
            option.value = modelId;
            option.textContent = `${modelInfo.name}${visionTag}`;
            chatModelSelect.appendChild(option);
        }
    });

    if (downloadedModels.length === 1) {
        chatModelSelect.value = downloadedModels[0];
        currentChatModel = downloadedModels[0];
        updateModelIndicator();
        updateAttachButtonVisibility();
    }

    chatModelSelect.onchange = () => {
        currentChatModel = chatModelSelect.value;
        updateModelIndicator();
        updateAttachButtonVisibility();
        updateSendButtonState();
    };
}

function updateModelIndicator() {
    if (!modelIndicator) return;

    if (currentChatModel) {
        const modelInfo = AVAILABLE_MODELS.find(m => m.id === currentChatModel);
        if (modelInfo) {
            const visionTag = modelInfo.vision ? ' (Vision)' : '';
            modelIndicator.textContent = `Ready${visionTag}`;
            modelIndicator.className = 'model-indicator';
        }
    } else {
        modelIndicator.textContent = 'No model selected';
        modelIndicator.className = 'model-indicator warning';
    }
}

function updateSendButtonState() {
    const hasMessage = messageInput && messageInput.value.trim().length > 0;
    const hasImages = pendingImages.length > 0;
    const hasModel = !!currentChatModel;

    if (sendButton) {
        sendButton.disabled = !(hasModel && (hasMessage || hasImages));
    }
}

// ==================== Navigation ====================

function setupNavigation() {
    navItems.forEach(item => {
        item.addEventListener('click', () => {
            const viewName = item.dataset.view;

            navItems.forEach(nav => nav.classList.remove('active'));
            item.classList.add('active');

            views.forEach(view => {
                view.classList.toggle('active', view.id === `${viewName}-view`);
            });

            if (viewName === 'settings') {
                renderModelList();
            }
        });
    });
}

// ==================== Chat ====================

function setupChat() {
    if (!messageInput || !sendButton) return;

    messageInput.addEventListener('input', () => {
        messageInput.style.height = 'auto';
        messageInput.style.height = Math.min(messageInput.scrollHeight, 150) + 'px';
        updateSendButtonState();
    });

    messageInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            if (!sendButton.disabled) {
                sendMessage();
            }
        }
    });

    sendButton.addEventListener('click', sendMessage);

    if (newChatBtn) {
        newChatBtn.addEventListener('click', clearChat);
    }
}

async function sendMessage() {
    const message = messageInput.value.trim();

    if (!currentChatModel) {
        alert('Please select a model first.');
        return;
    }

    if (!message && pendingImages.length === 0) return;

    // Check Ollama before sending
    const ollamaAvailable = await checkOllamaAvailable();
    if (!ollamaAvailable) {
        alert('Cannot connect to Ollama.\n\nPlease make sure Ollama is running.');
        return;
    }

    addMessage(message, true, pendingImages.length > 0 ? [...pendingImages] : null);

    const imagesToSend = [...pendingImages];

    messageInput.value = '';
    messageInput.style.height = 'auto';
    pendingImages = [];
    renderImagePreviews();
    sendButton.disabled = true;
    messageInput.disabled = true;

    const assistantMsg = addMessage('', false);
    const contentEl = assistantMsg.querySelector('.message-content p');

    try {
        const requestBody = {
            model: currentChatModel,
            prompt: message,
            stream: true
        };

        if (imagesToSend.length > 0) {
            requestBody.images = imagesToSend.map(img => img.base64);
        }

        const response = await fetch(`${OLLAMA_API_URL}/api/generate`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestBody)
        });

        if (!response.ok) {
            throw new Error(`Ollama error: ${response.status}`);
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let fullResponse = '';

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            const text = decoder.decode(value);
            const lines = text.split('\n').filter(line => line.trim());

            for (const line of lines) {
                try {
                    const data = JSON.parse(line);
                    if (data.response) {
                        fullResponse += data.response;
                        contentEl.textContent = fullResponse;
                        chatContainer.scrollTop = chatContainer.scrollHeight;
                    }
                } catch (e) {}
            }
        }

        conversationHistory.push({ role: 'user', content: message });
        conversationHistory.push({ role: 'assistant', content: fullResponse });

    } catch (error) {
        console.error('Chat error:', error);
        contentEl.textContent = `Error: ${error.message}`;
    } finally {
        sendButton.disabled = false;
        messageInput.disabled = false;
        messageInput.focus();
        updateSendButtonState();
    }
}

function addMessage(content, isUser = false, images = null) {
    const msgDiv = document.createElement('div');
    msgDiv.className = `message ${isUser ? 'user' : 'assistant'}`;

    const avatar = isUser ? '👤' : '🤖';

    let imagesHtml = '';
    if (images && images.length > 0) {
        imagesHtml = `<div class="message-images">${images.map(img =>
            `<img src="${img.preview}" alt="attached" style="max-width: 200px; border-radius: 8px; margin-bottom: 10px;">`
        ).join('')}</div>`;
    }

    msgDiv.innerHTML = `
        <div class="message-avatar">${avatar}</div>
        <div class="message-content">
            ${imagesHtml}
            <p>${escapeHtml(content)}</p>
        </div>
    `;

    chatContainer.appendChild(msgDiv);
    chatContainer.scrollTop = chatContainer.scrollHeight;

    return msgDiv;
}

async function clearChat() {
    chatContainer.innerHTML = '';
    conversationHistory = [];
    pendingImages = [];
    renderImagePreviews();
    addMessage('Chat cleared. Select a model to start chatting!', false);
}

// ==================== Knowledge Base ====================

function setupKnowledgeBase() {
    const uploadZone = document.getElementById('upload-zone');
    const fileInput = document.getElementById('file-input');
    const kbSearchBtn = document.getElementById('kb-search-btn');
    const kbSearchInput = document.getElementById('kb-search-input');

    if (!uploadZone) return;

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
        for (const file of Array.from(e.dataTransfer.files)) {
            await uploadFile(file);
        }
    });

    fileInput.addEventListener('change', async (e) => {
        for (const file of Array.from(e.target.files)) {
            await uploadFile(file);
        }
    });

    if (kbSearchBtn) kbSearchBtn.addEventListener('click', searchKnowledgeBase);
    if (kbSearchInput) kbSearchInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') searchKnowledgeBase();
    });

    loadKBStats();
}

async function uploadFile(file) {
    try {
        const content = await file.text();
        const docs = JSON.parse(localStorage.getItem('aigoodbyeKnowledgeBase') || '[]');
        docs.push({
            id: Date.now(),
            filename: file.name,
            content: content,
            uploadedAt: new Date().toISOString()
        });
        localStorage.setItem('aigoodbyeKnowledgeBase', JSON.stringify(docs));
        loadKBStats();
        alert(`"${file.name}" added to knowledge base!`);
    } catch (error) {
        alert(`Failed to upload: ${error.message}`);
    }
}

function loadKBStats() {
    const docs = JSON.parse(localStorage.getItem('aigoodbyeKnowledgeBase') || '[]');
    const chunks = docs.reduce((sum, doc) => sum + Math.ceil(doc.content.length / 500), 0);
    const docCountEl = document.getElementById('doc-count');
    const chunkCountEl = document.getElementById('chunk-count');
    if (docCountEl) docCountEl.textContent = docs.length;
    if (chunkCountEl) chunkCountEl.textContent = chunks;
}

function searchKnowledgeBase() {
    const input = document.getElementById('kb-search-input');
    const query = input ? input.value.trim().toLowerCase() : '';
    if (!query) return;

    const docs = JSON.parse(localStorage.getItem('aigoodbyeKnowledgeBase') || '[]');
    const resultsDiv = document.getElementById('kb-results');
    if (!resultsDiv) return;

    const results = docs
        .filter(doc => doc.content.toLowerCase().includes(query) || doc.filename.toLowerCase().includes(query))
        .map(doc => {
            const idx = doc.content.toLowerCase().indexOf(query);
            const start = Math.max(0, idx - 100);
            const end = Math.min(doc.content.length, idx + query.length + 100);
            return { filename: doc.filename, snippet: '...' + doc.content.substring(start, end) + '...' };
        });

    resultsDiv.innerHTML = results.length > 0
        ? results.map(r => `<div class="kb-result"><strong>${escapeHtml(r.filename)}</strong><p>${escapeHtml(r.snippet)}</p></div>`).join('')
        : '<p class="empty-state">No results found.</p>';
}

// ==================== Training ====================

function setupTraining() {
    const btn = document.getElementById('start-training');
    if (btn) btn.addEventListener('click', () => {
        alert('For model fine-tuning, use Ollama modelfiles.\n\nVisit: https://ollama.ai/docs/modelfile');
    });
}

// ==================== Settings ====================

function setupSettings() {
    const checkUpdatesBtn = document.getElementById('check-updates');
    loadSettings();

    document.querySelectorAll('.settings-content input, .settings-content textarea').forEach(input => {
        input.addEventListener('change', saveSettings);
    });

    if (checkUpdatesBtn) checkUpdatesBtn.addEventListener('click', checkForUpdates);
    renderModelList();
}

function loadSettings() {
    const settings = JSON.parse(localStorage.getItem('aigoodbyeSettings') || '{}');
    const el = document.getElementById('system-prompt');
    if (settings.systemPrompt && el) el.value = settings.systemPrompt;
}

function saveSettings() {
    const el = document.getElementById('system-prompt');
    localStorage.setItem('aigoodbyeSettings', JSON.stringify({
        systemPrompt: el ? el.value : ''
    }));
}

async function checkForUpdates() {
    try {
        if (window.__TAURI__) {
            const { check } = await import('@tauri-apps/plugin-updater');
            const update = await check();
            if (update?.available) {
                if (confirm(`Version ${update.version} available. Update now?`)) {
                    await update.downloadAndInstall();
                }
            } else {
                alert('You have the latest version!');
            }
        } else {
            alert('Updates available in desktop app only.');
        }
    } catch (e) {
        alert('Update check failed.');
    }
}

// ==================== Utilities ====================

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// ==================== Start ====================

document.addEventListener('DOMContentLoaded', init);
