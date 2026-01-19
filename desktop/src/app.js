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
const ollamaStatusDot = document.getElementById('ollama-status-dot');
const ollamaStatusText = document.getElementById('ollama-status-text');
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
let isOllamaRunning = false;
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

    // Check Ollama status
    await checkOllamaStatus();

    // Check if this is first launch or if models need to be set up
    await checkModelSetup();

    // Start periodic Ollama status check
    setInterval(checkOllamaStatus, 10000);
}

async function checkOllamaStatus() {
    try {
        const response = await fetch(`${OLLAMA_API_URL}/api/tags`, {
            method: 'GET',
            signal: AbortSignal.timeout(3000)
        });

        if (response.ok) {
            isOllamaRunning = true;
            if (ollamaStatusDot) ollamaStatusDot.classList.add('running');
            if (ollamaStatusText) ollamaStatusText.textContent = 'Ollama Running';

            // Get list of installed models from Ollama
            const data = await response.json();
            if (data.models) {
                // Update downloaded models based on what Ollama actually has
                const ollamaModels = data.models.map(m => m.name);
                updateDownloadedModelsFromOllama(ollamaModels);
            }
        } else {
            setOllamaOffline();
        }
    } catch (error) {
        setOllamaOffline();
    }
}

function setOllamaOffline() {
    isOllamaRunning = false;
    if (ollamaStatusDot) ollamaStatusDot.classList.remove('running');
    if (ollamaStatusText) ollamaStatusText.textContent = 'Ollama Not Running';
}

function updateDownloadedModelsFromOllama(ollamaModels) {
    // Check which of our available models are installed in Ollama
    const installedModels = [];

    AVAILABLE_MODELS.forEach(model => {
        // Check if model ID matches any Ollama model (with or without :latest)
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

    // Update UI
    updateModelSetupStatus();
    populateChatModelDropdown();
    renderModelList();
}

async function checkModelSetup() {
    // Load downloaded models from localStorage initially
    downloadedModels = JSON.parse(localStorage.getItem('aigoodbyeDownloadedModels') || '[]');

    // Wait a moment for Ollama check to complete
    await new Promise(resolve => setTimeout(resolve, 1000));

    // Check if any models are downloaded
    if (downloadedModels.length === 0) {
        // First launch - show model setup screen
        setTimeout(() => {
            loadingScreen.classList.add('hidden');
            modelSetupScreen.classList.remove('hidden');
        }, 500);
    } else {
        // Models exist - proceed to app
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
                    const base64 = event.target.result.split(',')[1]; // Remove data:image/...;base64, prefix
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
        imageInput.value = ''; // Reset input
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

// Make removeImage available globally
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
        // Clear any pending images if switching to non-vision model
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
        if (!isOllamaRunning) {
            alert('Ollama is not running. Please start Ollama first.\n\nDownload Ollama from: https://ollama.ai');
            return;
        }

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
        let allSuccessful = true;
        for (const modelId of selectedModels) {
            const success = await downloadModelFromOllama(modelId);
            if (!success) {
                allSuccessful = false;
            }
        }

        if (allSuccessful && downloadedModels.length > 0) {
            // Show continue button
            downloadBtn.classList.add('hidden');
            continueBtn.classList.remove('hidden');
            selectionHint.textContent = 'Models downloaded successfully!';
        } else {
            downloadBtn.disabled = false;
            downloadBtn.textContent = 'Download Selected Models';
            modelCheckboxes.forEach(cb => cb.disabled = false);
        }
    });

    // Continue button
    continueBtn.addEventListener('click', () => {
        modelSetupScreen.classList.add('hidden');
        app.classList.remove('hidden');
        populateChatModelDropdown();
        renderModelList();
    });

    // Update model cards with current download status
    updateModelSetupStatus();
}

async function downloadModelFromOllama(modelId) {
    const card = document.querySelector(`.model-card[data-model="${modelId}"]`);
    const progressContainer = card?.querySelector('.model-progress');
    const progressFill = card?.querySelector('.progress-fill');
    const progressText = card?.querySelector('.progress-text');
    const statusTextEl = card?.querySelector('.status-text');

    // Show progress
    if (progressContainer) progressContainer.classList.remove('hidden');
    if (statusTextEl) {
        statusTextEl.textContent = 'Downloading...';
        statusTextEl.className = 'status-text downloading';
    }

    try {
        // Use Ollama pull API with streaming
        const response = await fetch(`${OLLAMA_API_URL}/api/pull`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name: modelId, stream: true })
        });

        if (!response.ok) {
            throw new Error(`Failed to pull model: ${response.status}`);
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder();

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

                    if (data.status) {
                        // Keep showing progress
                    }
                } catch (e) {
                    // Ignore JSON parse errors for incomplete chunks
                }
            }
        }

        // Mark as downloaded
        if (!downloadedModels.includes(modelId)) {
            downloadedModels.push(modelId);
            localStorage.setItem('aigoodbyeDownloadedModels', JSON.stringify(downloadedModels));
        }

        // Update UI
        if (statusTextEl) {
            statusTextEl.textContent = 'Downloaded';
            statusTextEl.className = 'status-text downloaded';
        }
        if (progressContainer) progressContainer.classList.add('hidden');

        return true;

    } catch (error) {
        console.error(`Error downloading model ${modelId}:`, error);

        if (statusTextEl) {
            statusTextEl.textContent = 'Download failed - Is Ollama running?';
            statusTextEl.className = 'status-text';
        }
        if (progressContainer) progressContainer.classList.add('hidden');

        return false;
    }
}

