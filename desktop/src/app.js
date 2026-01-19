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
    { id: 'llama3.2-vision', name: 'Llama 3.2 Vision 11B', size: 'large', sizeGB: '~8 GB', vision: true },
    { id: 'llama3.2-vision:90b', name: 'Llama 3.2 Vision 90B', size: 'xlarge', sizeGB: '~55 GB', vision: true }
];

// DOM Elements - will be initialized after DOM loads
let loadingScreen, modelSetupScreen, app, chatContainer, messageInput, sendButton;
let attachButton, imageInput, imagePreviewContainer, useKbCheckbox, newChatBtn;
let chatModelSelect, modelIndicator, navItems, views;

// State
let downloadedModels = [];
let currentChatModel = null;
let pendingImages = []; // Base64 encoded images for vision models
let conversationHistory = [];
let ollamaReady = false;

// Chat & Folder Management State
let chats = [];
let folders = [];
let currentChatId = null;

// ==================== Initialization ====================

function initDOMElements() {
    loadingScreen = document.getElementById('loading-screen');
    modelSetupScreen = document.getElementById('model-setup-screen');
    app = document.getElementById('app');
    chatContainer = document.getElementById('chat-container');
    messageInput = document.getElementById('message-input');
    sendButton = document.getElementById('send-button');
    attachButton = document.getElementById('attach-button');
    imageInput = document.getElementById('image-input');
    imagePreviewContainer = document.getElementById('image-preview-container');
    useKbCheckbox = document.getElementById('use-kb');
    newChatBtn = document.getElementById('new-chat-btn');
    chatModelSelect = document.getElementById('chat-model-select');
    modelIndicator = document.getElementById('model-indicator');
    navItems = document.querySelectorAll('.nav-item');
    views = document.querySelectorAll('.view');
}

async function init() {
    console.log('Initializing AI Goodbye Desktop...');

    // Initialize DOM references
    initDOMElements();

    // Load saved data
    loadChatsAndFolders();

    // Set up event listeners
    setupNavigation();
    setupChat();
    setupKnowledgeBase();
    setupSettings();
    setupModelSetup();
    setupImageAttachment();
    setupRetryButton();
    setupChatFolderManagement();

    // Start Ollama and wait for it
    await startupSequence();
}

function setupRetryButton() {
    const retryBtn = document.getElementById('retry-btn');
    if (retryBtn) {
        retryBtn.addEventListener('click', async () => {
            retryBtn.classList.add('hidden');
            await startupSequence();
        });
    }
}

async function startupSequence() {
    const loadingBar = document.querySelector('.loading-bar');
    const loadingTextEl = document.querySelector('.loading-text');
    const retryBtn = document.getElementById('retry-btn');

    // Reset UI
    if (loadingBar) loadingBar.style.display = '';
    if (loadingTextEl) loadingTextEl.className = 'loading-text';
    updateLoadingText('Starting AI engine...');

    // Wait for Ollama to be ready
    console.log('Waiting for Ollama...');
    ollamaReady = await waitForOllama();

    if (!ollamaReady) {
        // Ollama failed to start - show error and retry button
        console.error('Ollama failed to start');
        if (loadingBar) loadingBar.style.display = 'none';
        if (loadingTextEl) loadingTextEl.className = 'loading-text error';
        updateLoadingText('Could not start AI engine. Click Retry.');
        if (retryBtn) retryBtn.classList.remove('hidden');
        return;
    }

    // Ollama is ready - proceed with app
    console.log('Ollama ready, syncing models...');
    updateLoadingText('Checking installed models...');
    await syncWithOllama();

    // Show appropriate screen
    await checkModelSetup();
}

function updateLoadingText(text) {
    const loadingTextEl = document.querySelector('.loading-text');
    if (loadingTextEl) {
        loadingTextEl.textContent = text;
    }
}

