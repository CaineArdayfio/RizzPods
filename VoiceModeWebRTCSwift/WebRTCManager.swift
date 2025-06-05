import WebRTC
import AVFoundation

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

// MARK: - WebRTCManager
class WebRTCManager: NSObject, ObservableObject {
    
    // UI State
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var eventTypeStr: String = ""
    @Published var isMuted: Bool = false
    
    // Basic conversation text
    @Published var conversation: [ConversationItem] = []
    
    // We'll store items by item_id for easy updates
    private var conversationMap: [String : ConversationItem] = [:]

    // Closure to be called when user transcript is completed
    var onUserTranscriptCompleted: (() -> Void)?
    
    // Model & session config
    private var modelName: String = "gpt-4o-mini-realtime-preview-2024-12-17"
    private var systemInstructions: String = ""
    private var voice: String = "alloy"
    
    // WebRTC references
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var audioTrack: RTCAudioTrack?
    private var remoteAudioTrack: RTCAudioTrack?
    
    // Audio routing state
    private var originalVolume: Float = 0.5
    private var isInPrivateMode: Bool = false
    
    // MARK: - Public Methods
    
    /// Start a WebRTC connection using a standard API key for local testing.
    func startConnection(
        apiKey: String,
        modelName: String,
        systemMessage: String,
        voice: String
    ) {
        conversation.removeAll()
        conversationMap.removeAll()
        
        // Store updated config
        self.modelName = modelName
        self.systemInstructions = systemMessage
        self.voice = voice
        
        setupPeerConnection()
        setupLocalAudio()
        configureAudioSession()
        
        guard let peerConnection = peerConnection else { return }
        
        // Create a Data Channel for sending/receiving events
        let config = RTCDataChannelConfiguration()
        if let channel = peerConnection.dataChannel(forLabel: "oai-events", configuration: config) {
            dataChannel = channel
            dataChannel?.delegate = self
        }
        
        // Create an SDP offer
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["levelControl": "true"],
            optionalConstraints: nil
        )
        peerConnection.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self,
                  let sdp = sdp,
                  error == nil else {
                print("Failed to create offer: \(String(describing: error))")
                return
            }
            // Set local description
            peerConnection.setLocalDescription(sdp) { [weak self] error in
                guard let self = self, error == nil else {
                    print("Failed to set local description: \(String(describing: error))")
                    return
                }
                
                Task {
                    do {
                        guard let localSdp = peerConnection.localDescription?.sdp else {
                            return
                        }
                        // Post SDP offer to Realtime
                        let answerSdp = try await self.fetchRemoteSDP(apiKey: apiKey, localSdp: localSdp)
                        
                        // Set remote description (answer)
                        let answer = RTCSessionDescription(type: .answer, sdp: answerSdp)
                        peerConnection.setRemoteDescription(answer) { error in
                            DispatchQueue.main.async {
                                if let error {
                                    print("Failed to set remote description: \(error)")
                                    self.connectionStatus = .disconnected
                                } else {
                                    self.connectionStatus = .connected
                                    // Initialize in normal mode (phone mic, muted output)
                                    self.switchToNormalMode()
                                }
                            }
                        }
                    } catch {
                        print("Error fetching remote SDP: \(error)")
                        self.connectionStatus = .disconnected
                    }
                }
            }
        }
    }
    
    func stopConnection() {
        peerConnection?.close()
        peerConnection = nil
        dataChannel = nil
        audioTrack = nil
        remoteAudioTrack = nil
        connectionStatus = .disconnected
        isInPrivateMode = false
        
        // Reset audio session to default state
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.overrideOutputAudioPort(.none)
        } catch {
            print("Failed to reset audio session: \(error)")
        }
    }
    
    /// Sends a predefined context message to the model
    func sendContextMessage(_ message: String) {
        guard let dc = dataChannel,
              !message.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        
        let realtimeEvent: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": message
                    ]
                ]
            ]
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: realtimeEvent) {
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
            createResponse()
        }
    }

    /// Sends a "response.create" event
    func createResponse() {
        guard let dc = dataChannel else { return }
        
        let realtimeEvent: [String: Any] = [ "type": "response.create" ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: realtimeEvent) {
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
        }
    }
    
    /// Mutes the local audio track and switches to private mode
    func mute() {
        audioTrack?.isEnabled = false
        isMuted = true
        switchToPrivateMode()
    }
    
    /// Unmutes the local audio track and switches to normal mode
    func unmute() {
        audioTrack?.isEnabled = true
        isMuted = false
        switchToNormalMode()
    }
    
    /// Switch to private mode: headphones input/output, WebRTC muted
    private func switchToPrivateMode() {
        guard !isInPrivateMode else { return }
        isInPrivateMode = true
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Try to route to Bluetooth headphones if available
            if let bluetoothInput = findBluetoothInput() {
                try audioSession.setPreferredInput(bluetoothInput)
                if Config.DEBUG {
                    print("✅ Switched to private mode: Using Bluetooth headphones")
                }
                // For Bluetooth, also ensure output goes to the same device
                try audioSession.overrideOutputAudioPort(.none) // Clear any override to use default routing
            } else {
                if Config.DEBUG {
                    print("ℹ️ No Bluetooth found, using built-in devices for private mode")
                }
                // Use built-in speaker for output in private mode
                try audioSession.overrideOutputAudioPort(.speaker)
            }
            
            // Enable remote audio playback (user can hear assistant)
            enableRemoteAudio()
            
        } catch {
            if Config.DEBUG {
                print("Failed to switch to private mode: \(error)")
            }
        }
    }
    
    /// Switch to normal mode: phone mic input, muted output
    private func switchToNormalMode() {
        isInPrivateMode = false
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Route back to built-in microphone
            if let builtInMic = findBuiltInMicrophone() {
                try audioSession.setPreferredInput(builtInMic)
                if Config.DEBUG {
                    print("✅ Switched to normal mode: Using built-in microphone")
                }
            }
            
            // Disable remote audio playback (phone stays silent)
            disableRemoteAudio()
            
        } catch {
            if Config.DEBUG {
                print("Failed to switch to normal mode: \(error)")
            }
        }
    }
    
    /// Enable remote audio track (user can hear assistant)
    private func enableRemoteAudio() {
        guard let peerConnection = peerConnection else { return }
        
        // Find and enable remote audio tracks
        for transceiver in peerConnection.transceivers {
            if let track = transceiver.receiver.track as? RTCAudioTrack {
                track.isEnabled = true
                remoteAudioTrack = track
                if Config.DEBUG {
                    print("✅ Enabled remote audio track")
                }
                break
            }
        }
    }
    
    /// Disable remote audio track (phone stays silent)
    private func disableRemoteAudio() {
        remoteAudioTrack?.isEnabled = false
        if Config.DEBUG {
            print("✅ Disabled remote audio track (phone muted)")
        }
    }
    
    /// Find Bluetooth input device
    private func findBluetoothInput() -> AVAudioSessionPortDescription? {
        let audioSession = AVAudioSession.sharedInstance()
        return audioSession.availableInputs?.first { input in
            input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP
        }
    }
    
    /// Find built-in microphone
    private func findBuiltInMicrophone() -> AVAudioSessionPortDescription? {
        let audioSession = AVAudioSession.sharedInstance()
        return audioSession.availableInputs?.first { input in
            input.portType == .builtInMic
        }
    }
    
    /// Called automatically when data channel opens, or you can manually call it.
    /// Updates session configuration with the latest instructions and voice.
    func sendSessionUpdate() {
        guard let dc = dataChannel, dc.readyState == .open else {
            if Config.DEBUG {
                print("Data channel is not open. Cannot send session.update.")
            }
            return
        }
        
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],  // Enable both text and audio
                "instructions": systemInstructions,
                "voice": voice,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "whisper-1"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": Decimal(string: "0.4")!,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 400,
                    "create_response": true
                ],
                "max_response_output_tokens": "inf"
            ]
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: sessionUpdate)
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
            if Config.DEBUG {
                print("session.update event sent.")
            }
        } catch {
            if Config.DEBUG {
                print("Failed to serialize session.update JSON: \(error)")
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupPeerConnection() {
        let config = RTCConfiguration()
        // If needed, configure ICE servers here
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let factory = RTCPeerConnectionFactory()
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setMode(.voiceChat) // Optimized for voice chat, enables Bluetooth
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Print current route information
            if Config.DEBUG {
                printCurrentAudioRoute()
            }
            
        } catch {
            if Config.DEBUG {
                print("Failed to configure AVAudioSession: \(error)")
            }
        }
    }
    
    private func printCurrentAudioRoute() {
        guard Config.DEBUG else { return }
        
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute
        
        print("🎵 Current Audio Route Information:")
        print("═══════════════════════════════════")
        
        // Print input ports
        print("📥 Input Ports (\(currentRoute.inputs.count)):")
        for (index, input) in currentRoute.inputs.enumerated() {
            print("  Input \(index + 1):")
            printPortDescription(input, prefix: "    ")
        }
        
        // Print output ports
        print("📤 Output Ports (\(currentRoute.outputs.count)):")
        for (index, output) in currentRoute.outputs.enumerated() {
            print("  Output \(index + 1):")
            printPortDescription(output, prefix: "    ")
        }
        
        // Print available inputs
        if let availableInputs = audioSession.availableInputs {
            print("🔍 Available Inputs (\(availableInputs.count)):")
            for (index, input) in availableInputs.enumerated() {
                print("  Available Input \(index + 1):")
                printPortDescription(input, prefix: "    ")
            }
        } else {
            print("🔍 Available Inputs: None")
        }
        
        // Print preferred input
        if let preferredInput = audioSession.preferredInput {
            print("⭐ Preferred Input:")
            printPortDescription(preferredInput, prefix: "  ")
        } else {
            print("⭐ Preferred Input: None")
        }
        
        print("═══════════════════════════════════")
    }
    
    private func printPortDescription(_ port: AVAudioSessionPortDescription, prefix: String = "") {
        print("\(prefix)Port Name: \(port.portName)")
        print("\(prefix)Port Type: \(port.portType.rawValue)")
        print("\(prefix)UID: \(port.uid)")
        print("\(prefix)Has Hardware Voice Call Processing: \(port.hasHardwareVoiceCallProcessing)")
        print("\(prefix)Supports Spatial Audio: \(port.isSpatialAudioEnabled)")
        print("\(prefix)Channels: \(port.channels?.count ?? 0)")
        
        // Print channel information
        if let channels = port.channels {
            for (index, channel) in channels.enumerated() {
                print("\(prefix)  Channel \(index + 1): \(channel.channelName) (Number: \(channel.channelNumber))")
            }
        }
        
        // Print data sources if available
        if let dataSources = port.dataSources {
            print("\(prefix)Data Sources (\(dataSources.count)):")
            for (index, dataSource) in dataSources.enumerated() {
                print("\(prefix)  Data Source \(index + 1):")
                print("\(prefix)    Name: \(dataSource.dataSourceName)")
                print("\(prefix)    ID: \(dataSource.dataSourceID)")
                if let location = dataSource.location {
                    print("\(prefix)    Location: \(location.rawValue)")
                }
                if let orientation = dataSource.orientation {
                    print("\(prefix)    Orientation: \(orientation.rawValue)")
                }
                if let supportedPolarPatterns = dataSource.supportedPolarPatterns {
                    print("\(prefix)    Supported Polar Patterns: \(supportedPolarPatterns.map { $0.rawValue })")
                }
                if let selectedPolarPattern = dataSource.selectedPolarPattern {
                    print("\(prefix)    Selected Polar Pattern: \(selectedPolarPattern.rawValue)")
                }
                if let preferredPolarPattern = dataSource.preferredPolarPattern {
                    print("\(prefix)    Preferred Polar Pattern: \(preferredPolarPattern.rawValue)")
                }
            }
        } else {
            print("\(prefix)Data Sources: None")
        }
        
        print("\(prefix)---")
    }
    
    private func setupLocalAudio() {
        guard let peerConnection = peerConnection else { return }
        let factory = RTCPeerConnectionFactory()
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true",
                "googHighpassFilter": "true"
            ],
            optionalConstraints: nil
        )
        
        let audioSource = factory.audioSource(with: constraints)
        
        let localAudioTrack = factory.audioTrack(with: audioSource, trackId: "local_audio")
        peerConnection.add(localAudioTrack, streamIds: ["local_stream"])
        audioTrack = localAudioTrack
    }
    
    /// Posts our SDP offer to the Realtime API, returns the answer SDP.
    private func fetchRemoteSDP(apiKey: String, localSdp: String) async throws -> String {
        let baseUrl = "https://api.openai.com/v1/realtime"
        guard let url = URL(string: "\(baseUrl)?model=\(modelName)") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = localSdp.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "WebRTCManager.fetchRemoteSDP",
                          code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        
        guard let answerSdp = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "WebRTCManager.fetchRemoteSDP",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to decode SDP"])
        }
        
        return answerSdp
    }
    
    private func handleIncomingJSON(_ jsonString: String) {
        // print("Received JSON:\n\(jsonString)\n")
        
        guard let data = jsonString.data(using: .utf8),
              let rawEvent = try? JSONSerialization.jsonObject(with: data),
              let eventDict = rawEvent as? [String: Any],
              let eventType = eventDict["type"] as? String else {
            return
        }
        
        eventTypeStr = eventType
        
        switch eventType {
        case "conversation.item.created":
            if let item = eventDict["item"] as? [String: Any],
               let itemId = item["id"] as? String,
               let role = item["role"] as? String
            {
                // If item contains "content", extract the text
                let text = (item["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                
                let newItem = ConversationItem(id: itemId, role: role, text: text)
                conversationMap[itemId] = newItem
                if role == "assistant" || role == "user" {
                    conversation.append(newItem)
                }
            }
            
        case "response.audio_transcript.delta":
            // partial transcript for assistant's message
            if let itemId = eventDict["item_id"] as? String,
               let delta = eventDict["delta"] as? String
            {
                if var convItem = conversationMap[itemId] {
                    convItem.text += delta
                    conversationMap[itemId] = convItem
                    if let idx = conversation.firstIndex(where: { $0.id == itemId }) {
                        conversation[idx].text = convItem.text
                    }
                }
            }
            
        case "response.audio_transcript.done":
            // final transcript for assistant's message
            if let itemId = eventDict["item_id"] as? String,
               let transcript = eventDict["transcript"] as? String
            {
                if var convItem = conversationMap[itemId] {
                    convItem.text = transcript
                    conversationMap[itemId] = convItem
                    if let idx = conversation.firstIndex(where: { $0.id == itemId }) {
                        conversation[idx].text = transcript
                    }
                }
            }
            
        case "conversation.item.input_audio_transcription.completed":
            // final transcript for user's audio input
            if let itemId = eventDict["item_id"] as? String,
               let transcript = eventDict["transcript"] as? String
            {
                if var convItem = conversationMap[itemId] {
                    convItem.text = transcript
                    conversationMap[itemId] = convItem
                    if let idx = conversation.firstIndex(where: { $0.id == itemId }) {
                        conversation[idx].text = transcript
                    }
                }
                // Trigger callback when user transcript is completed
                onUserTranscriptCompleted?()
            }
            
        case "session.created":
            if Config.DEBUG {
                print("Session created successfully")
            }
            
        case "error":
            // Handle error events from the API
            if let error = eventDict["error"] as? [String: Any] {
                let errorType = error["type"] as? String ?? "unknown"
                let errorCode = error["code"] as? String ?? "unknown"
                let errorMessage = error["message"] as? String ?? "no message"
                let errorParam = error["param"] as? String ?? "no param"
                
                if Config.DEBUG {
                    print("❌ API Error:")
                    print("  Type: \(errorType)")
                    print("  Code: \(errorCode)")
                    print("  Message: \(errorMessage)")
                    print("  Param: \(errorParam)")
                }
                
                // Update connection status on main thread
                DispatchQueue.main.async {
                    self.connectionStatus = .disconnected
                }
            }
            
        default:
            if Config.DEBUG {
                print("Unhandled event type: \(eventType)")
            }
            break
        }
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if Config.DEBUG {
            print("Remote stream added")
        }
        // Find and store remote audio track
        for track in stream.audioTracks {
            remoteAudioTrack = track
            // Start in normal mode (remote audio disabled)
            track.isEnabled = false
            if Config.DEBUG {
                print("Found remote audio track, initially disabled")
            }
            break
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if Config.DEBUG {
            print("ICE Connection State changed to: \(newState)")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // If the server creates the data channel on its side, handle it here
        dataChannel.delegate = self
    }
}

// MARK: - RTCDataChannelDelegate
extension WebRTCManager: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if Config.DEBUG {
            print("Data channel state changed: \(dataChannel.readyState)")
        }
        // Auto-send session.update after channel is open
        if dataChannel.readyState == .open {
            sendSessionUpdate()
        }
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel,
                     didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let message = String(data: buffer.data, encoding: .utf8) else {
            return
        }
        DispatchQueue.main.async {
            self.handleIncomingJSON(message)
        }
    }
}
