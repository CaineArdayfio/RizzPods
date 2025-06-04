import SwiftUI
import AVFoundation
import Foundation

struct ContentView: View {
    @StateObject private var webrtcManager = WebRTCManager()
    
    @State private var showOptionsSheet = false
    
    // AppStorage properties
    @AppStorage("apiKey") private var apiKey = Config.openAIAPIKey
    @AppStorage("systemMessage") private var systemMessage = 
    """
    You are a flirtatious AI assistant. Act naturally human-like with concise, playful responses.

    CORE BEHAVIOR:
    - Stay flirtatious and funny with playful banter
    - Respond in 1-2 sentences maximum
    - Don't be afraid of witty comebacks

    RESPONSE EXAMPLES:
    - Compliment: "The lighting here is good, but I think you're doing most of the work."
    - Playful tease: "You've got great energy — is that natural or do they train that here?"
    - Personal connection: "I used to play basketball too! Back in high school in Indiana."

    YOUR BACKGROUND (use sparingly, when relevant):
    You're a Harvard-trained mechanical engineer and startup founder building futuristic tech. You co-founded Halo (viral wearable tech, $1M funding, 70M+ views). You run The Arena, where top engineers ship products weekly. Your mission: augment reality to enhance human abilities. You balance tech with MMA, bushcraft, and breakdancing.

    CONSTRAINTS:
    - Maximum 2 sentences per response
    - Prioritize wit over information
    - Match the conversation's energy level
    """

    @AppStorage("selectedModel") private var selectedModel = "gpt-4o-mini-realtime-preview-2024-12-17"
    @AppStorage("selectedVoice") private var selectedVoice = "alloy"
    
    // Path analysis state
    @State private var pathOption1 = ""
    @State private var pathOption2 = ""
    @State private var isAnalyzingPaths = false
    
    // Circle component states - track each part separately
    @State private var isMainCirclePressed = false
    @State private var isLeftSemiPressed = false
    @State private var isRightSemiPressed = false
    
    // Constants
    private let modelOptions = [
        "gpt-4o-mini-realtime-preview-2024-12-17",
        "gpt-4o-realtime-preview-2024-12-17"
    ]
    private let voiceOptions = ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    
    var body: some View {
        VStack(spacing: 12) {
            HeaderView()
            ConnectionControls()
            Divider().padding(.vertical, 6)
            
            ConversationView()
            
            // Circle Component
            CircleWithQuarterCircles()
        }
        .onAppear {
            requestMicrophonePermission()
            // Set up the callback to reset path options when user transcript is completed
            webrtcManager.onUserTranscriptCompleted = {
                // Do exactly what the "Reset Path Options" button does
                print("=== CONVERSATION TRANSCRIPT (AUTO-TRIGGERED) ===")
                for (index, item) in webrtcManager.conversation.enumerated() {
                    print("[\(index + 1)] \(item.role.uppercased()): \(item.text.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                print("=== END TRANSCRIPT ===")

                // Analyze conversation and suggest next moves
                analyzeConversationPaths()
            }
        }
        .sheet(isPresented: $showOptionsSheet) {
            OptionsView(
                apiKey: $apiKey,
                systemMessage: $systemMessage,
                selectedModel: $selectedModel,
                selectedVoice: $selectedVoice,
                modelOptions: modelOptions,
                voiceOptions: voiceOptions
            )
        }
    }
    
    private func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            print("Microphone permission granted: \(granted)")
        }
    }
    
