//
//  VoiceInputView.swift
//  AI goodbye
//
//  Voice input interface with waveform visualization
//

import SwiftUI
import Speech
import Combine
import AVFoundation

struct VoiceInputView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voiceRecorder = VoiceRecorder()
    @State private var isRecording = false
    @State private var transcribedText = ""
    @State private var waveformValues: [CGFloat] = Array(repeating: 0.3, count: 30)
    @State private var isCheckingPermissions = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Status indicator
                VStack(spacing: 8) {
                    if isCheckingPermissions {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Requesting permissions...")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    } else if !voiceRecorder.isAuthorized {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.red)
                        Text("Permissions required")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: isRecording ? "waveform" : "mic.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(isRecording ? .red : .blue)
                            .symbolEffect(.bounce, value: isRecording)
                        Text(isRecording ? "Listening..." : "Tap to speak")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Waveform visualization
                if isRecording {
                    WaveformView(values: waveformValues)
                        .frame(height: 80)
                        .padding(.horizontal)
                }

                // Error message
                if let error = voiceRecorder.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Transcribed text
                if !transcribedText.isEmpty {
                    ScrollView {
                        Text(transcribedText)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .frame(maxHeight: 150)
                    .padding(.horizontal)
                }

                Spacer()

                // Controls
                HStack(spacing: 40) {
                    // Cancel button
                    Button {
                        stopRecording()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.gray)
                    }

                    // Record button
                    Button {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(canRecord ? (isRecording ? .red : .blue) : .gray)
                                .frame(width: 80, height: 80)

                            if isRecording {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.white)
                                    .frame(width: 24, height: 24)
                            } else {
                                Circle()
                                    .fill(.white.opacity(canRecord ? 1 : 0.5))
                                    .frame(width: 60, height: 60)
                            }
                        }
                    }
                    .disabled(!canRecord)

                    // Send button
                    Button {
                        sendVoiceMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(transcribedText.isEmpty ? .gray : .green)
                    }
                    .disabled(transcribedText.isEmpty)
                }
                .padding(.bottom, 40)
            }
            .navigationTitle("Voice Input")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stopRecording()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            Task {
                await voiceRecorder.requestPermissionAsync()
                isCheckingPermissions = false
            }
        }
        .onDisappear {
            stopRecording()
        }
        .onChange(of: voiceRecorder.transcribedText) { _, newValue in
            transcribedText = newValue
        }
        .onChange(of: voiceRecorder.audioLevel) { _, newValue in
            updateWaveform(with: newValue)
        }
    }

    // Can only record when not checking permissions and authorized
    private var canRecord: Bool {
        !isCheckingPermissions && voiceRecorder.isAuthorized
    }

    private func startRecording() {
        guard canRecord else { return }
        isRecording = true
        voiceRecorder.startRecording()
    }

    private func stopRecording() {
        isRecording = false
        voiceRecorder.stopRecording()
    }

    private func sendVoiceMessage() {
        guard !transcribedText.isEmpty else { return }
        Task {
            await viewModel.sendVoiceMessage(transcribedText)
            dismiss()
        }
    }

    private func updateWaveform(with level: CGFloat) {
        waveformValues.removeFirst()
        waveformValues.append(level)
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let values: [CGFloat]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<values.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 4, height: max(8, values[index] * 80))
                    .animation(.easeInOut(duration: 0.1), value: values[index])
            }
        }
    }
}

// MARK: - Voice Recorder