async function deleteModelFromOllama(modelId) {
    if (!confirm(`Are you sure you want to delete ${modelId}? This will free up disk space.`)) {
        return false;
    }

    try {
        const response = await fetch(`${OLLAMA_API_URL}/api/delete`, {
            method: 'DELETE',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name: modelId })
        });

        if (response.ok) {
            // Remove from downloaded models
            downloadedModels = downloadedModels.filter(m => m !== modelId);
            localStorage.setItem('aigoodbyeDownloadedModels', JSON.stringify(downloadedModels));

            // Update UI
            renderModelList();
            populateChatModelDropdown();
            updateModelSetupStatus();

            return true;
        } else {
            alert('Failed to delete model. Please try again.');
            return false;
        }
    } catch (error) {
        console.error('Error deleting model:', error);
        alert('Failed to delete model. Is Ollama running?');
        return false;
    }
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

// Make functions available globally for onclick handlers
window.handleDownloadModel = async function(modelId) {
    if (!isOllamaRunning) {
        alert('Ollama is not running. Please start Ollama first.\n\nDownload Ollama from: https://ollama.ai');
        return;
    }

    // Update UI to show downloading
    const modelItem = document.querySelector(`.model-item[data-model="${modelId}"]`);
    if (modelItem) {
        const actionsDiv = modelItem.querySelector('.model-item-actions');
        actionsDiv.innerHTML = `<span class="model-item-status downloading">Downloading...</span>`;
    }

    const success = await downloadModelFromOllama(modelId);

    // Re-render the list
    renderModelList();
    populateChatModelDropdown();
};

window.handleDeleteModel = async function(modelId) {
    await deleteModelFromOllama(modelId);
};

// ==================== Chat Model Selection ====================

function populateChatModelDropdown() {
    if (!chatModelSelect) return;

    // Clear existing options except the placeholder
    chatModelSelect.innerHTML = '<option value="" disabled selected>Select a model...</option>';

    // Add downloaded models
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

    // If only one model, select it automatically
    if (downloadedModels.length === 1) {
        chatModelSelect.value = downloadedModels[0];
        currentChatModel = downloadedModels[0];
        updateModelIndicator();
        updateAttachButtonVisibility();
    }

    // Handle model selection change
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
    const ollamaReady = isOllamaRunning;

    if (sendButton) {
        sendButton.disabled = !(hasModel && ollamaReady && (hasMessage || hasImages));
    }
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

            // Refresh model list when entering settings
            if (viewName === 'settings') {
                renderModelList();
            }
        });
    });
}

// ==================== Chat ====================

function setupChat() {
    if (!messageInput || !sendButton) return;

    // Auto-resize textarea
    messageInput.addEventListener('input', () => {
        messageInput.style.height = 'auto';
        messageInput.style.height = Math.min(messageInput.scrollHeight, 150) + 'px';
        updateSendButtonState();
    });

    // Send on Enter (Shift+Enter for new line)
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
        alert('Please select a model from the dropdown above before sending a message.');
        if (chatModelSelect) chatModelSelect.focus();
        return;
    }

    if (!isOllamaRunning) {
        alert('Ollama is not running. Please start Ollama to chat.\n\nDownload Ollama from: https://ollama.ai');
        return;
    }

    if (!message && pendingImages.length === 0) return;

    // Add user message
    addMessage(message, true, pendingImages.length > 0 ? [...pendingImages] : null);

    // Store for API call
    const imagesToSend = [...pendingImages];

    // Clear input
    messageInput.value = '';
    messageInput.style.height = 'auto';
    pendingImages = [];
    renderImagePreviews();
    sendButton.disabled = true;
    messageInput.disabled = true;

    // Add empty assistant message for streaming
    const assistantMsg = addMessage('', false);
    const contentEl = assistantMsg.querySelector('.message-content p');

    try {
        // Build the request for Ollama
        const requestBody = {
            model: currentChatModel,
            prompt: message,
            stream: true
        };

        // Add images for vision models
        if (imagesToSend.length > 0) {
            requestBody.images = imagesToSend.map(img => img.base64);
        }

        // Call Ollama generate API
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
                } catch (e) {
                    // Ignore JSON parse errors
                }
            }
        }

        // Add to conversation history
        conversationHistory.push({ role: 'user', content: message });
        conversationHistory.push({ role: 'assistant', content: fullResponse });

    } catch (error) {
        console.error('Chat error:', error);
        contentEl.textContent = `Error: ${error.message}. Make sure Ollama is running and the model is downloaded.`;
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
            `<img src="${img.preview}" alt="attached image" style="max-width: 200px; border-radius: 8px; margin-bottom: 10px;">`
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

    // Reset pending images
    pendingImages = [];
    renderImagePreviews();

    addMessage('Chat cleared. Select a model and start a new conversation!', false);
}