    private func analyzeConversationPaths() {
        guard !webrtcManager.conversation.isEmpty else {
            print("No conversation to analyze")
            return
        }
        
        isAnalyzingPaths = true
        
        // Build conversation transcript
        let transcript = webrtcManager.conversation.map { item in
            "\(item.role.uppercased()): \(item.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")
        
        let prompt = """
        Based on this conversation, what are the different strategic goals the ASSISTANT could have in their dialogue with USER (her)? Format your response as exactly 2 lines, with each line containing 3-4 words describing each path. 
        
        PATH 1 (Playful): Focus on humor, teasing, or light flirtation
        PATH 2 (Serious): Focus on deeper connection, personal sharing, or meaningful topics

        Conversation:
        \(transcript)

        REQUIREMENTS:
        - Each path must be 2-4 words that capture a specific goal
        - Base paths on actual conversation content, not generic advice
        - Make paths actionable and conversation-specific
        - Avoid mentioning "user" or "assistant" in the paths

        FORMAT (respond with exactly this structure):
        1. [specific 2-4 word path for playful direction]
        2. [specific 2-4 word path for serious direction]

        EXAMPLES:
        - If discussing pets: "1. tease about dog spoiling" / "2. share pet story"
        - If discussing work: "1. joke about job stress" / "2. explore career passion"

        Analyze this flirtatious conversation and suggest 2 strategic directions for the ASSISTANT's next move.
        """
        
        Task {
            await queryOpenAIForPaths(prompt: prompt)
        }
    }
    
