import Foundation

struct XMPBuilder: Sendable {
    func stars(for composite: Double) -> Int {
        if composite >= 9 { return 5 }
        if composite >= 7.5 { return 4 }
        if composite >= 6 { return 3 }
        if composite >= 4 { return 2 }
        return 1
    }

    func sidecar(for photo: ScoredPhoto) -> String {
        let score = photo.score
        var description = ["SoccerShots: \(String(format: "%.1f", score.composite))/10"]
        if score.actionType != .unknown { description.append(score.actionType.rawValue) }
        if let number = score.jerseyNumber { description.append("#\(number)") }
        if let color = score.jerseyColor { description.append(color) }
        if !score.lightroomSuggestions.isEmpty { description.append(score.lightroomSuggestions.joined(separator: " · ")) }
        let crs = developAttributes(score.developSettings)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="SoccerShots">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmp:Rating="\(stars(for: score.composite))"\(crs)>
              <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(escape(description.joined(separator: " | ")))</rdf:li></rdf:Alt></dc:description>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }

    func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func developAttributes(_ settings: DevelopSettings) -> String {
        var values: [(String, String)] = []
        if let value = settings.exposure2012 { values.append(("Exposure2012", value)) }
        if let value = settings.highlights2012 { values.append(("Highlights2012", String(value))) }
        if let value = settings.shadows2012 { values.append(("Shadows2012", String(value))) }
        if let value = settings.whites2012 { values.append(("Whites2012", String(value))) }
        if let value = settings.blacks2012 { values.append(("Blacks2012", String(value))) }
        if let value = settings.clarity2012 { values.append(("Clarity2012", String(value))) }
        if let value = settings.vibrance { values.append(("Vibrance", String(value))) }
        if let value = settings.saturation { values.append(("Saturation", String(value))) }
        if let value = settings.luminanceSmoothing { values.append(("LuminanceSmoothing", String(value))) }
        if let value = settings.colorNoiseReduction { values.append(("ColorNoiseReduction", String(value))) }
        if let value = settings.whiteBalance { values.append(("WhiteBalance", value)) }
        guard !values.isEmpty else { return "" }
        return "\n              xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\"\n              crs:ProcessVersion=\"11.0\"" +
            "\n              crs:HasSettings=\"True\"\n              crs:AlreadyApplied=\"False\"" +
            values.map { "\n              crs:\($0.0)=\"\(escape($0.1))\"" }.joined()
    }
}
