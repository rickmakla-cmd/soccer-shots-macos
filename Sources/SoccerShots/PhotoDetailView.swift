import AppKit
import SwiftData
import SwiftUI

struct PhotoDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var model: AppModel
    let photo: ScoredPhoto
    @Binding var isPresented: Bool

    private var current: ScoredPhoto { model.selectedPhoto ?? photo }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.moveSelection(by: -1) } label: { Label("Previous", systemImage: "chevron.left") }
                Button { model.moveSelection(by: 1) } label: { Label("Next", systemImage: "chevron.right") }
                Spacer()
                Text(current.filename).font(.headline).lineLimit(1)
                Spacer()
                Button("Close") { isPresented = false }.keyboardShortcut(.cancelAction)
            }.padding().background(.bar)

            HSplitView {
                LocalThumbnail(
                    url: current.fileURL,
                    maxPixelSize: 2_400,
                    contentMode: .fit,
                    loadingLane: .foreground
                )
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        scoreHeader
                        manualReview
                        scoreBreakdown
                        suggestions
                        metadata
                        evidenceComparison
                        benchmarkComparison
                        geminiBatchComparison
                        deepReview
                    }.padding(20)
                }
                .frame(minWidth: 350, idealWidth: 420, maxWidth: 520)
            }
        }
        .frame(minWidth: 980, minHeight: 700)
    }

    private var manualReview: some View {
        GroupBox("Your ground-truth label") {
            Picker("Decision", selection: Binding(
                get: { current.manualReviewLabel },
                set: { model.setManualReviewLabel($0, for: current.id, modelContext: modelContext) }
            )) {
                Text("Unlabeled").tag(nil as ManualReviewLabel?)
                ForEach(ManualReviewLabel.allCases) { label in
                    Text(label.title).tag(label as ManualReviewLabel?)
                }
            }
            .pickerStyle(.segmented)
            Text("These labels are stored locally and can be used to measure and tune local scoring against your actual choices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var evidenceComparison: some View {
        if let result = current.evidenceBenchmarkResults.max(by: { $0.scoredAt < $1.scoredAt }) {
            GroupBox("Evidence-first local benchmark") {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        GridRow { Text("Primary score").foregroundStyle(.secondary); Text(current.score.composite, format: .number.precision(.fractionLength(1))) }
                        GridRow { Text("Rule-based score").foregroundStyle(.secondary); Text(result.score.composite, format: .number.precision(.fractionLength(1))) }
                        GridRow { Text("Face").foregroundStyle(.secondary); Text(result.evidence.faceVisibility.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) }
                        GridRow { Text("Face detail").foregroundStyle(.secondary); Text(result.evidence.faceSharpness.rawValue.capitalized) }
                        if let value = result.evidence.subjectSharpness {
                            GridRow { Text("Model sharpness").foregroundStyle(.secondary); Text(value.rawValue.capitalized) }
                        }
                        if let value = result.pixelSharpness {
                            GridRow {
                                Text("Pixel sharpness").foregroundStyle(.secondary)
                                Text(value, format: .number.precision(.fractionLength(1)))
                            }
                        }
                        if let value = result.evidence.subjectOrientation {
                            GridRow { Text("Orientation").foregroundStyle(.secondary); Text(value.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) }
                        }
                        GridRow { Text("Action").foregroundStyle(.secondary); Text(result.evidence.actionMoment.rawValue.capitalized) }
                        if let value = result.evidence.actionCue {
                            GridRow { Text("Visible action cue").foregroundStyle(.secondary); Text(value.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) }
                        }
                        GridRow { Text("Ball").foregroundStyle(.secondary); Text(result.evidence.ballRelevance.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) }
                        GridRow { Text("Obstruction").foregroundStyle(.secondary); Text(result.evidence.foregroundObstruction.rawValue.capitalized) }
                        GridRow { Text("Clutter").foregroundStyle(.secondary); Text(result.evidence.backgroundClutter.rawValue.capitalized) }
                        if let value = result.evidence.emptySpace {
                            GridRow { Text("Empty space").foregroundStyle(.secondary); Text(value.rawValue.capitalized) }
                        }
                        if let value = result.evidence.framingQuality {
                            GridRow { Text("Framing").foregroundStyle(.secondary); Text(value.rawValue.capitalized) }
                        }
                        if let value = result.evidence.subjectIsolation {
                            GridRow { Text("Subject isolation").foregroundStyle(.secondary); Text(value.rawValue.capitalized) }
                        }
                        if let consensus = current.consensusAssessment {
                            GridRow { Text("Model agreement").foregroundStyle(.secondary); Text(consensus.summary) }
                        }
                        GridRow { Text("Confidence").foregroundStyle(.secondary); Text(result.evidence.confidence, format: .percent.precision(.fractionLength(0))) }
                    }
                    Text(result.evidence.primarySubject).font(.callout)
                    ForEach(result.evidence.observations, id: \.self) { observation in
                        Text("• \(observation)")
                    }
                    Text(result.modelID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("The model supplied observations; SoccerShots calculated the score using fixed rules. Existing decisions were not changed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var scoreHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(String(format: "%.1f", current.score.composite))
                .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
            Text("/ 10").font(.title3).foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing) {
                Text(current.score.keepRecommendation ? "KEEPER" : "REVIEW")
                    .font(.headline).foregroundStyle(current.score.keepRecommendation ? .green : .secondary)
                if current.score.autoReject { Text("Auto-rejected for sharpness").foregroundStyle(.red) }
            }
        }
    }

    private var scoreBreakdown: some View {
        GroupBox("Score breakdown") {
            VStack(spacing: 10) {
                ScoreBar(label: "Sharpness", value: current.score.sharpness)
                ScoreBar(label: "Face / Eyes", value: current.score.faceEyes)
                ScoreBar(label: "Peak Action", value: current.score.peakAction)
                ScoreBar(label: "Ball in Frame", value: current.score.ballInFrame, emptyLabel: "Jube exception")
                ScoreBar(label: "Exposure", value: current.score.exposure)
                ScoreBar(label: "Composition", value: current.score.composition)
                ScoreBar(label: "Convergence ×2", value: current.score.convergence)
            }.padding(.vertical, 4)
        }
    }

    private var suggestions: some View {
        GroupBox("Lightroom suggestions") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(current.score.lightroomSuggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: "slider.horizontal.3")
                }
                if current.score.lightroomSuggestions.isEmpty {
                    Text("No adjustments suggested.").foregroundStyle(.secondary)
                }
                if !current.score.lightroomSuggestions.isEmpty {
                    Button("Copy all") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(current.score.lightroomSuggestions.joined(separator: "\n"), forType: .string)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadata: some View {
        GroupBox("Photo metadata") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow { Text("Action").foregroundStyle(.secondary); Text(current.score.actionType.rawValue.capitalized) }
                GridRow { Text("Jersey").foregroundStyle(.secondary); Text(current.score.jerseyNumber.map { "#\($0)" } ?? "Unknown") }
                GridRow { Text("Color").foregroundStyle(.secondary); Text(current.score.jerseyColor ?? "Unknown") }
                GridRow { Text("Engine").foregroundStyle(.secondary); Text(current.scoringEngine) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var deepReview: some View {
        GroupBox("Gemini Deep Review · optional") {
            VStack(alignment: .leading, spacing: 10) {
                if let review = current.deepReview {
                    Text(review.assessment)
                    if !review.limitingFactors.isEmpty {
                        Text("Limiting factors").font(.headline)
                        ForEach(review.limitingFactors, id: \.self) { Text("• \($0)") }
                    }
                    if let fix = review.suggestedFix { Label(fix, systemImage: "wand.and.stars") }
                    if let crop = review.cropSuggestion { Label(crop, systemImage: "crop") }
                } else {
                    Text("Request a cloud second opinion for this photo only. The local Gemma score will not be changed.")
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.runDeepReview(for: current.id, modelContext: modelContext)
                } label: {
                    if model.isDeepReviewing { ProgressView() }
                    else { Label(current.deepReview == nil ? "Deep Review This Photo" : "Run Deep Review Again", systemImage: "cloud") }
                }
                .disabled(model.isDeepReviewing || model.isBenchmarking || model.isGeminiBatchRunning)
                if !model.isGeminiConfigured {
                    Button("Configure Gemini in Settings") { model.isShowingSettings = true }
                        .buttonStyle(.link)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var benchmarkComparison: some View {
        if let result = current.benchmarkResult {
            GroupBox("Local A/B comparison") {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow {
                            Text("Primary").foregroundStyle(.secondary)
                            Text(current.score.composite, format: .number.precision(.fractionLength(1))).monospacedDigit()
                            Text(current.score.keepRecommendation ? "Keep" : "Review")
                        }
                        GridRow {
                            Text("Gemma 4").foregroundStyle(.secondary)
                            Text(result.score.composite, format: .number.precision(.fractionLength(1))).monospacedDigit()
                            Text(result.score.keepRecommendation ? "Keep" : "Review")
                        }
                        GridRow {
                            Text("Difference").foregroundStyle(.secondary)
                            Text(String(format: "%+.1f", result.score.composite - current.score.composite)).monospacedDigit()
                            Text(result.durationSeconds, format: .number.precision(.fractionLength(1))) + Text(" sec")
                        }
                    }
                    Text(result.modelID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("The candidate result is observational only and has not changed this photo's keeper or rejection state.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var geminiBatchComparison: some View {
        if let result = current.geminiBatchResult {
            GroupBox("Gemini batch score · comparison only") {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow {
                            Text("Gemma primary").foregroundStyle(.secondary)
                            Text(current.score.composite, format: .number.precision(.fractionLength(1))).monospacedDigit()
                            Text(current.score.keepRecommendation ? "Keep" : "Review")
                        }
                        GridRow {
                            Text("Gemini batch").foregroundStyle(.secondary)
                            if result.score.autoReject {
                                Text("Reject").foregroundStyle(.red).fontWeight(.semibold)
                                Text("Auto-rejected").foregroundStyle(.red)
                            } else {
                                Text(result.score.composite, format: .number.precision(.fractionLength(1))).monospacedDigit()
                                Text(result.score.keepRecommendation ? "Keep" : "Review")
                            }
                        }
                        GridRow {
                            Text("Difference").foregroundStyle(.secondary)
                            Text(result.score.autoReject ? "Not comparable" : String(format: "%+.1f", result.score.composite - current.score.composite))
                                .monospacedDigit()
                            Text(result.modelID)
                        }
                    }
                    if result.score.autoReject, let reason = result.score.rejectReason {
                        Label(reason, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                    if !result.score.lightroomSuggestions.isEmpty {
                        Text("Gemini Lightroom suggestions").font(.headline)
                        ForEach(result.score.lightroomSuggestions, id: \.self) { suggestion in
                            Label(suggestion, systemImage: "slider.horizontal.3")
                        }
                    }
                    Text("This result is stored separately and has not changed the Primary keeper, rejection, or export decision.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ScoreBar: View {
    let label: String
    let value: Double?
    var emptyLabel = "Not scored"

    var body: some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading)
            if let value {
                ProgressView(value: value, total: 10)
                Text(String(format: "%.0f", value)).frame(width: 24, alignment: .trailing).monospacedDigit()
            } else {
                Text(emptyLabel).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}
