import Foundation

// Minimal voice descriptor from ElevenLabs' /v1/voices endpoint. Their
// real response has many more fields (labels, description, preview URL,
// settings, permissions); we only need identity + display name for the
// Settings picker.
struct ElevenLabsVoice: Decodable, Sendable, Hashable, Identifiable {
    let voiceID: String
    let name: String

    var id: String { voiceID }

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name
    }
}