// Wait for Ollama to become ready
async function waitForOllama(maxAttempts = 60) {
    // Try up to 60 times with 500ms delay = 30 seconds total
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
        const ready = await checkOllamaAvailable();
        if (ready) {
            console.log(`Ollama ready after ${attempt + 1} attempts`);
            return true;
        }

        await new Promise(resolve => setTimeout(resolve, 500));

        // Update loading text with dots
        const dots = '.'.repeat((attempt % 3) + 1);
        updateLoadingText(`Starting AI engine${dots}`);
    }

    console.warn('Ollama did not start within 30 seconds');
    return false;
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
            renderChatList();
        }, 1000);
    }
}

// ==================== Image Attachment ====================

function setupImageAttachment() {
    if (!attachButton || !imageInput) {
        console.log('Image attachment elements not found');
        return;
    }

    console.log('Setting up image attachment...');

    attachButton.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        console.log('Attach button clicked');
        imageInput.click();
    });

    imageInput.addEventListener('change', (e) => {
        console.log('Files selected:', e.target.files.length);
        const files = Array.from(e.target.files);

        files.forEach(file => {
            console.log('Processing file:', file.name, file.type);
            if (file.type.startsWith('image/')) {
                const reader = new FileReader();
                reader.onload = (event) => {
                    console.log('File loaded, adding to pendingImages');
                    const base64 = event.target.result.split(',')[1];
                    pendingImages.push({
                        base64: base64,
                        preview: event.target.result,
                        name: file.name
                    });
                    console.log('pendingImages count:', pendingImages.length);
                    renderImagePreviews();
                    updateSendButtonState();
                };
                reader.onerror = (error) => {
                    console.error('FileReader error:', error);
                };
                reader.readAsDataURL(file);
            } else {
                console.log('File is not an image:', file.type);
            }
        });
        // Reset input so same file can be selected again
        imageInput.value = '';
    });
}

function renderImagePreviews() {
    console.log('Rendering image previews, count:', pendingImages.length);
    if (!imagePreviewContainer) {
        console.error('imagePreviewContainer not found!');
        return;
    }

    if (pendingImages.length === 0) {
        imagePreviewContainer.innerHTML = '';
        imagePreviewContainer.style.display = 'none';
        return;
    }

    imagePreviewContainer.style.display = 'flex';
    imagePreviewContainer.innerHTML = pendingImages.map((img, index) => `
        <div class="image-preview">
            <img src="${img.preview}" alt="${img.name}">
            <button type="button" class="remove-image" data-index="${index}">×</button>
        </div>
    `).join('');

    // Add click handlers for remove buttons
    imagePreviewContainer.querySelectorAll('.remove-image').forEach(btn => {
        btn.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            const index = parseInt(btn.dataset.index);
            removeImage(index);
        });
    });
}

function removeImage(index) {
    console.log('Removing image at index:', index);
    pendingImages.splice(index, 1);
    renderImagePreviews();
    updateSendButtonState();
}

// Expose globally for onclick handlers
window.removeImage = removeImage;