@MainActor
class VoiceRecorder: ObservableObject {
    @Published var transcribedText = ""
    @Published var audioLevel: CGFloat = 0.3
    @Published var isSpeechAuthorized = false
    @Published var isMicrophoneAuthorized = false
    @Published var errorMessage: String?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    var isAuthorized: Bool {
        isSpeechAuthorized && isMicrophoneAuthorized
    }

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        // Check current permission status on init
        checkCurrentPermissions()
    }

    private func checkCurrentPermissions() {
        // Check microphone status
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            isMicrophoneAuthorized = true
        case .denied:
            isMicrophoneAuthorized = false
        case .undetermined:
            isMicrophoneAuthorized = false
        @unknown default:
            isMicrophoneAuthorized = false
        }

        // Check speech recognition status
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            isSpeechAuthorized = true
        case .denied, .restricted:
            isSpeechAuthorized = false
        case .notDetermined:
            isSpeechAuthorized = false
        @unknown default:
            isSpeechAuthorized = false
        }
    }

    func requestPermission() {
        // Request microphone first using the older reliable API
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.isMicrophoneAuthorized = granted
                if !granted {
                    self?.errorMessage = "Microphone access is required. Please enable in Settings."
                }
            }
        }

        // Request speech recognition permission
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.isSpeechAuthorized = status == .authorized
                if status != .authorized {
                    self?.errorMessage = "Speech recognition is required. Please enable in Settings."
                }
            }
        }
    }

    // Async version that waits for both permissions
    func requestPermissionAsync() async {
        // Check if already authorized
        checkCurrentPermissions()
        if isAuthorized {
            return
        }

        // Request microphone permission using the older API (more reliable)
        if !isMicrophoneAuthorized {
            let micGranted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            isMicrophoneAuthorized = micGranted
            if !micGranted {
                errorMessage = "Microphone access is required. Please enable in Settings."
            }
        }

        // Request speech recognition permission
        if !isSpeechAuthorized {
            let speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            isSpeechAuthorized = speechStatus == .authorized
            if speechStatus != .authorized && errorMessage == nil {
                errorMessage = "Speech recognition is required. Please enable in Settings."
            }
        }
    }

    func startRecording() {
        errorMessage = nil

        // Check microphone permission
        guard isMicrophoneAuthorized else {
            errorMessage = "Microphone access not authorized. Please enable in Settings."
            return
        }

        // Check speech recognition permission
        guard isSpeechAuthorized else {
            errorMessage = "Speech recognition not authorized. Please enable in Settings."
            return
        }

        guard speechRecognizer?.isAvailable == true else {
            errorMessage = "Speech recognition is not available on this device."
            return
        }

        // Cancel any existing task
        stopRecording()

        do {
            // Configure audio session
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else {
                errorMessage = "Failed to initialize audio engine"
                return
            }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                errorMessage = "Failed to create recognition request"
                return
            }

            recognitionRequest.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // Check if we're in simulator or no mic available
            guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
                errorMessage = "Microphone not available. Please test on a real device."
                return
            }

            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                if let result = result {
                    DispatchQueue.main.async {
                        self?.transcribedText = result.bestTranscription.formattedString
                    }
                }

                if let error = error {
                    DispatchQueue.main.async {
                        self?.errorMessage = "Recognition error: \(error.localizedDescription)"
                        self?.stopRecording()
                    }
                } else if result?.isFinal == true {
                    DispatchQueue.main.async {
                        self?.stopRecording()
                    }
                }
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)

                // Calculate audio level for waveform
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0 else { return }

                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += abs(channelData[i])
                }
                let average = sum / Float(frameLength)

                DispatchQueue.main.async {
                    self?.audioLevel = CGFloat(min(1, average * 10))
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            errorMessage = "Recording failed: \(error.localizedDescription)"
            stopRecording()
        }
    }

    func stopRecording() {
        // Safely stop the audio engine
        if audioEngine?.isRunning == true {
            audioEngine?.stop()
        }

        // End the recognition request
        recognitionRequest?.endAudio()

        // Cancel any ongoing recognition task
        recognitionTask?.cancel()

        // Remove the tap from input node
        if let inputNode = audioEngine?.inputNode {
            inputNode.removeTap(onBus: 0)
        }

        // Deactivate audio session
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Ignore errors when deactivating
        }

        // Clear references
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
    }

    func setLanguage(_ locale: String) {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
    }
}

#Preview {
    VoiceInputView(viewModel: ChatViewModel())
}
