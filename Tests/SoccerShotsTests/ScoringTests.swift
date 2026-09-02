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

    @Test func xmpIncludesLightroomDevelopSettings() {
        var photo = samplePhoto(composite: 8.2, filename: "IMG_0042.CR3")
        photo.score.lightroomSuggestions = ["Lift shadows & protect highlights"]
        photo.score.developSettings = DevelopSettings(
            exposure2012: "+0.30", highlights2012: -35, shadows2012: 22,
            whites2012: 8, blacks2012: -9, clarity2012: 6, vibrance: 12,
            saturation: nil, luminanceSmoothing: 18, colorNoiseReduction: 25,
            whiteBalance: "As Shot"
        )

        let xmp = XMPBuilder().sidecar(for: photo)
        #expect(xmp.contains("xmp:Rating=\"4\""))
        #expect(xmp.contains("crs:HasSettings=\"True\""))
        #expect(xmp.contains("crs:Exposure2012=\"+0.30\""))
        #expect(xmp.contains("crs:Highlights2012=\"-35\""))
        #expect(xmp.contains("Lift shadows &amp; protect highlights"))
    }

    @Test func exportCopiesOriginalAndCreatesCollisionSafeSidecar() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SoccerShotsExportTests-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("export", isDirectory: true)
        try fileManager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let source = sourceFolder.appendingPathComponent("IMG_0042.CR3")
        let originalData = Data([0x43, 0x52, 0x33])
        try originalData.write(to: source)
        var photo = samplePhoto(composite: 8.2, filename: source.lastPathComponent)
        photo = ScoredPhoto(
            id: photo.id, fileURL: source, filename: photo.filename,
            fileSize: Int64(originalData.count), modificationDate: photo.modificationDate,
            sessionFolder: sourceFolder, scoredAt: photo.scoredAt,
            scoringVersion: photo.scoringVersion, scoringEngine: photo.scoringEngine,
            score: photo.score, deepReview: photo.deepReview,
            benchmarkResult: photo.benchmarkResult, isPostProcessed: photo.isPostProcessed,
            isManuallyRejected: photo.isManuallyRejected, isSelectedForExport: true
        )

        let service = ExportService(fileManager: fileManager)
        let first = try service.export(photos: [photo], to: destination)
        let second = try service.export(photos: [photo], to: destination)

        #expect(first.exported == 1)
        #expect(first.failed == 0)
        #expect(second.exported == 1)
        #expect(try Data(contentsOf: destination.appendingPathComponent("IMG_0042.CR3")) == originalData)
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("IMG_0042.xmp").path))
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("IMG_0042-2.CR3").path))
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("IMG_0042-2.xmp").path))
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

    @Test func burstGroupingMapsOnlyScoredNeighboringFrames() {
        let start = Date(timeIntervalSince1970: 1_000)
        let discovered = [
            discoveredPhoto("IMG_1.jpg", captureDate: start),
            discoveredPhoto("IMG_2.jpg", captureDate: start.addingTimeInterval(0.8)),
            discoveredPhoto("IMG_3.jpg", captureDate: start.addingTimeInterval(5))
        ]
        let scored = [
            samplePhoto(composite: 7.2, filename: "IMG_1.jpg"),
            samplePhoto(composite: 8.4, filename: "IMG_2.jpg"),
            samplePhoto(composite: 9.1, filename: "IMG_3.jpg")
        ]

        let bursts = BurstGrouping.make(discovered: discovered, scored: scored)
        #expect(bursts.count == 1)
        #expect(bursts[0].photos.count == 2)
        #expect(bursts[0].bestScore == 8.4)
    }

    @Test func sessionStoreRoundTripsReviewPosition() throws {
        let suite = "SoccerShotsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(defaults: defaults, key: "session")
        let snapshot = SessionSnapshot(
            folderPath: "/game", folderBookmark: Data([1, 2, 3]),
            selectedPhotoPath: "/game/IMG_2.jpg", galleryFilter: .nearMiss,
            gallerySort: .filename, updatedAt: Date(timeIntervalSince1970: 500)
        )

        try store.save(snapshot)
        #expect(store.load() == snapshot)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func geminiBatchStoreRoundTripsDurableJobs() throws {
        let suite = "SoccerShotsBatchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GeminiBatchStore(defaults: defaults, key: "jobs")
        let job = GeminiBatchJob(
            name: "batches/123", modelID: "gemini-2.5-pro",
            photoPaths: ["/game/IMG_1.CR3", "/game/IMG_2.CR3"],
            submittedAt: Date(timeIntervalSince1970: 100)
        )

        try store.save([job])
        #expect(store.load() == [job])
    }

    @Test func discoveryChecksCancellationBeforeTouchingFolder() {
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try PhotoDiscovery().discover(
                in: URL(fileURLWithPath: "/folder-that-should-not-be-read"),
                cancellationCheck: { throw Stop() }
            )
        }
    }

    @Test func benchmarkSamplingSpansTheWholeSortedRange() {
        let values = Array(0..<10)
        #expect(BenchmarkAnalysis.evenlySpaced(values, count: 4) == [0, 3, 6, 9])
        #expect(BenchmarkAnalysis.evenlySpaced(values, count: 1) == [5])
        #expect(BenchmarkAnalysis.evenlySpaced(values, count: 20) == values)
        #expect(BenchmarkAnalysis.evenlySpaced(values, count: 0).isEmpty)
    }

    @Test func benchmarkSummaryKeepsPrimaryAndCandidateSeparate() throws {
        var first = samplePhoto(composite: 7.0, filename: "IMG_1.jpg")
        var second = samplePhoto(composite: 8.0, filename: "IMG_2.jpg")
        var candidateOne = first.score
        candidateOne.composite = 8.0
        candidateOne.keepRecommendation = true
        var candidateTwo = second.score
        candidateTwo.composite = 7.0
        candidateTwo.keepRecommendation = false
        first.benchmarkResult = ModelBenchmarkResult(
            modelID: "gemma-4", scoredAt: .distantPast, durationSeconds: 12, score: candidateOne
        )
        second.benchmarkResult = ModelBenchmarkResult(
            modelID: "gemma-4", scoredAt: .distantPast, durationSeconds: 18, score: candidateTwo
        )

        let summary = try #require(BenchmarkAnalysis.summary(for: [first, second]))
        #expect(summary.completed == 2)
        #expect(summary.averageBaseline == 7.5)
        #expect(summary.averageCandidate == 7.5)
        #expect(summary.averageDelta == 0)
        #expect(summary.keeperAgreementRate == 0.5)
        #expect(summary.averageDurationSeconds == 15)
        #expect(first.score.composite == 7.0)
        #expect(second.score.composite == 8.0)
    }

    private func discoveredPhoto(_ filename: String, captureDate: Date) -> DiscoveredPhoto {
        let url = URL(fileURLWithPath: "/game/\(filename)")
        return DiscoveredPhoto(
            id: url, url: url, fileSize: 100, modificationDate: .distantPast,
            captureDate: captureDate
        )
    }

    private func samplePhoto(composite: Double, filename: String = "IMG_1.jpg") -> ScoredPhoto {
        let url = URL(fileURLWithPath: "/game/\(filename)")
        let score = PhotoScore(
            autoReject: false, sharpness: 8, faceEyes: 7, peakAction: 7,
            ballInFrame: 7, exposure: 7, composition: 7, convergence: 7,
            composite: composite, lightroomSuggestions: [], developSettings: .init(),
            keepRecommendation: composite >= 6.5, rejectReason: nil, jerseyNumber: nil,
            jerseyColor: nil, actionType: .sprint
        )
        return ScoredPhoto(
            id: UUID(), fileURL: url, filename: filename,
            fileSize: 100, modificationDate: .distantPast,
            sessionFolder: URL(fileURLWithPath: "/game"), scoredAt: .distantPast,
            scoringVersion: "v2", scoringEngine: "gemma-local", score: score,
            deepReview: nil, isPostProcessed: false, isManuallyRejected: false,
            isSelectedForExport: false
        )
    }
}
