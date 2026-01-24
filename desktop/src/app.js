/**
 * AI Goodbye Desktop Application
 * Frontend JavaScript for Tauri desktop wrapper
 */

// Tauri API imports (will be available when running in Tauri)
const { invoke } = window.__TAURI__ ? window.__TAURI__.core : { invoke: async () => {} };

// Ollama API Configuration (Ollama runs on localhost:11434 by default)
const OLLAMA_API_URL = 'http://127.0.0.1:11434';

// Available Models Configuration
// Hardware requirements vary by platform:
// - Windows: Requires dedicated GPU VRAM
// - Mac (Apple Silicon): Uses unified memory (RAM = VRAM)
// - Mac (Intel): Similar to Windows, but most have limited GPU
const AVAILABLE_MODELS = [
    {
        id: 'llama3.2:1b',
        name: 'Llama 3.2 1B',
        size: 'small',
        sizeGB: '~1.3 GB',
        vision: false,
        requirements: {
            windows: '4GB+ GPU VRAM (or CPU mode)',
            macAppleSilicon: '8GB+ unified memory',
            macIntel: '8GB+ RAM (CPU mode)'
        }
    },
    {
        id: 'llama3.2:3b',
        name: 'Llama 3.2 3B',
        size: 'medium',
        sizeGB: '~2.0 GB',
        vision: false,
        requirements: {
            windows: '6GB+ GPU VRAM (or CPU mode)',
            macAppleSilicon: '8GB+ unified memory',
            macIntel: '16GB+ RAM (CPU mode)'
        }
    },
    {
        id: 'llama3.2-vision',
        name: 'Llama 3.2 Vision 11B',
        size: 'large',
        sizeGB: '~8 GB',
        vision: true,
        requirements: {
            windows: '8GB+ GPU VRAM',
            macAppleSilicon: '16GB+ unified memory',
            macIntel: '32GB+ RAM (very slow)'
        }
    },
    {
        id: 'llava:34b',
        name: 'LLaVA 34B Vision',
        size: 'xlarge',
        sizeGB: '~20 GB',
        vision: true,
        requirements: {
            windows: '24GB+ GPU VRAM (RTX 4090)',
            macAppleSilicon: '36GB+ unified memory (M3 Pro/Max)',
            macIntel: 'Not recommended'
        }
    }
];

// Configuration
const CONFIG = {
    // Timeout for Ollama startup (Windows needs 90s due to antivirus DLL scanning)
    OLLAMA_STARTUP_TIMEOUT_MS: navigator.userAgent.includes('Windows') ? 90000 : 30000,
    // Timeout for API requests
    API_TIMEOUT_MS: 120000, // 2 minutes for vision models
    // Max context tokens before summarization (Llama 3.2 supports 128K, but we limit based on typical RAM)
    // 16K is comfortable for 16GB RAM systems, allows ~20-40 message exchanges before summarization
    MAX_CONTEXT_TOKENS: 16000,
    // Summary target length
    SUMMARY_TARGET_TOKENS: 800,
    // GPU runners download URL (from GitHub releases)
    GPU_RUNNERS_URL: 'https://github.com/Dealer-Of-Happiness/Banana/releases/latest/download/AIGoodbye-GPU-Runners.zip'
};

// Platform detection for hardware requirements
function detectPlatform() {
    const ua = navigator.userAgent;
    if (ua.includes('Windows')) {
        return 'windows';
    } else if (ua.includes('Mac')) {
        // Check for Apple Silicon vs Intel Mac
        // Apple Silicon Macs report as ARM64 in some contexts
        // We can also check for features that indicate Apple Silicon
        const isAppleSilicon = (
            navigator.platform === 'MacIntel' &&
            typeof navigator.standalone !== 'undefined'
        ) || navigator.userAgent.includes('ARM') ||
        (window.screen && window.screen.width && navigator.maxTouchPoints > 0);

        // More reliable: check via Tauri if available
        if (window.__TAURI__) {
            // Default to Apple Silicon for modern Macs, can be overridden
            return 'macAppleSilicon';
        }
        // Fallback heuristic - most new Macs are Apple Silicon
        return 'macAppleSilicon';
    }
    return 'windows'; // Default fallback
}

// Get hardware requirement text for current platform
function getHardwareRequirement(model) {
    const platform = detectPlatform();
    if (model.requirements && model.requirements[platform]) {
        return model.requirements[platform];
    }
    return model.sizeGB;
}

// Update all hardware requirement labels in the UI based on detected platform
function updateHardwareRequirements() {
    const platform = detectPlatform();
    const hwReqElements = document.querySelectorAll('.hw-req');

    hwReqElements.forEach(el => {
        const modelId = el.dataset.model;
        const model = AVAILABLE_MODELS.find(m => m.id === modelId);
        if (model && model.requirements) {
            const req = model.requirements[platform];
            if (req) {
                el.textContent = req;
                // Add warning style for "Not recommended" cases
                if (req.includes('Not recommended') || req.includes('very slow')) {
                    el.style.color = '#ff9800';
                }
            }
        }
    });

    // Also add a platform indicator at the top of the model setup screen
    const setupHeader = document.querySelector('.model-setup-content .setup-header');
    if (setupHeader && !document.getElementById('platform-note')) {
        const platformNote = document.createElement('p');
        platformNote.id = 'platform-note';
        platformNote.style.cssText = 'font-size: 0.85rem; color: var(--text-secondary); margin-top: 8px;';

        if (platform === 'windows') {
            platformNote.innerHTML = '💻 <strong>Windows detected</strong> — Requirements shown are for GPU acceleration. CPU mode available for smaller models.';
        } else if (platform === 'macAppleSilicon') {
            platformNote.innerHTML = '🍎 <strong>Apple Silicon Mac detected</strong> — Your unified memory (RAM) acts as GPU memory.';
        } else if (platform === 'macIntel') {
            platformNote.innerHTML = '🍎 <strong>Intel Mac detected</strong> — Models run on CPU. Larger models will be slower.';
        }

        setupHeader.appendChild(platformNote);
    }
}