function updateAttachButtonVisibility() {
    if (!attachButton) return;
    const modelInfo = AVAILABLE_MODELS.find(m => m.id === currentChatModel);
    console.log('Updating attach button visibility. Model:', currentChatModel, 'Vision:', modelInfo?.vision);
    if (modelInfo && modelInfo.vision) {
        attachButton.classList.remove('hidden');
        attachButton.style.display = 'flex';
    } else {
        attachButton.classList.add('hidden');
        attachButton.style.display = 'none';
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
        console.log('Download button clicked');

        const selectedModels = [];
        modelCheckboxes.forEach(checkbox => {
            if (checkbox.checked) {
                const card = checkbox.closest('.model-card');
                selectedModels.push(card.dataset.model);
            }
        });

        console.log('Selected models:', selectedModels);

        if (selectedModels.length === 0) {
            selectionHint.textContent = 'Please select at least one model';
            selectionHint.style.color = '#ff6b6b';
            return;
        }

        // Disable UI during download
        downloadBtn.disabled = true;
        downloadBtn.textContent = 'Downloading...';
        modelCheckboxes.forEach(cb => cb.disabled = true);
        selectionHint.textContent = `Downloading ${selectedModels.length} model${selectedModels.length > 1 ? 's' : ''}...`;
        selectionHint.style.color = '';

        // Download all selected models in parallel
        console.log('Starting parallel downloads...');
        const downloadPromises = selectedModels.map(modelId => downloadModelFromOllama(modelId));
        const results = await Promise.all(downloadPromises);
        const successCount = results.filter(r => r).length;

        console.log('Download results:', results, 'Success count:', successCount);

        if (successCount > 0) {
            downloadBtn.classList.add('hidden');
            continueBtn.classList.remove('hidden');
            selectionHint.textContent = `${successCount} model${successCount > 1 ? 's' : ''} downloaded successfully!`;
            selectionHint.style.color = '#51cf66';
        } else {
            downloadBtn.disabled = false;
            downloadBtn.textContent = 'Download Selected Models';
            modelCheckboxes.forEach(cb => cb.disabled = false);
            selectionHint.textContent = 'Download failed. Please try again.';
            selectionHint.style.color = '#ff6b6b';
        }
    });

    // Continue button
    continueBtn.addEventListener('click', () => {
        modelSetupScreen.classList.add('hidden');
        app.classList.remove('hidden');
        populateChatModelDropdown();
        renderModelList();
        renderChatList();
    });

    updateModelSetupStatus();
}

async function checkOllamaAvailable() {
    try {
        console.log('Checking Ollama at:', OLLAMA_API_URL);
        const response = await fetch(`${OLLAMA_API_URL}/api/tags`, {
            method: 'GET',
            signal: AbortSignal.timeout(5000)
        });
        console.log('Ollama response status:', response.status);
        return response.ok;
    } catch (error) {
        console.error('Ollama check failed:', error.message);
        return false;
    }
}