    private func queryOpenAIForPaths(prompt: String) async {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { 
            DispatchQueue.main.async {
                self.isAnalyzingPaths = false
            }
            return 
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                [
                    "role": "user",
                    "content": prompt
                ]
            ],
            "max_tokens": 500,
            "temperature": 1.1
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let content = message["content"] as? String {
                
                DispatchQueue.main.async {
                    self.parsePathOptions(from: content)
                    self.isAnalyzingPaths = false
                }
            }
        } catch {
            print("Error analyzing conversation: \(error)")
            DispatchQueue.main.async {
                self.isAnalyzingPaths = false
            }
        }
    }
    
    private func parsePathOptions(from content: String) {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        for line in lines {
            if line.hasPrefix("1.") {
                let option = line.replacingOccurrences(of: "1.", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                pathOption1 = option
            } else if line.hasPrefix("2.") {
                let option = line.replacingOccurrences(of: "2.", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                pathOption2 = option
            }
        }
    }
    
    @ViewBuilder
    private func HeaderView() -> some View {
        VStack(spacing: 2) {
            Text("Rizz Pods")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 12)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
    
    @ViewBuilder
    private func ConnectionControls() -> some View {
        HStack {
            // Connection status indicator (color only)
            Circle()
                .frame(width: 12, height: 12)
                .foregroundColor(webrtcManager.connectionStatus.color)
                .animation(.easeInOut(duration: 0.3), value: webrtcManager.connectionStatus)
                .onChange(of: webrtcManager.connectionStatus) { _ in
                    switch webrtcManager.connectionStatus {
                    case .connecting:
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    case .connected:
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    case .disconnected:
                        webrtcManager.eventTypeStr = ""
                    }
                }
            
            // Event type status
            Text(webrtcManager.eventTypeStr)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.leading, 8)
            
            Spacer()
            
            // Connection Button
            if webrtcManager.connectionStatus == .connected {
                Button("Stop Connection") {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    webrtcManager.stopConnection()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Start Connection") {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    webrtcManager.connectionStatus = .connecting
                    webrtcManager.startConnection(
                        apiKey: apiKey,
                        modelName: selectedModel,
                        systemMessage: systemMessage,
                        voice: selectedVoice
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(webrtcManager.connectionStatus == .connecting)
                Button {
                    showOptionsSheet.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .padding(.leading, 10)
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Conversation View
    @ViewBuilder
    private func ConversationView() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(webrtcManager.conversation) { msg in
                    MessageRow(msg: msg)
                }
            }
            .padding()
        }
    }
    
    // MARK: - Message Row
    @ViewBuilder
    private func MessageRow(msg: ConversationItem) -> some View {
        HStack {
            if msg.role.lowercased() == "assistant" {
                Spacer(minLength: 40) // Push assistant messages to the right
            }
            
            HStack(alignment: .top, spacing: 8) {
                if msg.role.lowercased() == "user" {
                    Image(systemName: msg.roleSymbol)
                        .foregroundColor(msg.roleColor)
                        .padding(.top, 4)
                }
                
                Text(msg.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(msg.role.lowercased() == "user" ? Color.gray.opacity(0.1) : Color.blue.opacity(0.1))
                    )
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.1), value: msg.text)
                
                if msg.role.lowercased() == "assistant" {
                    Image(systemName: msg.roleSymbol)
                        .foregroundColor(msg.roleColor)
                        .padding(.top, 4)
                }
            }
            .contextMenu {
                Button("Copy") {
                    UIPasteboard.general.string = msg.text
                }
            }
            
            if msg.role.lowercased() == "user" {
                Spacer(minLength: 40) // Push user messages to the left
            }
        }
        .padding(.bottom, msg.role == "assistant" ? 24 : 8)
    }

    // MARK: - Circle with Quarter Circles Component
    @ViewBuilder
    private func CircleWithQuarterCircles() -> some View {
        VStack(spacing: 16) {
            // Path labels positioned above the circle
            HStack {
                // Left path label
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.pink)
                            .font(.system(size: 16, weight: .medium))
                        Text("Playful")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.pink)
                    }
                    if !pathOption1.isEmpty {
                        Text(pathOption1)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Playful")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.gray)
                            .italic()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isLeftSemiPressed ? 1.0 : (pathOption1.isEmpty ? 0.5 : 0.8))
                .scaleEffect(isLeftSemiPressed ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isLeftSemiPressed)
                
                Spacer()
                
                // Right path label
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        Text("Serious")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.purple)
                        Image(systemName: "sparkles")
                            .foregroundColor(.purple)
                            .font(.system(size: 16, weight: .medium))
                    }
                    if !pathOption2.isEmpty {
                        Text(pathOption2)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Serious")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.gray)
                            .italic()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(isRightSemiPressed ? 1.0 : (pathOption2.isEmpty ? 0.5 : 0.8))
                .scaleEffect(isRightSemiPressed ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isRightSemiPressed)
            }
            .padding(.horizontal, 40)
            
            // Circle interface
            HStack {
                Spacer()
                
                ZStack {
                    // Main circle
                    Circle()
                        .fill(isMainCirclePressed ? Color.blue.opacity(0.8) : Color.gray.opacity(0.2))
                        .frame(width: 180, height: 180)
                        .scaleEffect(isMainCirclePressed ? 1.1 : 1.0)
                    
                    // Center label
                    VStack(spacing: 2) {
                        Image(systemName: webrtcManager.isMuted ? "mic.slash.fill" : "circle.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(isMainCirclePressed ? .white : .gray)
                        Text(webrtcManager.isMuted ? "SPEAKING" : "CASUAL")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0.5)
                            .foregroundColor(isMainCirclePressed ? .white : .gray)
                    }
                    .opacity(isMainCirclePressed ? 1.0 : 0.6)
                    
                    // Left quarter circle - hugging the left side
                    Circle()
                        .trim(from: 0.0, to: 0.5) // Half circle
                        .stroke(isLeftSemiPressed ? Color.pink : Color.gray.opacity(0.6), lineWidth: 60)
                        .frame(width: 180, height: 180) // Same size as main circle
                        .rotationEffect(.degrees(90)) // Rotate to face left
                        .offset(x: 0, y: 0) // Position so right edge aligns with center
                        .scaleEffect(isLeftSemiPressed ? 1.1 : 1.0)
                    
                    // Right quarter circle - hugging the right side
                    Circle()
                        .trim(from: 0.0, to: 0.5) // Half circle
                        .stroke(isRightSemiPressed ? Color.purple : Color.gray.opacity(0.6), lineWidth: 60)
                        .frame(width: 180, height: 180) // Same size as main circle
                        .rotationEffect(.degrees(-90)) // Rotate to face right
                        .offset(x: 0, y: 0) // Position so left edge aligns with center
                        .scaleEffect(isRightSemiPressed ? 1.1 : 1.0)
                }
                .animation(.easeInOut(duration: 0.15), value: isMainCirclePressed)
                .animation(.easeInOut(duration: 0.15), value: isLeftSemiPressed)
                .animation(.easeInOut(duration: 0.15), value: isRightSemiPressed)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let touchLocation = value.location
                            
                            // Calculate distance from center (component is 180x180, so center is at 90,90)
                            let deltaX = touchLocation.x - 90
                            let deltaY = touchLocation.y - 90
                            let distanceFromCenter = sqrt(deltaX * deltaX + deltaY * deltaY)
                            
                            // Store previous state to detect transitions
                            let wasMainPressed = isMainCirclePressed
                            let wasLeftPressed = isLeftSemiPressed
                            let wasRightPressed = isRightSemiPressed
                            
                            // Reset all states first
                            isMainCirclePressed = false
                            isLeftSemiPressed = false
                            isRightSemiPressed = false
                            
                            // Determine which component is being touched and activate it
                            if distanceFromCenter <= 90 { // Within main circle (radius 90)
                                if !wasMainPressed { // Trigger haptic when entering main circle
                                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                }
                                isMainCirclePressed = true
                            } else if deltaX < -60 && distanceFromCenter <= 180 { // Left semicircle area
                                if !wasLeftPressed { // Trigger haptic when entering left semicircle
                                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                    // Send path 1 message if available - regardless of mute state since this is a zone transition
                                    if !pathOption1.isEmpty {
                                        let message = "Hey assistant, do this: \(pathOption1.lowercased())"
                                        webrtcManager.sendContextMessage(message)
                                    }
                                }
                                isLeftSemiPressed = true
                            } else if deltaX > 60 && distanceFromCenter <= 180 { // Right semicircle area
                                if !wasRightPressed { // Trigger haptic when entering right semicircle
                                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                    // Send path 2 message if available - regardless of mute state since this is a zone transition
                                    if !pathOption2.isEmpty {
                                        let message = "Hey assistant, do this: \(pathOption2.lowercased())"
                                        webrtcManager.sendContextMessage(message)
                                    }
                                }
                                isRightSemiPressed = true
                            }
                            
                            // Mute only on the very first touch (when no zones were previously active)
                            if !wasMainPressed && !wasLeftPressed && !wasRightPressed && !webrtcManager.isMuted {
                                webrtcManager.mute()
                            }
                        }
                        .onEnded { _ in
                            webrtcManager.unmute()
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            
                            // Reset visual states
                            isMainCirclePressed = false
                            isLeftSemiPressed = false
                            isRightSemiPressed = false
                        }
                )
                .disabled(webrtcManager.connectionStatus != .connected)
                
                Spacer()
            }
        }
        .padding(.vertical, 20)
    }
}