// ==================== Knowledge Base ====================

function setupKnowledgeBase() {
    const uploadZone = document.getElementById('upload-zone');
    const fileInput = document.getElementById('file-input');
    const kbSearchInput = document.getElementById('kb-search-input');
    const kbSearchBtn = document.getElementById('kb-search-btn');

    if (!uploadZone) return;

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
    if (kbSearchBtn) {
        kbSearchBtn.addEventListener('click', searchKnowledgeBase);
    }
    if (kbSearchInput) {
        kbSearchInput.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') searchKnowledgeBase();
        });
    }

    // Load stats
    loadKBStats();
}

async function uploadFile(file) {
    // Store in localStorage for now (simple implementation)
    // In a full implementation, this would use a vector database
    try {
        const content = await file.text();

        // Store document in localStorage
        const docs = JSON.parse(localStorage.getItem('aigoodbyeKnowledgeBase') || '[]');
        docs.push({
            id: Date.now(),
            filename: file.name,
            content: content,
            uploadedAt: new Date().toISOString()
        });
        localStorage.setItem('aigoodbyeKnowledgeBase', JSON.stringify(docs));

        loadKBStats();
        alert(`File "${file.name}" added to knowledge base!`);

    } catch (error) {
        console.error('Upload error:', error);
        alert(`Failed to upload "${file.name}": ${error.message}`);
    }
}

function loadKBStats() {
    const docs = JSON.parse(localStorage.getItem('aigoodbyeKnowledgeBase') || '[]');
    const totalChunks = docs.reduce((sum, doc) => sum + Math.ceil(doc.content.length / 500), 0);

    const docCountEl = document.getElementById('doc-count');
    const chunkCountEl = document.getElementById('chunk-count');

    if (docCountEl) docCountEl.textContent = docs.length;
    if (chunkCountEl) chunkCountEl.textContent = totalChunks;
}

async function searchKnowledgeBase() {
    const kbSearchInput = document.getElementById('kb-search-input');
    const query = kbSearchInput ? kbSearchInput.value.trim().toLowerCase() : '';
    if (!query) return;

    const docs = JSON.parse(localStorage.getItem('aigoodbyeKnowledgeBase') || '[]');
    const resultsDiv = document.getElementById('kb-results');

    if (!resultsDiv) return;

    // Simple text search
    const results = docs
        .filter(doc => doc.content.toLowerCase().includes(query) || doc.filename.toLowerCase().includes(query))
        .map(doc => {
            // Find the matching section
            const index = doc.content.toLowerCase().indexOf(query);
            const start = Math.max(0, index - 100);
            const end = Math.min(doc.content.length, index + query.length + 100);
            const snippet = '...' + doc.content.substring(start, end) + '...';

            return { filename: doc.filename, snippet };
        });

    if (results.length > 0) {
        resultsDiv.innerHTML = results.map(result => `
            <div class="kb-result">
                <strong>${escapeHtml(result.filename)}</strong>
                <p>${escapeHtml(result.snippet)}</p>
            </div>
        `).join('');
    } else {
        resultsDiv.innerHTML = '<p class="empty-state">No results found.</p>';
    }
}

// ==================== Training ====================

function setupTraining() {
    const startTrainingBtn = document.getElementById('start-training');
    if (startTrainingBtn) {
        startTrainingBtn.addEventListener('click', startTraining);
    }
}

async function startTraining() {
    alert('Model training requires significant computational resources.\n\nFor fine-tuning, we recommend using Ollama\'s modelfile feature to create custom models based on existing ones.\n\nVisit: https://ollama.ai/docs/modelfile');
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
    if (checkUpdatesBtn) {
        checkUpdatesBtn.addEventListener('click', checkForUpdates);
    }

    // Initial render of model list
    renderModelList();
}

function loadSettings() {
    const settings = JSON.parse(localStorage.getItem('aigoodbyeSettings') || '{}');
    const systemPromptEl = document.getElementById('system-prompt');
    if (settings.systemPrompt && systemPromptEl) {
        systemPromptEl.value = settings.systemPrompt;
    }
}

function saveSettings() {
    const systemPromptEl = document.getElementById('system-prompt');
    const settings = {
        systemPrompt: systemPromptEl ? systemPromptEl.value : ''
    };

    localStorage.setItem('aigoodbyeSettings', JSON.stringify(settings));
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