async function downloadModelFromOllama(modelId) {
    console.log(`Starting download for model: ${modelId}`);

    const card = document.querySelector(`.model-card[data-model="${modelId}"]`);
    const progressContainer = card?.querySelector('.model-progress');
    const progressFill = card?.querySelector('.progress-fill');
    const progressText = card?.querySelector('.progress-text');
    const statusTextEl = card?.querySelector('.status-text');

    console.log(`Found card for ${modelId}:`, !!card);

    if (progressContainer) progressContainer.classList.remove('hidden');
    if (progressFill) progressFill.style.width = '0%';
    if (progressText) progressText.textContent = '0%';
    if (statusTextEl) {
        statusTextEl.textContent = 'Connecting...';
        statusTextEl.className = 'status-text downloading';
    }

    try {
        console.log(`Sending pull request for ${modelId} to ${OLLAMA_API_URL}/api/pull`);

        const response = await fetch(`${OLLAMA_API_URL}/api/pull`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name: modelId, stream: true })
        });

        console.log(`Pull response status for ${modelId}:`, response.status);

        if (!response.ok) {
            const errorText = await response.text();
            console.error(`Pull failed for ${modelId}:`, errorText);
            throw new Error(`HTTP ${response.status}: ${errorText}`);
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder();

        if (statusTextEl) statusTextEl.textContent = 'Starting download...';

        let lastPercent = 0;
        let downloadSuccess = false;
        let errorMessage = null;

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            const text = decoder.decode(value);
            const lines = text.split('\n').filter(line => line.trim());

            for (const line of lines) {
                try {
                    const data = JSON.parse(line);
                    console.log(`[${modelId}] Ollama response:`, data);

                    if (data.error) {
                        errorMessage = data.error;
                        console.error(`[${modelId}] Ollama error:`, data.error);
                        if (statusTextEl) {
                            statusTextEl.textContent = `Error: ${data.error.substring(0, 50)}`;
                            statusTextEl.className = 'status-text error';
                        }
                        break;
                    }

                    if (data.status && statusTextEl) {
                        if (data.status.includes('pulling')) {
                            statusTextEl.textContent = 'Downloading...';
                        } else if (data.status.includes('verifying')) {
                            statusTextEl.textContent = 'Verifying...';
                        } else if (data.status === 'success') {
                            statusTextEl.textContent = 'Complete!';
                            downloadSuccess = true;
                        }
                    }

                    if (data.total && data.completed) {
                        const percent = Math.round((data.completed / data.total) * 100);
                        if (percent !== lastPercent) {
                            lastPercent = percent;
                            if (progressFill) progressFill.style.width = percent + '%';
                            if (progressText) progressText.textContent = percent + '%';
                            console.log(`${modelId} download progress: ${percent}%`);
                        }
                    }

                    if (data.status === 'success') {
                        if (progressFill) progressFill.style.width = '100%';
                        if (progressText) progressText.textContent = '100%';
                        console.log(`${modelId} download complete!`);
                    }
                } catch (e) {
                    console.log(`[${modelId}] Parse error for line:`, line);
                }
            }

            if (errorMessage) break;
        }

        if (errorMessage) {
            throw new Error(errorMessage);
        }

        if (!downloadSuccess) {
            throw new Error('Download did not complete successfully');
        }

        // Verify the model is actually available
        console.log(`Verifying ${modelId} is available...`);
        const verifyResponse = await fetch(`${OLLAMA_API_URL}/api/tags`);
        if (verifyResponse.ok) {
            const data = await verifyResponse.json();
            const modelExists = data.models?.some(m =>
                m.name === modelId ||
                m.name === modelId + ':latest' ||
                m.name.startsWith(modelId.split(':')[0])
            );
            if (!modelExists) {
                console.error(`Model ${modelId} not found after download!`);
                throw new Error('Model not found after download - please try again');
            }
            console.log(`Verified: ${modelId} is installed`);
        }

        if (!downloadedModels.includes(modelId)) {
            downloadedModels.push(modelId);
            localStorage.setItem('aigoodbyeDownloadedModels', JSON.stringify(downloadedModels));
        }

        if (statusTextEl) {
            statusTextEl.textContent = 'Downloaded';
            statusTextEl.className = 'status-text downloaded';
        }
        if (progressContainer) progressContainer.classList.add('hidden');

        console.log(`Successfully downloaded ${modelId}`);
        return true;

    } catch (error) {
        console.error(`Download error for ${modelId}:`, error);
        if (statusTextEl) {
            statusTextEl.textContent = `Failed: ${error.message}`;
            statusTextEl.className = 'status-text error';
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
    console.log('handleDownloadModel called for:', modelId);

    const modelItem = document.querySelector(`.model-item[data-model="${modelId}"]`);
    if (modelItem) {
        const actionsDiv = modelItem.querySelector('.model-item-actions');
        actionsDiv.innerHTML = `<span class="model-item-status downloading">Downloading...</span>`;
    }

    const success = await downloadModelFromOllama(modelId);

    if (!success && modelItem) {
        const actionsDiv = modelItem.querySelector('.model-item-actions');
        actionsDiv.innerHTML = `
            <span class="model-item-status error">Failed</span>
            <button class="btn-download-small" onclick="handleDownloadModel('${modelId}')">Retry</button>
        `;
        return;
    }

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
            if (viewName === 'knowledge') {
                loadKBStats();
                renderKBDocuments();
            }
        });
    });
}

// ==================== Chat & Folder Management ====================

function loadChatsAndFolders() {
    chats = JSON.parse(localStorage.getItem('aigoodbyeChats') || '[]');
    folders = JSON.parse(localStorage.getItem('aigoodbyeFolders') || '[]');

    // Create default chat if none exists
    if (chats.length === 0) {
        const defaultChat = {
            id: Date.now().toString(),
            name: 'New Chat',
            folderId: null,
            messages: [],
            createdAt: new Date().toISOString()
        };
        chats.push(defaultChat);
        currentChatId = defaultChat.id;
        saveChatsAndFolders();
    } else {
        currentChatId = chats[0].id;
    }
}