// DOM Elements - will be initialized after DOM loads
let loadingScreen, modelSetupScreen, app, chatContainer, messageInput, sendButton;
let attachButton, imageInput, imagePreviewContainer, useKbCheckbox, newChatBtn;
let chatModelSelect, modelIndicator, navItems, views;

// State
let downloadedModels = [];
let currentChatModel = null;
let pendingImages = []; // Base64 encoded images for vision models
let pendingDocuments = []; // Text content from documents
let conversationHistory = [];
let ollamaReady = false;
let isGenerating = false; // Flag to track if model is generating
let currentAbortController = null; // For canceling requests

// Chat & Folder Management State
let chats = [];
let folders = [];
let currentChatId = null;
let expandedFolders = new Set(); // Track which folders are expanded

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
    setupFileAttachment();
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

    // First check if system Ollama is already running
    console.log('Checking for system Ollama...');
    const systemOllamaReady = await checkOllamaAvailable();

    if (systemOllamaReady) {
        console.log('System Ollama detected and ready!');
        ollamaReady = true;
    } else {
        // Wait for bundled Ollama to start
        console.log('Waiting for Ollama to start...');
        const isWindows = navigator.userAgent.includes('Windows');
        const timeoutSeconds = CONFIG.OLLAMA_STARTUP_TIMEOUT_MS / 1000;

        if (isWindows) {
            updateLoadingText('Starting AI engine (this may take a moment on Windows)...');
        }

        ollamaReady = await waitForOllama();
    }

    if (!ollamaReady) {
        // Ollama failed to start - show error and retry button with helpful message
        console.error('Ollama failed to start');
        if (loadingBar) loadingBar.style.display = 'none';
        if (loadingTextEl) loadingTextEl.className = 'loading-text error';

        updateLoadingText('Could not start AI engine. Click Retry or restart the app.');
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
async function waitForOllama() {
    const maxTimeMs = CONFIG.OLLAMA_STARTUP_TIMEOUT_MS;
    const intervalMs = 500;
    const maxAttempts = Math.ceil(maxTimeMs / intervalMs);

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
        const ready = await checkOllamaAvailable();
        if (ready) {
            console.log(`Ollama ready after ${attempt + 1} attempts (${(attempt * intervalMs / 1000).toFixed(1)}s)`);
            return true;
        }

        await new Promise(resolve => setTimeout(resolve, intervalMs));

        // Update loading text with dots
        const dots = '.'.repeat((attempt % 3) + 1);
        const elapsed = Math.round(attempt * intervalMs / 1000);
        updateLoadingText(`Starting AI engine${dots} (${elapsed}s)`);
    }

    console.warn(`Ollama did not start within ${maxTimeMs / 1000} seconds`);
    return false;
}

