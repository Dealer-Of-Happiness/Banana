//
//  VoiceInputView.swift
//  DOH AI
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Status indicator
                VStack(spacing: 8) {
                    Image(systemName: isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(isRecording ? .red : .blue)
                        .symbolEffect(.bounce, value: isRecording)

                    Text(isRecording ? "Listening..." : "Tap to speak")
                        .font(.headline)
                        .foregroundStyle(.secondary)
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
                                .fill(isRecording ? .red : .blue)
                                .frame(width: 80, height: 80)

                            if isRecording {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.white)
                                    .frame(width: 24, height: 24)
                            } else {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 60, height: 60)
                            }
                        }
                    }

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
            voiceRecorder.requestPermission()
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

    private func startRecording() {
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
    @Published var isAuthorized = false
    @Published var errorMessage: String?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.isAuthorized = status == .authorized
            }
        }
    }

    func startRecording() {
        errorMessage = nil

        guard isAuthorized else {
            errorMessage = "Speech recognition not authorized"
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
            guard let audioEngine = audioEngine else { return }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else { return }

            recognitionRequest.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // Check if we're in simulator (sampleRate will be 0)
            guard recordingFormat.sampleRate > 0 else {
                errorMessage = "Microphone not available in Simulator. Test on a real device."
                return
            }

            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                if let result = result {
                    DispatchQueue.main.async {
                        self?.transcribedText = result.bestTranscription.formattedString
                    }
                }

                if error != nil || result?.isFinal == true {
                    DispatchQueue.main.async {
                        self?.stopRecording()
                    }
                }
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)

                // Calculate audio level for waveform
                let channelData = buffer.floatChannelData?[0]
                let frameLength = Int(buffer.frameLength)

                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += abs(channelData?[i] ?? 0)
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
        }
    }

    func stopRecording() {
        audioEngine?.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        if let inputNode = audioEngine?.inputNode {
            inputNode.removeTap(onBus: 0)
        }

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