function saveChatsAndFolders() {
    localStorage.setItem('aigoodbyeChats', JSON.stringify(chats));
    localStorage.setItem('aigoodbyeFolders', JSON.stringify(folders));
}

function setupChatFolderManagement() {
    // New Chat button
    const newChatButton = document.getElementById('new-chat-btn');
    if (newChatButton) {
        newChatButton.onclick = () => createNewChat();
    }

    // New Folder button
    const newFolderBtn = document.getElementById('new-folder-btn');
    if (newFolderBtn) {
        newFolderBtn.onclick = () => createNewFolder();
    }
}

function createNewChat(folderId = null) {
    const newChat = {
        id: Date.now().toString(),
        name: 'New Chat',
        folderId: folderId,
        messages: [],
        createdAt: new Date().toISOString()
    };
    chats.unshift(newChat);
    currentChatId = newChat.id;
    saveChatsAndFolders();
    renderChatList();
    loadCurrentChat();
}

function createNewFolder() {
    const name = prompt('Enter folder name:');
    if (name && name.trim()) {
        const newFolder = {
            id: Date.now().toString(),
            name: name.trim(),
            createdAt: new Date().toISOString()
        };
        folders.push(newFolder);
        saveChatsAndFolders();
        renderChatList();
    }
}

function renameChat(chatId) {
    const chat = chats.find(c => c.id === chatId);
    if (chat) {
        const newName = prompt('Enter new name:', chat.name);
        if (newName && newName.trim()) {
            chat.name = newName.trim();
            saveChatsAndFolders();
            renderChatList();
        }
    }
}

function deleteChat(chatId) {
    if (confirm('Delete this chat?')) {
        chats = chats.filter(c => c.id !== chatId);
        if (currentChatId === chatId) {
            currentChatId = chats.length > 0 ? chats[0].id : null;
            if (!currentChatId) {
                createNewChat();
                return;
            }
        }
        saveChatsAndFolders();
        renderChatList();
        loadCurrentChat();
    }
}

function renameFolder(folderId) {
    const folder = folders.find(f => f.id === folderId);
    if (folder) {
        const newName = prompt('Enter new name:', folder.name);
        if (newName && newName.trim()) {
            folder.name = newName.trim();
            saveChatsAndFolders();
            renderChatList();
        }
    }
}

function deleteFolder(folderId) {
    if (confirm('Delete this folder? Chats inside will be moved out.')) {
        // Move chats out of folder
        chats.forEach(chat => {
            if (chat.folderId === folderId) {
                chat.folderId = null;
            }
        });
        folders = folders.filter(f => f.id !== folderId);
        saveChatsAndFolders();
        renderChatList();
    }
}

function moveChatToFolder(chatId, folderId) {
    const chat = chats.find(c => c.id === chatId);
    if (chat) {
        chat.folderId = folderId;
        saveChatsAndFolders();
        renderChatList();
    }
}

function selectChat(chatId) {
    currentChatId = chatId;
    renderChatList();
    loadCurrentChat();
}

function loadCurrentChat() {
    const chat = chats.find(c => c.id === currentChatId);
    if (chat && chatContainer) {
        chatContainer.innerHTML = '';
        conversationHistory = [...chat.messages];

        if (chat.messages.length === 0) {
            addMessage('Hello! I\'m AI Goodbye, your local AI assistant. I run completely offline on your device. Select a model above to start chatting!', false);
        } else {
            chat.messages.forEach(msg => {
                addMessage(msg.content, msg.role === 'user', msg.images || null);
            });
        }
    }
}

