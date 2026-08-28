import Foundation
import Testing
@testable import SoccerShots

@Suite("Validated SoccerShots rules")
struct ScoringTests {
    @Test func compositeExcludesNullableBallScore() throws {
        let json = """
        {"auto_reject":false,"sharpness_score":8,"face_eyes_score":8,"peak_action_score":9,"ball_in_frame_score":null,"exposure_score":7,"composition_score":6,"convergence_score":8,"lightroom_suggestions":[],"develop_settings":{},"keep_recommendation":true,"reject_reason":null,"jersey_number":"7","jersey_color":"blue","action_type":"celebration"}
        """
        let score = try ScoringParser().parse(json)
        #expect(score.composite == 7.9)
        #expect(score.ballInFrame == nil)
        #expect(score.keepRecommendation)
    }

    @Test func sharpnessAtTwoAlwaysAutoRejects() throws {
        let score = try ScoringParser().parse("""
        {"auto_reject":false,"sharpness_score":2,"keep_recommendation":true,"action_type":"shot"}
        """)
        #expect(score.autoReject)
        #expect(score.composite == 0)
        #expect(!score.keepRecommendation)
        #expect(score.actionType == .unknown)
    }

    @Test func parserExtractsFencedJSONAndRepairsTrailingComma() throws {
        let score = try ScoringParser().parse("""
        Here is the result:
        ```json
        {"auto_reject":true,"sharpness_score":1,"reject_reason":"Blurred face",}
        ```
        """)
        #expect(score.autoReject)
        #expect(score.rejectReason == "Blurred face")
    }

    @Test func rawJPEGPairPrefersRAW() {
        let date = Date()
        let raw = DiscoveredPhoto(id: URL(fileURLWithPath: "/game/IMG_1.CR3"), url: URL(fileURLWithPath: "/game/IMG_1.CR3"), fileSize: 10, modificationDate: date, captureDate: nil)
        let jpeg = DiscoveredPhoto(id: URL(fileURLWithPath: "/game/IMG_1.jpg"), url: URL(fileURLWithPath: "/game/IMG_1.jpg"), fileSize: 5, modificationDate: date, captureDate: nil)
        let result = PhotoDiscovery.preferRAW([jpeg, raw])
        #expect(result.count == 1)
        #expect(result[0].url.pathExtension.lowercased() == "cr3")
    }

    @Test func xmpEscapesFreeTextAndMapsStars() {
        let builder = XMPBuilder()
        #expect(builder.stars(for: 9.0) == 5)
        #expect(builder.stars(for: 7.5) == 4)
        #expect(builder.escape("A & B <C> \"D\"") == "A &amp; B &lt;C&gt; &quot;D&quot;")
    }

    @Test func galleryFiltersRespectManualRejectAndScoreBands() {
        let photo = samplePhoto(composite: 7.4)
        #expect(GalleryFilter.nearMiss.includes(photo))
        #expect(!GalleryFilter.keepers.includes(photo))
        var rejected = photo
        rejected.isManuallyRejected = true
        #expect(GalleryFilter.manuallyRejected.includes(rejected))
        #expect(!GalleryFilter.nearMiss.includes(rejected))
    }

    private func samplePhoto(composite: Double) -> ScoredPhoto {
        let score = PhotoScore(
            autoReject: false, sharpness: 8, faceEyes: 7, peakAction: 7,
            ballInFrame: 7, exposure: 7, composition: 7, convergence: 7,
            composite: composite, lightroomSuggestions: [], developSettings: .init(),
            keepRecommendation: composite >= 6.5, rejectReason: nil, jerseyNumber: nil,
            jerseyColor: nil, actionType: .sprint
        )
        return ScoredPhoto(
            id: UUID(), fileURL: URL(fileURLWithPath: "/game/IMG_1.jpg"), filename: "IMG_1.jpg",
            fileSize: 100, modificationDate: .distantPast,
            sessionFolder: URL(fileURLWithPath: "/game"), scoredAt: .distantPast,
            scoringVersion: "v2", scoringEngine: "gemma-local", score: score,
            deepReview: nil, isPostProcessed: false, isManuallyRejected: false,
            isSelectedForExport: false
        )
    }
}
