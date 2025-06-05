import Foundation

struct Config {
    // Debug flag - set to false in production to improve performance
    static let DEBUG = false
    
    static let openAIAPIKey: String = {
        // First try environment variable (for development)
        if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        
        // If no environment variable, show error with instructions
        fatalError("OPENAI_API_KEY not found. Please set it as an environment variable in Xcode scheme.")
    }()
} 