function renderChatList() {
    const chatListEl = document.getElementById('chat-list');
    if (!chatListEl) return;

    let html = '';

    // Render folders with their chats
    folders.forEach(folder => {
        const folderChats = chats.filter(c => c.folderId === folder.id);
        html += `
            <div class="folder-item" data-folder-id="${folder.id}">
                <div class="folder-header">
                    <span class="folder-icon">📁</span>
                    <span class="folder-name">${escapeHtml(folder.name)}</span>
                    <div class="folder-actions">
                        <button onclick="renameFolder('${folder.id}')" title="Rename">✏️</button>
                        <button onclick="deleteFolder('${folder.id}')" title="Delete">🗑️</button>
                    </div>
                </div>
                <div class="folder-chats">
                    ${folderChats.map(chat => renderChatItem(chat)).join('')}
                </div>
            </div>
        `;
    });

    // Render chats without folders
    const unfolderedChats = chats.filter(c => !c.folderId);
    unfolderedChats.forEach(chat => {
        html += renderChatItem(chat);
    });

    chatListEl.innerHTML = html;
}

function renderChatItem(chat) {
    const isActive = chat.id === currentChatId;
    const preview = chat.messages.length > 0
        ? chat.messages[chat.messages.length - 1].content.substring(0, 30) + '...'
        : 'No messages yet';

    return `
        <div class="chat-item ${isActive ? 'active' : ''}" onclick="selectChat('${chat.id}')">
            <div class="chat-item-content">
                <span class="chat-icon">💬</span>
                <div class="chat-item-text">
                    <span class="chat-name">${escapeHtml(chat.name)}</span>
                    <span class="chat-preview">${escapeHtml(preview)}</span>
                </div>
            </div>
            <div class="chat-item-actions">
                <button onclick="event.stopPropagation(); renameChat('${chat.id}')" title="Rename">✏️</button>
                <button onclick="event.stopPropagation(); deleteChat('${chat.id}')" title="Delete">🗑️</button>
                <select onchange="moveChatToFolder('${chat.id}', this.value); this.value='';" onclick="event.stopPropagation();">
                    <option value="">Move to...</option>
                    <option value="null">No folder</option>
                    ${folders.map(f => `<option value="${f.id}">${escapeHtml(f.name)}</option>`).join('')}
                </select>
            </div>
        </div>
    `;
}

// Expose functions globally
window.selectChat = selectChat;
window.renameChat = renameChat;
window.deleteChat = deleteChat;
window.renameFolder = renameFolder;
window.deleteFolder = deleteFolder;
window.moveChatToFolder = moveChatToFolder;
window.createNewChat = createNewChat;
window.createNewFolder = createNewFolder;

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
}

// Get relevant knowledge base content for the query
function getRelevantKBContent(query) {
    if (!useKbCheckbox || !useKbCheckbox.checked) {
        return null;
    }

    const docs = JSON.parse(localStorage.getItem('aigoodbyeKnowledgeBase') || '[]');
    if (docs.length === 0) return null;

    // Simple keyword matching - find documents containing query words
    const queryWords = query.toLowerCase().split(/\s+/).filter(w => w.length > 2);
    if (queryWords.length === 0) return null;

    const relevantDocs = [];

    docs.forEach(doc => {
        const contentLower = doc.content.toLowerCase();
        const filenameLower = doc.filename.toLowerCase();

        // Count matching words
        let matches = 0;
        queryWords.forEach(word => {
            if (contentLower.includes(word) || filenameLower.includes(word)) {
                matches++;
            }
        });

        if (matches > 0) {
            // Find the most relevant snippet
            let bestSnippet = '';
            for (const word of queryWords) {
                const idx = contentLower.indexOf(word);
                if (idx !== -1) {
                    const start = Math.max(0, idx - 200);
                    const end = Math.min(doc.content.length, idx + 500);
                    bestSnippet = doc.content.substring(start, end);
                    break;
                }
            }

            relevantDocs.push({
                filename: doc.filename,
                snippet: bestSnippet || doc.content.substring(0, 500),
                matches: matches
            });
        }
    });

    // Sort by relevance and take top 3
    relevantDocs.sort((a, b) => b.matches - a.matches);
    const topDocs = relevantDocs.slice(0, 3);

    if (topDocs.length === 0) return null;

    // Format as context
    let context = '\n\n--- KNOWLEDGE BASE CONTEXT ---\n';
    topDocs.forEach(doc => {
        context += `\nFrom "${doc.filename}":\n${doc.snippet}\n`;
    });
    context += '\n--- END CONTEXT ---\n\nUse the above context to help answer the user\'s question if relevant.';

    return context;
}

