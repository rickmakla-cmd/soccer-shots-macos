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

    @Test func geminiBatchRequestOmitsLocalFilesystemDetails() throws {
        let request = try GeminiBatchClient.requestObject(jpegData: Data([0x01, 0x02]))
        let encoded = try JSONSerialization.data(withJSONObject: request)
        let text = try #require(String(data: encoded, encoding: .utf8))

        #expect(!text.contains("photoPath"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("/Volumes/"))
    }

    @Test func geminiBatchReadsLongRunningOperationStatus() throws {
        let job = GeminiBatchJob(
            name: "batches/123", modelID: "gemini-3.7-flash",
            photoPaths: ["/game/IMG_1.CR3"], submittedAt: .now
        )
        let scoreJSON = #"{"auto_reject":false,"sharpness_score":8,"face_eyes_score":8,"peak_action_score":9,"ball_in_frame_score":7,"exposure_score":7,"composition_score":8,"convergence_score":9,"lightroom_suggestions":[],"develop_settings":{},"keep_recommendation":true}"#
        let encodedScore = try #require(String(data: JSONEncoder().encode(scoreJSON), encoding: .utf8))
        let response = Data("""
        {
          "name": "batches/123",
          "done": true,
          "metadata": {"state": "JOB_STATE_SUCCEEDED"},
          "response": {"inlinedResponses": {"inlinedResponses": [
            {"response": {"candidates": [{"content": {"parts": [{"text": \(encodedScore)}]}}]}}
          ]}}
        }
        """.utf8)

        let result = try GeminiBatchClient.parseStatus(response, job: job)
        #expect(result.state == .succeeded)
        #expect(result.scoresByPath["/game/IMG_1.CR3"]?.composite == 8.2)
        #expect(result.failedPaths.isEmpty)
    }

    @Test func geminiBatchReadsResourceStatus() throws {
        let job = GeminiBatchJob(
            name: "batches/456", modelID: "gemini-3.7-flash",
            photoPaths: ["/game/IMG_2.CR3"], submittedAt: .now
        )
        let response = Data(#"{"name":"batches/456","state":"BATCH_STATE_RUNNING"}"#.utf8)

        let result = try GeminiBatchClient.parseStatus(response, job: job)
        #expect(result.state == .running)
    }

    @Test func evidenceRulesCapBackFacingSubjectAndSevereObstruction() {
        let evidence = PhotoEvidence(
            primarySubject: "foreground player facing away",
            faceVisibility: .obscured, faceSharpness: .indeterminate,
            subjectSharpness: .sharp, subjectScale: .medium, subjectOrientation: .awayFromCamera,
            actionMoment: .strong, actionCue: .routineRunning,
            ballRelevance: .relevant, emotion: .unseen,
            foregroundObstruction: .severe, backgroundClutter: .moderate,
            emptySpace: nil, framingQuality: nil, subjectIsolation: nil,
            exposureQuality: .good, confidence: 0.9,
            observations: ["Fence crosses the player."]
        )

        let score = EvidenceRuleEngine().score(evidence)
        #expect(score.faceEyes == 2)
        #expect(score.composition == 1)
        #expect(score.peakAction == 5)
        #expect(score.convergence == 4)
        #expect(!score.keepRecommendation)
    }

    @Test func evidenceRulesUseSubjectSharpnessAndLooseFraming() throws {
        let evidence = PhotoEvidence(
            primarySubject: "back-facing player running toward the ball",
            faceVisibility: .obscured, faceSharpness: .blurred,
            subjectSharpness: .usable, subjectScale: .medium, subjectOrientation: .awayFromCamera,
            actionMoment: .strong, actionCue: .routineRunning,
            ballRelevance: .relevant, emotion: .unseen,
            foregroundObstruction: .none, backgroundClutter: .minor,
            emptySpace: .severe, framingQuality: .loose, subjectIsolation: .weak,
            exposureQuality: .good, confidence: 0.9,
            observations: ["The player is approaching the ball."]
        )

        let score = EvidenceRuleEngine().score(evidence)
        #expect(score.faceEyes == 2)
        #expect(score.sharpness == 7)
        #expect(score.peakAction == 5)
        let composition = try #require(score.composition)
        #expect(composition <= 3)
        #expect(!score.autoReject)
        #expect(!score.keepRecommendation)
    }

    @Test func evidenceParserReadsCategoricalJSON() throws {
        let json = #"{"primary_subject":"goalkeeper","face_visibility":"profile","face_sharpness":"usable","subject_scale":"medium","action_moment":"peak","ball_relevance":"central","emotion":"visible","foreground_obstruction":"none","background_clutter":"minor","exposure_quality":"good","confidence":0.85,"observations":["Keeper is fully extended."]}"#
        let evidence = try EvidenceParser().parse("result:\n\(json)")

        #expect(evidence.faceVisibility == .profile)
        #expect(evidence.actionMoment == .peak)
        #expect(evidence.ballRelevance == .central)
        #expect(evidence.confidence == 0.85)
    }

    @Test func evidenceVisionProbeAcceptsNaturalColorNamesAndFormatting() {
        #expect(EvidenceVisionProbe.passes("LEFT=pink; RIGHT=bright yellow"))
        #expect(EvidenceVisionProbe.passes(#"{"left":"purple","right":"gold"}"#))
        #expect(EvidenceVisionProbe.passes("The right side is golden; the left side is fuchsia."))
        #expect(!EvidenceVisionProbe.passes("LEFT=yellow; RIGHT=magenta"))
        #expect(!EvidenceVisionProbe.passes("I cannot see an image."))
    }

    @Test func geminiSelectorReplacesRetiredPreferredModelFromLiveCatalog() {
        let models = [
            remoteModel("gemini-3.1-pro-preview", methods: ["generateContent"]),
            remoteModel("gemini-3.6-flash", methods: ["generateContent", "batchGenerateContent"])
        ]

        #expect(
            GeminiModelSelector.interactiveCandidates(
                preferred: "gemini-2.5-pro", catalog: models
            ).first == "gemini-3.1-pro-preview"
        )
        #expect(
            GeminiModelSelector.batchCandidates(
                preferred: "gemini-2.5-pro", catalog: models
            ) == ["gemini-3.6-flash"]
        )
    }

    @Test func geminiBatchSelectorPrefersExplicitBatchCapability() {
        let models = [
            remoteModel("gemini-3.7-flash", methods: ["generateContent"]),
            remoteModel("gemini-3.6-flash", methods: ["generateContent", "batchGenerateContent"]),
            remoteModel("text-embedding-999", methods: ["generateContent", "batchGenerateContent"])
        ]

        #expect(
            GeminiModelSelector.batchCandidates(
                preferred: "gemini-3.7-flash", catalog: models
            ) == ["gemini-3.6-flash"]
        )
    }

    @Test func geminiFallbackOnlyRetriesDefiniteModelRejection() {
        #expect(GeminiHTTPError(
            statusCode: 404,
            serverMessage: "This model is no longer available to new users."
        ).definitelyRejectsModel)
        #expect(!GeminiHTTPError(
            statusCode: 429,
            serverMessage: "Model quota exceeded."
        ).definitelyRejectsModel)
        #expect(!GeminiHTTPError(
            statusCode: 403,
            serverMessage: "Billing is not enabled."
        ).definitelyRejectsModel)
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

    private func remoteModel(_ id: String, methods: [String]) -> GeminiRemoteModel {
        GeminiRemoteModel(name: "models/\(id)", displayName: id, supportedGenerationMethods: methods)
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

    @Test func evidenceSummaryKeepsSeparateResultsForEachCandidateModel() throws {
        var photo = samplePhoto(composite: 8.0)
        var qwen4Score = photo.score
        qwen4Score.composite = 6.0
        var qwen9Score = photo.score
        qwen9Score.composite = 5.0
        let evidence = PhotoEvidence(
            primarySubject: "player", faceVisibility: .profile, faceSharpness: .usable,
            subjectSharpness: nil, subjectScale: .medium, subjectOrientation: nil,
            actionMoment: .strong, actionCue: nil, ballRelevance: .relevant,
            emotion: .visible, foregroundObstruction: .none, backgroundClutter: .minor,
            emptySpace: nil, framingQuality: nil, subjectIsolation: nil,
            exposureQuality: .good, confidence: 0.8, observations: []
        )
        photo.evidenceBenchmarkResults = [
            .init(modelID: "qwen-4b", scoredAt: .distantPast, durationSeconds: 10, evidence: evidence, score: qwen4Score),
            .init(modelID: "qwen-9b", scoredAt: .now, durationSeconds: 20, evidence: evidence, score: qwen9Score)
        ]

        let summary = try #require(EvidenceBenchmarkAnalysis.summary(for: [photo], modelID: "qwen-9b"))
        #expect(summary.completed == 1)
        #expect(summary.averageCandidate == 5.0)
        #expect(summary.averageDelta == -3.0)
        #expect(photo.evidenceBenchmarkResults.count == 2)
    }

    @Test func evidenceBenchmarkUsesOnlyExplicitlySelectedPhotos() {
        var first = samplePhoto(composite: 8.0, filename: "IMG_1.jpg")
        let second = samplePhoto(composite: 7.0, filename: "IMG_2.jpg")
        var third = samplePhoto(composite: 6.0, filename: "IMG_3.jpg")
        first.isSelectedForExport = true
        third.isSelectedForExport = true

        let selected = EvidenceBenchmarkAnalysis.selectedCandidates(from: [first, second, third])
        #expect(selected.map(\.filename) == ["IMG_1.jpg", "IMG_3.jpg"])
    }

    @Test func consensusReportsVotesWithoutAveragingModelScores() throws {
        var photo = samplePhoto(composite: 8.1)
        var keepScore = photo.score
        keepScore.composite = 8.8
        keepScore.keepRecommendation = true
        var reviewScore = photo.score
        reviewScore.composite = 4.1
        reviewScore.keepRecommendation = false
        let evidence = try EvidenceParser().parse(#"{"primary_subject":"player","face_visibility":"back","face_sharpness":"indeterminate","subject_scale":"medium","action_moment":"ordinary","ball_relevance":"relevant","emotion":"unseen","foreground_obstruction":"none","background_clutter":"minor","exposure_quality":"good","confidence":0.9,"observations":[]}"#)

        photo.benchmarkResult = .init(
            modelID: "gemma-4", scoredAt: .distantPast, durationSeconds: 1, score: keepScore
        )
        photo.geminiBatchResult = .init(
            modelID: "gemini", scoredAt: .distantPast, durationSeconds: 1, score: reviewScore
        )
        photo.evidenceBenchmarkResults = [
            .init(modelID: "qwen", scoredAt: .distantPast, durationSeconds: 1, evidence: evidence, score: reviewScore),
            .init(modelID: "qwen", scoredAt: .now, durationSeconds: 1, evidence: evidence, score: reviewScore)
        ]

        let consensus = try #require(photo.consensusAssessment)
        #expect(consensus.decision == .review)
        #expect(consensus.keepVotes == 0)
        #expect(consensus.totalVotes == 2)
        #expect(consensus.summary == "Review · 0/2 keep")
    }

    @Test func manualReviewLabelIsPersistedWithScoreRecord() throws {
        var photo = samplePhoto(composite: 7.0)
        photo.manualReviewLabel = .reject
        let record = try ScoreRecord(photo: photo)
        #expect(record.manualReviewLabelRaw == ManualReviewLabel.reject.rawValue)
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