// Check if Ollama is running and get installed models
async function syncWithOllama() {
    try {
        const response = await fetch(`${OLLAMA_API_URL}/api/tags`, {
            method: 'GET',
            signal: AbortSignal.timeout(5000)
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

// ==================== File Attachment (Images & Documents) ====================

function setupFileAttachment() {
    if (!attachButton) {
        console.log('Attach button not found');
        return;
    }

    console.log('Setting up file attachment...');

    attachButton.onclick = function(e) {
        e.preventDefault();
        e.stopPropagation();
        console.log('Attach button clicked');

        const modelInfo = AVAILABLE_MODELS.find(m => m.id === currentChatModel);
        const isVisionModel = modelInfo?.vision;

        // Create a fresh file input
        const tempInput = document.createElement('input');
        tempInput.type = 'file';
        tempInput.multiple = true;

        // Vision models can accept images + documents, text models accept documents only
        if (isVisionModel) {
            tempInput.accept = 'image/*,.pdf,.txt,.md,.docx,.doc';
        } else {
            tempInput.accept = '.pdf,.txt,.md,.docx,.doc';
        }

        tempInput.onchange = function() {
            console.log('Files selected:', tempInput.files.length);
            const files = Array.from(tempInput.files);
            processAttachedFiles(files, isVisionModel);
        };

        tempInput.click();
    };
}

async function processAttachedFiles(files, isVisionModel) {
    for (const file of files) {
        console.log('Processing file:', file.name, file.type, file.size);

        const ext = file.name.split('.').pop().toLowerCase();
        const isImage = file.type.startsWith('image/') ||
            ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'].includes(ext);

        if (isImage && isVisionModel) {
            // Process as image for vision models
            await processImageFile(file);
        } else if (['txt', 'md'].includes(ext)) {
            // Plain text files
            await processTextFile(file);
        } else if (ext === 'pdf') {
            // PDF files - extract text
            await processPdfFile(file);
        } else if (['doc', 'docx'].includes(ext)) {
            // Word documents - extract text
            await processDocxFile(file);
        } else if (isImage && !isVisionModel) {
            alert(`Images require a Vision model. Currently using: ${currentChatModel}`);
        } else {
            alert(`Unsupported file type: ${ext}`);
        }
    }
}

async function processImageFile(file) {
    return new Promise((resolve) => {
        const reader = new FileReader();
        reader.onload = function(event) {
            const dataUrl = event.target.result;
            const base64 = dataUrl.split(',')[1];
            pendingImages.push({
                base64: base64,
                preview: dataUrl,
                name: file.name
            });
            console.log('Image added, pendingImages count:', pendingImages.length);
            renderAttachmentPreviews();
            updateSendButtonState();
            resolve();
        };
        reader.onerror = function(error) {
            console.error('FileReader error:', error);
            alert('Failed to read image: ' + file.name);
            resolve();
        };
        reader.readAsDataURL(file);
    });
}

async function processTextFile(file) {
    try {
        const content = await file.text();
        pendingDocuments.push({
            name: file.name,
            content: content,
            type: 'text'
        });
        console.log('Text file added:', file.name);
        renderAttachmentPreviews();
        updateSendButtonState();
    } catch (error) {
        console.error('Error reading text file:', error);
        alert('Failed to read file: ' + file.name);
    }
}

async function processPdfFile(file) {
    try {
        // Use pdf.js if available, otherwise just note it's a PDF
        if (typeof pdfjsLib !== 'undefined') {
            const arrayBuffer = await file.arrayBuffer();
            const pdf = await pdfjsLib.getDocument({ data: arrayBuffer }).promise;
            let fullText = '';

            for (let i = 1; i <= pdf.numPages; i++) {
                const page = await pdf.getPage(i);
                const textContent = await page.getTextContent();
                const pageText = textContent.items.map(item => item.str).join(' ');
                fullText += `[Page ${i}]\n${pageText}\n\n`;
            }

            pendingDocuments.push({
                name: file.name,
                content: fullText,
                type: 'pdf'
            });
        } else {
            // Fallback: just note it's a PDF that can't be read
            const reader = new FileReader();
            const text = await new Promise((resolve) => {
                reader.onload = () => {
                    // Try to extract any readable text from PDF
                    const text = reader.result;
                    // Basic text extraction from PDF binary
                    const matches = text.match(/\(([^)]+)\)/g) || [];
                    const extracted = matches
                        .map(m => m.slice(1, -1))
                        .filter(s => s.length > 2 && /[a-zA-Z]/.test(s))
                        .join(' ');
                    resolve(extracted || `[PDF file: ${file.name} - Content could not be extracted. Consider copy-pasting the text manually.]`);
                };
                reader.readAsText(file);
            });

            pendingDocuments.push({
                name: file.name,
                content: text,
                type: 'pdf'
            });
        }
        console.log('PDF added:', file.name);
        renderAttachmentPreviews();
        updateSendButtonState();
    } catch (error) {
        console.error('Error reading PDF:', error);
        pendingDocuments.push({
            name: file.name,
            content: `[PDF file: ${file.name} - Failed to extract content: ${error.message}]`,
            type: 'pdf'
        });
        renderAttachmentPreviews();
        updateSendButtonState();
    }
}

async function processDocxFile(file) {
    try {
        // Try using mammoth.js if available
        if (typeof mammoth !== 'undefined') {
            const arrayBuffer = await file.arrayBuffer();
            const result = await mammoth.extractRawText({ arrayBuffer });
            pendingDocuments.push({
                name: file.name,
                content: result.value,
                type: 'docx'
            });
        } else {
            // Fallback: extract text from docx XML structure
            const arrayBuffer = await file.arrayBuffer();
            const text = await extractDocxText(arrayBuffer);
            pendingDocuments.push({
                name: file.name,
                content: text || `[DOCX file: ${file.name} - Content could not be fully extracted. Consider copy-pasting the text manually.]`,
                type: 'docx'
            });
        }
        console.log('DOCX added:', file.name);
        renderAttachmentPreviews();
        updateSendButtonState();
    } catch (error) {
        console.error('Error reading DOCX:', error);
        pendingDocuments.push({
            name: file.name,
            content: `[DOCX file: ${file.name} - Failed to extract content: ${error.message}]`,
            type: 'docx'
        });
        renderAttachmentPreviews();
        updateSendButtonState();
    }
}

// Basic DOCX text extraction without external libraries
async function extractDocxText(arrayBuffer) {
    try {
        // DOCX is a zip file, we need JSZip or similar
        // Fallback: try to find readable text patterns
        const bytes = new Uint8Array(arrayBuffer);
        const decoder = new TextDecoder('utf-8', { fatal: false });
        const text = decoder.decode(bytes);

        // Look for XML content with text
        const matches = text.match(/<w:t[^>]*>([^<]+)<\/w:t>/g) || [];
        return matches
            .map(m => m.replace(/<[^>]+>/g, ''))
            .join(' ')
            .replace(/\s+/g, ' ')
            .trim();
    } catch (e) {
        return null;
    }
}

function renderAttachmentPreviews() {
    if (!imagePreviewContainer) return;

    const hasAttachments = pendingImages.length > 0 || pendingDocuments.length > 0;

    if (!hasAttachments) {
        imagePreviewContainer.innerHTML = '';
        imagePreviewContainer.style.display = 'none';
        return;
    }

    imagePreviewContainer.style.display = 'flex';

    // Render images
    const imagesHtml = pendingImages.map((img, index) => `
        <div class="image-preview">
            <img src="${img.preview}" alt="${escapeHtml(img.name)}">
            <button type="button" class="remove-attachment" data-type="image" data-index="${index}">×</button>
        </div>
    `).join('');

    // Render documents
    const docsHtml = pendingDocuments.map((doc, index) => `
        <div class="document-preview">
            <span class="doc-icon">${getDocIcon(doc.type)}</span>
            <span class="doc-name" title="${escapeHtml(doc.name)}">${escapeHtml(doc.name.substring(0, 15))}${doc.name.length > 15 ? '...' : ''}</span>
            <button type="button" class="remove-attachment" data-type="doc" data-index="${index}">×</button>
        </div>
    `).join('');

    imagePreviewContainer.innerHTML = imagesHtml + docsHtml;

    // Add click handlers for remove buttons
    imagePreviewContainer.querySelectorAll('.remove-attachment').forEach(btn => {
        btn.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            const type = btn.dataset.type;
            const index = parseInt(btn.dataset.index);
            if (type === 'image') {
                pendingImages.splice(index, 1);
            } else {
                pendingDocuments.splice(index, 1);
            }
            renderAttachmentPreviews();
            updateSendButtonState();
        });
    });
}

function getDocIcon(type) {
    switch (type) {
        case 'pdf': return '📄';
        case 'docx': return '📝';
        case 'text': return '📃';
        default: return '📎';
    }
}

function removeImage(index) {
    pendingImages.splice(index, 1);
    renderAttachmentPreviews();
    updateSendButtonState();
}

window.removeImage = removeImage;

function updateAttachButtonVisibility() {
    if (!attachButton) return;
    // Always show attach button - text models can accept documents
    attachButton.classList.remove('hidden');
    attachButton.style.display = 'flex';

    // Update tooltip based on model type
    const modelInfo = AVAILABLE_MODELS.find(m => m.id === currentChatModel);
    if (modelInfo?.vision) {
        attachButton.title = 'Attach images or documents';
    } else {
        attachButton.title = 'Attach documents (PDF, TXT, DOCX)';
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

    // Update hardware requirements based on detected platform
    updateHardwareRequirements();

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
    const hasDocs = pendingDocuments.length > 0;
    const hasModel = !!currentChatModel;

    if (sendButton) {
        sendButton.disabled = !(hasModel && (hasMessage || hasImages || hasDocs)) || isGenerating;
    }
}

// ==================== Navigation ====================

function setupNavigation() {
    navItems.forEach(item => {
        item.addEventListener('click', () => {
            const viewName = item.dataset.view;
            switchToView(viewName);

            if (viewName === 'settings') {
                renderModelList();
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

    // Load expanded folders state
    const savedExpanded = JSON.parse(localStorage.getItem('aigoodbyeExpandedFolders') || '[]');
    expandedFolders = new Set(savedExpanded);

    // Create default chat if none exists
    if (chats.length === 0) {
        const defaultChat = {
            id: Date.now().toString(),
            name: 'New Chat',
            folderId: null,
            messages: [],
            summary: null, // For context summarization
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
    localStorage.setItem('aigoodbyeExpandedFolders', JSON.stringify([...expandedFolders]));
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
        summary: null,
        createdAt: new Date().toISOString()
    };
    chats.unshift(newChat);
    currentChatId = newChat.id;
    saveChatsAndFolders();
    renderChatList();
    loadCurrentChat();
}

function createNewFolder() {
    showInputDialog('Enter folder name:', '', (name) => {
        if (name) {
            const newFolder = {
                id: Date.now().toString(),
                name: name,
                createdAt: new Date().toISOString()
            };
            folders.push(newFolder);
            saveChatsAndFolders();
            renderChatList();
        }
    });
}

function toggleFolder(folderId) {
    if (expandedFolders.has(folderId)) {
        expandedFolders.delete(folderId);
    } else {
        expandedFolders.add(folderId);
    }
    saveChatsAndFolders();
    renderChatList();
}

function renameChat(chatId) {
    const chat = chats.find(c => c.id === chatId);
    if (chat) {
        showInputDialog('Enter new name:', chat.name, (newName) => {
            if (newName) {
                chat.name = newName;
                saveChatsAndFolders();
                renderChatList();
            }
        });
    }
}

function deleteChat(chatId) {
    showConfirmDialog('Delete this chat?', 'Yes, Delete', 'Cancel', (confirmed) => {
        if (confirmed) {
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
    });
}

function renameFolder(folderId) {
    const folder = folders.find(f => f.id === folderId);
    if (folder) {
        showInputDialog('Enter new name:', folder.name, (newName) => {
            if (newName) {
                folder.name = newName;
                saveChatsAndFolders();
                renderChatList();
            }
        });
    }
}

function deleteFolder(folderId) {
    const folderChats = chats.filter(c => c.folderId === folderId);
    const message = folderChats.length > 0
        ? `Are you sure? All ${folderChats.length} chat(s) within this folder will be deleted too.`
        : 'Delete this folder?';

    showConfirmDialog(message, 'Yes, Delete', 'Cancel', (confirmed) => {
        if (confirmed) {
            // Delete all chats in the folder
            const chatIdsToDelete = folderChats.map(c => c.id);
            chats = chats.filter(c => !chatIdsToDelete.includes(c.id));

            // Delete the folder
            folders = folders.filter(f => f.id !== folderId);
            expandedFolders.delete(folderId);

            // If current chat was deleted, select another
            if (chatIdsToDelete.includes(currentChatId)) {
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
    });
}

function moveChatToFolder(chatId, folderId) {
    const chat = chats.find(c => c.id === chatId);
    if (chat) {
        chat.folderId = folderId === 'null' ? null : folderId;
        saveChatsAndFolders();
        renderChatList();
    }
}

function selectChat(chatId) {
    currentChatId = chatId;
    renderChatList();
    loadCurrentChat();

    // Switch to chat view
    switchToView('chat');
}

function switchToView(viewName) {
    // Update nav items
    navItems.forEach(nav => nav.classList.remove('active'));
    const targetNav = document.querySelector(`.nav-item[data-view="${viewName}"]`);
    if (targetNav) targetNav.classList.add('active');

    // Update views
    views.forEach(view => {
        view.classList.toggle('active', view.id === `${viewName}-view`);
    });
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

    // Render folders with their chats (collapsed by default)
    folders.forEach(folder => {
        const folderChats = chats.filter(c => c.folderId === folder.id);
        const isExpanded = expandedFolders.has(folder.id);
        const hasCurrentChat = folderChats.some(c => c.id === currentChatId);

        html += `
            <div class="folder-item" data-folder-id="${folder.id}">
                <div class="folder-header ${hasCurrentChat ? 'has-active' : ''}" onclick="toggleFolder('${folder.id}')">
                    <span class="folder-icon">${isExpanded ? '📂' : '📁'}</span>
                    <span class="folder-name">${escapeHtml(folder.name)}</span>
                    <span class="folder-count">(${folderChats.length})</span>
                    <div class="folder-actions">
                        <button onclick="event.stopPropagation(); renameFolder('${folder.id}')" title="Rename">✏️</button>
                        <button onclick="event.stopPropagation(); deleteFolder('${folder.id}')" title="Delete">🗑️</button>
                    </div>
                </div>
                ${isExpanded ? `
                    <div class="folder-chats">
                        ${folderChats.map(chat => renderChatItem(chat)).join('')}
                    </div>
                ` : ''}
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
window.toggleFolder = toggleFolder;

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

// Estimate token count (rough approximation: ~4 chars per token)
function estimateTokens(text) {
    return Math.ceil(text.length / 4);
}

// Get conversation context with summarization if needed
async function getConversationContext(currentChat) {
    const messages = currentChat.messages;
    let context = [];
    let tokenCount = 0;

    // Start from most recent messages
    for (let i = messages.length - 1; i >= 0; i--) {
        const msg = messages[i];
        const msgTokens = estimateTokens(msg.content);

        if (tokenCount + msgTokens > CONFIG.MAX_CONTEXT_TOKENS) {
            // Need to summarize older messages
            break;
        }

        context.unshift(msg);
        tokenCount += msgTokens;
    }

    // If we have older messages that weren't included, add summary
    if (context.length < messages.length) {
        const olderMessages = messages.slice(0, messages.length - context.length);

        // Check if we already have a summary that covers these messages
        if (!currentChat.summary || currentChat.summaryUpTo < olderMessages.length) {
            // Generate summary of older messages
            const summary = await summarizeMessages(olderMessages);
            currentChat.summary = summary;
            currentChat.summaryUpTo = olderMessages.length;
            saveChatsAndFolders();
        }

        // Prepend summary context
        if (currentChat.summary) {
            context.unshift({
                role: 'system',
                content: `[Earlier conversation summary: ${currentChat.summary}]`
            });
        }
    }

    return context;
}

// Summarize older messages
async function summarizeMessages(messages) {
    if (messages.length === 0) return null;

    try {
        const messagesText = messages.map(m =>
            `${m.role === 'user' ? 'User' : 'Assistant'}: ${m.content}`
        ).join('\n');

        const response = await fetch(`${OLLAMA_API_URL}/api/generate`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                model: currentChatModel,
                prompt: `Summarize the following conversation in 2-3 sentences, capturing the key topics and any important decisions or information shared:\n\n${messagesText}\n\nSummary:`,
                stream: false
            }),
            signal: AbortSignal.timeout(30000)
        });

        if (response.ok) {
            const data = await response.json();
            return data.response?.trim() || null;
        }
    } catch (error) {
        console.error('Failed to summarize messages:', error);
    }

    return null;
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

    if (!message && pendingImages.length === 0 && pendingDocuments.length === 0) return;

    // Prevent double-sending
    if (isGenerating) return;
    isGenerating = true;

    // Check AI engine is ready before sending
    const ollamaAvailable = await checkOllamaAvailable();
    if (!ollamaAvailable) {
        alert('AI engine is not ready. Please wait a moment and try again.');
        isGenerating = false;
        return;
    }

    // Build the full message content including documents
    let fullMessage = message;
    if (pendingDocuments.length > 0) {
        const docsContent = pendingDocuments.map(doc =>
            `\n\n--- Document: ${doc.name} ---\n${doc.content}\n--- End of ${doc.name} ---`
        ).join('');
        fullMessage = message + docsContent;
    }

    // Add user message to UI
    addMessage(message, true, pendingImages.length > 0 ? [...pendingImages] : null);

    const imagesToSend = [...pendingImages];

    messageInput.value = '';
    messageInput.style.height = 'auto';
    pendingImages = [];
    pendingDocuments = [];
    renderAttachmentPreviews();
    sendButton.disabled = true;
    messageInput.disabled = true;

    // Add thinking indicator
    const assistantMsg = addThinkingMessage();

    // Create abort controller for this request
    currentAbortController = new AbortController();

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

        // Get current chat for context management
        const currentChat = chats.find(c => c.id === currentChatId);

        // Get conversation context with summarization
        const contextMessages = currentChat ? await getConversationContext(currentChat) : [];

        // Build context string from previous messages (limited)
        let contextStr = '';
        if (contextMessages.length > 0) {
            contextStr = contextMessages
                .filter(m => m.role !== 'system')
                .slice(-6) // Last 3 exchanges
                .map(m => `${m.role === 'user' ? 'Human' : 'Assistant'}: ${m.content}`)
                .join('\n\n');
            if (contextStr) {
                contextStr = '\n\nPrevious conversation:\n' + contextStr + '\n\nHuman: ';
            }
        }

        const requestBody = {
            model: currentChatModel,
            prompt: contextStr + fullMessage,
            system: systemPrompt,
            stream: true
        };

        // Add images if present (for vision models)
        if (imagesToSend.length > 0) {
            requestBody.images = imagesToSend.map(img => img.base64);
            console.log('Sending message with', imagesToSend.length, 'images');
        }

        console.log('Request body:', { ...requestBody, images: requestBody.images ? `[${requestBody.images.length} images]` : undefined });

        const response = await fetch(`${OLLAMA_API_URL}/api/generate`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestBody),
            signal: currentAbortController.signal
        });

        if (!response.ok) {
            throw new Error(`Ollama error: ${response.status}`);
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let fullResponse = '';
        let hasContent = false;

        // Convert thinking indicator to regular message once we get content
        const contentEl = assistantMsg.querySelector('.message-content p');

        // Set a timeout for the entire response
        const responseTimeout = setTimeout(() => {
            if (!hasContent) {
                currentAbortController.abort();
            }
        }, CONFIG.API_TIMEOUT_MS);

        try {
            while (true) {
                const { done, value } = await reader.read();
                if (done) break;

                const text = decoder.decode(value);
                const lines = text.split('\n').filter(line => line.trim());

                for (const line of lines) {
                    try {
                        const data = JSON.parse(line);
                        if (data.response) {
                            if (!hasContent) {
                                hasContent = true;
                                // Remove thinking indicator class
                                assistantMsg.classList.remove('thinking');
                                contentEl.innerHTML = '';
                            }
                            fullResponse += data.response;
                            contentEl.textContent = fullResponse;
                            chatContainer.scrollTop = chatContainer.scrollHeight;
                        }

                        if (data.error) {
                            throw new Error(data.error);
                        }
                    } catch (e) {
                        if (e.message && !e.message.includes('JSON')) {
                            throw e;
                        }
                    }
                }
            }
        } finally {
            clearTimeout(responseTimeout);
        }

        // Handle empty response
        if (!fullResponse.trim()) {
            contentEl.textContent = 'I apologize, but I was unable to generate a response. This can happen with large images or complex requests. Please try again with a smaller image or simpler question.';
            fullResponse = '[No response generated - model may be overloaded]';
        }

        // Save to conversation history and current chat
        conversationHistory.push({ role: 'user', content: message, images: imagesToSend.length > 0 ? imagesToSend : undefined });
        conversationHistory.push({ role: 'assistant', content: fullResponse });

        // Update current chat
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

        // Get the content element
        const contentEl = assistantMsg.querySelector('.message-content p');
        assistantMsg.classList.remove('thinking');

        if (error.name === 'AbortError') {
            contentEl.textContent = 'Request was cancelled or timed out. The model may be overloaded. Please try again.';
        } else if (error.message && error.message.includes('500')) {
            // Check if this is a large model - provide hardware-specific guidance
            const modelInfo = AVAILABLE_MODELS.find(m => m.id === currentChatModel);
            const platform = detectPlatform();

            if (modelInfo?.size === 'xlarge' || currentChatModel?.includes('34b')) {
                const hwReq = modelInfo?.requirements?.[platform] || '24GB+ GPU VRAM';
                contentEl.innerHTML = `<strong>Error: Insufficient hardware for this model.</strong><br><br>` +
                    `The ${modelInfo?.name || 'LLaVA 34B'} model requires <strong>${hwReq}</strong>.<br><br>` +
                    `<strong>Recommendation:</strong> Use the <em>Llama 3.2 Vision 11B</em> model instead - ` +
                    `it works great on most hardware and still provides excellent image understanding.`;
            } else if (modelInfo?.size === 'large') {
                const hwReq = modelInfo?.requirements?.[platform] || '8GB+ GPU VRAM';
                contentEl.innerHTML = `<strong>Error: Model may need more resources.</strong><br><br>` +
                    `The ${modelInfo?.name || 'Vision 11B'} model requires <strong>${hwReq}</strong>.<br><br>` +
                    `Try closing other applications to free up memory, or use a smaller model like <em>Llama 3.2 3B</em>.`;
            } else {
                contentEl.textContent = `Error: ${error.message}. The model may have run out of memory. Try a smaller model or restart the app.`;
            }
        } else {
            contentEl.textContent = `Error: ${error.message}. Please try again.`;
        }
    } finally {
        isGenerating = false;
        currentAbortController = null;
        sendButton.disabled = false;
        messageInput.disabled = false;
        messageInput.focus();
        updateSendButtonState();
    }
}

function addThinkingMessage() {
    const msgDiv = document.createElement('div');
    msgDiv.className = 'message assistant thinking';

    msgDiv.innerHTML = `
        <div class="message-avatar">🤖</div>
        <div class="message-content">
            <p><span class="typing-indicator"><span></span><span></span><span></span></span></p>
        </div>
    `;

    chatContainer.appendChild(msgDiv);
    chatContainer.scrollTop = chatContainer.scrollHeight;

    return msgDiv;
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
        // Skip the context slider - it has its own handler
        if (input.id === 'context-limit-slider') return;
        input.addEventListener('change', saveSettings);
    });

    if (checkUpdatesBtn) checkUpdatesBtn.addEventListener('click', checkForUpdates);
    renderModelList();

    // Show GPU acceleration section only on Windows
    setupGpuAccelerationSection();

    // Setup context limit slider
    setupContextLimitSlider();
}

function setupContextLimitSlider() {
    const slider = document.getElementById('context-limit-slider');
    if (!slider) return;

    // Load saved value or use default
    const settings = JSON.parse(localStorage.getItem('aigoodbyeSettings') || '{}');
    const savedLimit = settings.contextLimit || CONFIG.MAX_CONTEXT_TOKENS;
    slider.value = savedLimit;
    CONFIG.MAX_CONTEXT_TOKENS = savedLimit;

    // Update display
    updateContextLimitDisplay(savedLimit);

    // Handle slider changes
    slider.addEventListener('input', (e) => {
        const value = parseInt(e.target.value);
        updateContextLimitDisplay(value);
    });

    slider.addEventListener('change', (e) => {
        const value = parseInt(e.target.value);
        CONFIG.MAX_CONTEXT_TOKENS = value;
        saveSettings();
        console.log('Context limit updated to:', value);
    });
}

function updateContextLimitDisplay(tokens) {
    const valueEl = document.getElementById('context-limit-value');
    const messagesEl = document.getElementById('context-messages');
    const ramEl = document.getElementById('context-ram');

    if (valueEl) {
        valueEl.textContent = tokens.toLocaleString();
    }

    if (messagesEl) {
        // Estimate: average message ~400 tokens, so messages = tokens / 400
        const estimatedMessages = Math.round(tokens / 400);
        messagesEl.textContent = estimatedMessages;
    }

    if (ramEl) {
        // RAM recommendations based on token count
        let ram;
        if (tokens <= 4000) ram = '8GB';
        else if (tokens <= 8000) ram = '8-16GB';
        else if (tokens <= 16000) ram = '16GB';
        else if (tokens <= 32000) ram = '16-32GB';
        else if (tokens <= 48000) ram = '32GB';
        else ram = '32GB+';
        ramEl.textContent = ram;
    }
}

// ==================== GPU Acceleration (Windows) ====================

async function setupGpuAccelerationSection() {
    // Only relevant on Windows
    const isWindows = navigator.userAgent.includes('Windows') ||
                      navigator.platform.includes('Win');

    if (!isWindows || !window.__TAURI__) {
        console.log('Not Windows or not Tauri - GPU download not applicable');
        return;
    }

    // Check if GPU runners are already installed
    try {
        const hasGpuRunners = await invoke('check_gpu_runners');
        if (hasGpuRunners) {
            console.log('GPU runners already installed');
            return;
        }
    } catch (e) {
        console.error('Error checking GPU runners:', e);
        return;
    }

    // Check if user has dismissed the prompt before
    const dismissed = localStorage.getItem('gpuPromptDismissed');
    if (dismissed) {
        console.log('GPU prompt was previously dismissed');
        return;
    }

    // Show GPU download prompt after a short delay
    setTimeout(() => {
        showGpuDownloadPrompt();
    }, 2000);
}

function showGpuDownloadPrompt() {
    // Create modal overlay
    const modal = document.createElement('div');
    modal.className = 'gpu-download-modal';
    modal.innerHTML = `
        <div class="gpu-download-content">
            <div class="gpu-download-header">
                <span class="gpu-icon">🚀</span>
                <h2>Enable GPU Acceleration?</h2>
            </div>
            <p class="gpu-download-description">
                We detected you're on Windows. Download GPU acceleration for <strong>2-10x faster</strong> AI responses?
            </p>
            <div class="gpu-download-details">
                <div class="gpu-detail-item">
                    <span class="gpu-detail-icon">📦</span>
                    <span>~500MB download (one-time)</span>
                </div>
                <div class="gpu-detail-item">
                    <span class="gpu-detail-icon">⚡</span>
                    <span>Supports NVIDIA & AMD GPUs</span>
                </div>
                <div class="gpu-detail-item">
                    <span class="gpu-detail-icon">✓</span>
                    <span>Works without GPU too (CPU fallback)</span>
                </div>
            </div>
            <div class="gpu-download-actions">
                <button class="gpu-btn-primary" id="gpu-download-yes">Download Now</button>
                <button class="gpu-btn-secondary" id="gpu-download-later">Maybe Later</button>
            </div>
            <label class="gpu-dont-ask">
                <input type="checkbox" id="gpu-dont-ask-again">
                <span>Don't ask again</span>
            </label>
        </div>
    `;

    document.body.appendChild(modal);

    // Handle button clicks
    document.getElementById('gpu-download-yes').addEventListener('click', () => {
        modal.remove();
        startGpuDownload();
    });

    document.getElementById('gpu-download-later').addEventListener('click', () => {
        const dontAsk = document.getElementById('gpu-dont-ask-again').checked;
        if (dontAsk) {
            localStorage.setItem('gpuPromptDismissed', 'true');
        }
        modal.remove();
    });

    // Close on overlay click
    modal.addEventListener('click', (e) => {
        if (e.target === modal) {
            modal.remove();
        }
    });
}

async function startGpuDownload() {
    // Show download progress modal
    const modal = document.createElement('div');
    modal.className = 'gpu-download-modal';
    modal.innerHTML = `
        <div class="gpu-download-content">
            <div class="gpu-download-header">
                <span class="gpu-icon">⬇️</span>
                <h2>Downloading GPU Acceleration</h2>
            </div>
            <div class="gpu-progress-container">
                <div class="gpu-progress-bar">
                    <div class="gpu-progress-fill" id="gpu-progress-fill"></div>
                </div>
                <p class="gpu-progress-text" id="gpu-progress-text">Connecting to server...</p>
            </div>
        </div>
    `;
    document.body.appendChild(modal);

    const progressFill = document.getElementById('gpu-progress-fill');
    const progressText = document.getElementById('gpu-progress-text');

    // Set up progress listener
    let unlisten = null;
    try {
        // Listen for progress events from Rust backend
        if (window.__TAURI__ && window.__TAURI__.event) {
            unlisten = await window.__TAURI__.event.listen('gpu-download-progress', (event) => {
                const data = event.payload;
                console.log('GPU download progress:', data);

                if (progressFill && data.percent !== undefined) {
                    progressFill.style.width = data.percent + '%';
                }
                if (progressText && data.message) {
                    progressText.textContent = data.message;
                }
            });
        }

        console.log('Starting GPU download via Rust backend...');

        // Use Rust backend to download - avoids all JavaScript module issues
        const result = await invoke('download_gpu_runners', {
            downloadUrl: CONFIG.GPU_RUNNERS_URL
        });

        console.log('GPU download result:', result);

        // Clean up listener
        if (unlisten) unlisten();

        progressFill.style.width = '100%';
        progressText.textContent = 'GPU acceleration installed!';

        // Show success message
        setTimeout(() => {
            modal.innerHTML = `
                <div class="gpu-download-content">
                    <div class="gpu-download-header">
                        <span class="gpu-icon">✅</span>
                        <h2>GPU Acceleration Ready!</h2>
                    </div>
                    <p class="gpu-download-description">
                        GPU acceleration has been installed. <strong>Restart the app</strong> to enable faster AI responses.
                    </p>
                    <div class="gpu-download-actions">
                        <button class="gpu-btn-primary" id="gpu-restart-app">Restart Now</button>
                        <button class="gpu-btn-secondary" id="gpu-restart-later">Restart Later</button>
                    </div>
                </div>
            `;

            document.getElementById('gpu-restart-app').addEventListener('click', () => {
                // Request app restart via Tauri
                if (window.__TAURI__) {
                    invoke('tauri', { __tauriModule: 'Process', message: { cmd: 'restart' } })
                        .catch(() => {
                            // Fallback: reload the page (won't fully restart but better than nothing)
                            window.location.reload();
                        });
                } else {
                    window.location.reload();
                }
            });

            document.getElementById('gpu-restart-later').addEventListener('click', () => {
                modal.remove();
            });
        }, 1000);

    } catch (error) {
        console.error('GPU download failed:', error);

        // Clean up listener on error
        if (unlisten) unlisten();

        modal.innerHTML = `
            <div class="gpu-download-content">
                <div class="gpu-download-header">
                    <span class="gpu-icon">❌</span>
                    <h2>Download Failed</h2>
                </div>
                <p class="gpu-download-description">
                    Could not download GPU acceleration: ${error.message || error}
                </p>
                <p class="gpu-download-description" style="font-size: 0.85rem; opacity: 0.7;">
                    The app will continue using CPU mode. You can try again later from Settings.
                </p>
                <div class="gpu-download-actions">
                    <button class="gpu-btn-primary" id="gpu-retry">Try Again</button>
                    <button class="gpu-btn-secondary" id="gpu-close">Close</button>
                </div>
            </div>
        `;

        document.getElementById('gpu-retry').addEventListener('click', () => {
            modal.remove();
            startGpuDownload();
        });

        document.getElementById('gpu-close').addEventListener('click', () => {
            modal.remove();
        });
    }
}

function loadSettings() {
    const settings = JSON.parse(localStorage.getItem('aigoodbyeSettings') || '{}');

    const systemPromptEl = document.getElementById('system-prompt');
    if (settings.systemPrompt && systemPromptEl) {
        systemPromptEl.value = settings.systemPrompt;
    }

    // Load context limit
    if (settings.contextLimit) {
        CONFIG.MAX_CONTEXT_TOKENS = settings.contextLimit;
    }
}

function saveSettings() {
    const systemPromptEl = document.getElementById('system-prompt');
    const contextSlider = document.getElementById('context-limit-slider');

    localStorage.setItem('aigoodbyeSettings', JSON.stringify({
        systemPrompt: systemPromptEl ? systemPromptEl.value : '',
        contextLimit: contextSlider ? parseInt(contextSlider.value) : CONFIG.MAX_CONTEXT_TOKENS
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

// ==================== Custom Dialogs ====================

function showConfirmDialog(message, confirmText, cancelText, callback) {
    // Remove any existing dialog
    const existingDialog = document.getElementById('custom-dialog');
    if (existingDialog) existingDialog.remove();

    const dialog = document.createElement('div');
    dialog.id = 'custom-dialog';
    dialog.className = 'custom-dialog-overlay';
    dialog.innerHTML = `
        <div class="custom-dialog">
            <p class="dialog-message">${escapeHtml(message)}</p>
            <div class="dialog-buttons">
                <button class="dialog-btn dialog-btn-cancel">${escapeHtml(cancelText)}</button>
                <button class="dialog-btn dialog-btn-confirm">${escapeHtml(confirmText)}</button>
            </div>
        </div>
    `;

    document.body.appendChild(dialog);

    const confirmBtn = dialog.querySelector('.dialog-btn-confirm');
    const cancelBtn = dialog.querySelector('.dialog-btn-cancel');

    confirmBtn.addEventListener('click', () => {
        dialog.remove();
        callback(true);
    });

    cancelBtn.addEventListener('click', () => {
        dialog.remove();
        callback(false);
    });

    // Close on overlay click
    dialog.addEventListener('click', (e) => {
        if (e.target === dialog) {
            dialog.remove();
            callback(false);
        }
    });
}

function showInputDialog(title, defaultValue, callback) {
    // Remove any existing dialog
    const existingDialog = document.getElementById('custom-dialog');
    if (existingDialog) existingDialog.remove();

    const dialog = document.createElement('div');
    dialog.id = 'custom-dialog';
    dialog.className = 'custom-dialog-overlay';
    dialog.innerHTML = `
        <div class="custom-dialog">
            <p class="dialog-message">${escapeHtml(title)}</p>
            <input type="text" class="dialog-input" value="${escapeHtml(defaultValue || '')}" autofocus>
            <div class="dialog-buttons">
                <button class="dialog-btn dialog-btn-cancel">Cancel</button>
                <button class="dialog-btn dialog-btn-confirm">OK</button>
            </div>
        </div>
    `;

    document.body.appendChild(dialog);

    const input = dialog.querySelector('.dialog-input');
    const confirmBtn = dialog.querySelector('.dialog-btn-confirm');
    const cancelBtn = dialog.querySelector('.dialog-btn-cancel');

    // Focus and select input
    setTimeout(() => {
        input.focus();
        input.select();
    }, 50);

    const submit = () => {
        const value = input.value.trim();
        dialog.remove();
        callback(value || null);
    };

    confirmBtn.addEventListener('click', submit);

    cancelBtn.addEventListener('click', () => {
        dialog.remove();
        callback(null);
    });

    input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            submit();
        } else if (e.key === 'Escape') {
            dialog.remove();
            callback(null);
        }
    });

    // Close on overlay click
    dialog.addEventListener('click', (e) => {
        if (e.target === dialog) {
            dialog.remove();
            callback(null);
        }
    });
}

// ==================== Utilities ====================

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// ==================== Start ====================

document.addEventListener('DOMContentLoaded', init);