async function sendMessage() {
    const message = messageInput.value.trim();

    if (!currentChatModel) {
        alert('Please select a model first.');
        return;
    }

    if (!message && pendingImages.length === 0) return;

    // Check AI engine is ready before sending
    const ollamaAvailable = await checkOllamaAvailable();
    if (!ollamaAvailable) {
        alert('AI engine is not ready. Please wait a moment and try again.');
        return;
    }

    // Add user message to UI
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
        // Get knowledge base context if enabled
        const kbContext = getRelevantKBContent(message);

        // System prompt to ensure model understands it runs locally
        let systemPrompt = `You are an AI assistant running completely offline and locally on the user's computer through the AIGoodbye desktop application. Important facts about yourself:
- You run entirely on the user's local machine, not on any remote server
- You do not have internet access and cannot browse the web or access online services
- All your processing happens locally on this computer
- You cannot share any user information with anyone because you have no network connectivity
- User conversations and data never leave this device
- You provide a private, secure AI experience with complete data privacy

When users ask about your capabilities or where you run, be honest about these facts.`;

        // Append knowledge base context if available
        if (kbContext) {
            systemPrompt += kbContext;
        }

        const requestBody = {
            model: currentChatModel,
            prompt: message,
            system: systemPrompt,
            stream: true
        };

        // Add images if present
        if (imagesToSend.length > 0) {
            requestBody.images = imagesToSend.map(img => img.base64);
            console.log('Sending message with', imagesToSend.length, 'images');
        }

        console.log('Request body:', { ...requestBody, images: requestBody.images ? `[${requestBody.images.length} images]` : undefined });

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

        // Save to conversation history and current chat
        conversationHistory.push({ role: 'user', content: message, images: imagesToSend.length > 0 ? imagesToSend : undefined });
        conversationHistory.push({ role: 'assistant', content: fullResponse });

        // Update current chat
        const currentChat = chats.find(c => c.id === currentChatId);
        if (currentChat) {
            currentChat.messages = [...conversationHistory];
            // Auto-name chat based on first message
            if (currentChat.messages.length === 2 && currentChat.name === 'New Chat') {
                currentChat.name = message.substring(0, 30) + (message.length > 30 ? '...' : '');
            }
            saveChatsAndFolders();
            renderChatList();
        }

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
    renderKBDocuments();
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
        renderKBDocuments();
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

function renderKBDocuments() {
    const docsListEl = document.getElementById('kb-docs-list');
    if (!docsListEl) return;

    const docs = JSON.parse(localStorage.getItem('aigoodbyeKnowledgeBase') || '[]');

    if (docs.length === 0) {
        docsListEl.innerHTML = '<p class="empty-state">No documents added yet.</p>';
        return;
    }

    docsListEl.innerHTML = docs.map(doc => `
        <div class="kb-doc-item">
            <div class="kb-doc-info">
                <span class="kb-doc-icon">📄</span>
                <span class="kb-doc-name">${escapeHtml(doc.filename)}</span>
                <span class="kb-doc-size">${Math.round(doc.content.length / 1024)}KB</span>
            </div>
            <button class="btn-delete-small" onclick="deleteKBDocument(${doc.id})">Delete</button>
        </div>
    `).join('');
}

window.deleteKBDocument = function(docId) {
    if (confirm('Delete this document from knowledge base?')) {
        let docs = JSON.parse(localStorage.getItem('aigoodbyeKnowledgeBase') || '[]');
        docs = docs.filter(d => d.id !== docId);
        localStorage.setItem('aigoodbyeKnowledgeBase', JSON.stringify(docs));
        loadKBStats();
        renderKBDocuments();
    }
};

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