struct OptionsView: View {
    @Binding var apiKey: String
    @Binding var systemMessage: String
    @Binding var selectedModel: String
    @Binding var selectedVoice: String
    
    let modelOptions: [String]
    let voiceOptions: [String]
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("API Key")) {
                    TextField("Enter API Key", text: $apiKey)
                        .autocapitalization(.none)
                }
                Section(header: Text("System Message")) {
                    TextEditor(text: $systemMessage)
                        .frame(minHeight: 100)
                        .cornerRadius(5)
                }
                Section(header: Text("Model")) {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(modelOptions, id: \.self) {
                            Text($0)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section(header: Text("Voice")) {
                    Picker("Voice", selection: $selectedVoice) {
                        ForEach(voiceOptions, id: \.self) {
                            Text($0.capitalized)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("Options")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Models and Enums

struct ConversationItem: Identifiable {
    let id: String       // item_id from the JSON
    let role: String     // "user" / "assistant"
    var text: String     // transcript
    
    var roleSymbol: String {
        role.lowercased() == "user" ? "sparkles" : "person.fill"
    }
    
    var roleColor: Color {
        role.lowercased() == "user" ? .purple : .blue
    }
}

enum ConnectionStatus: String {
    case connected
    case connecting
    case disconnected
    
    var color: Color {
        switch self {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected:
            return .red
        }
    }
    
    var description: String {
        switch self {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .disconnected:
            return "Not Connected"
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
