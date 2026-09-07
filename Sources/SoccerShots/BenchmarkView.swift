import Foundation
import SwiftData
import SwiftUI

struct BenchmarkView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var candidateModelID = ""

    private let presets = [
        ("Qwen3.5 4B · faster", "mlx-community/Qwen3.5-4B-MLX-4bit"),
        ("Qwen3.5 9B · higher quality", "mlx-community/Qwen3.5-9B-MLX-4bit"),
        ("Gemma 4 E4B · experimental", "mlx-community/gemma-4-e4b-it-8bit")
    ]

    private var candidateCount: Int { model.selectedForExport.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Evidence-First Local Benchmark").font(.title2.bold())
                    Text("Compare observable evidence and rule-based scores without changing keeper decisions.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(.bar)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    configuration
                    if model.isBenchmarking { running }
                    if let summary = model.evidenceBenchmarkSummary { summaryView(summary) }
                    comparisons
                }
                .padding(24)
            }
        }
        .frame(minWidth: 780, minHeight: 650)
        .onAppear {
            candidateModelID = model.benchmarkModelID
        }
    }

    private var configuration: some View {
        GroupBox("Benchmark setup") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Candidate model", selection: $candidateModelID) {
                    ForEach(Array(presets.enumerated()), id: \.offset) { item in
                        Text(item.element.0).tag(item.element.1)
                    }
                }
                TextField("Candidate Hugging Face model ID", text: $candidateModelID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isBenchmarking)
                Text("Qwen 3.5 9B is recommended. Every local model receives one complete frame because the current MLX Gemma 4 and Qwen processors can terminate the app on multi-image input. SoccerShots—not the model—calculates the score and enforces hard caps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LabeledContent("Explicit selection", value: "\(candidateCount) checked photo\(candidateCount == 1 ? "" : "s")")
                if candidateCount == 0 {
                    Text("Close this window and check the gallery images you want to compare. SoccerShots will not choose benchmark photos automatically.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Text("Only the checked gallery images will be scored. The selection is snapshotted when the run starts, so the A/B set is exact and repeatable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        model.updateBenchmarkModelID(candidateModelID)
                        model.startEvidenceBenchmark(modelContext: modelContext)
                    } label: {
                        Label("Run A/B on \(candidateCount) Selected", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBenchmarking || candidateCount == 0 || candidateModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var running: some View {
        GroupBox("Running locally") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.benchmarkProgress.message)
                }
                Text("SoccerShots unloads the primary model first. Evidence results are stored separately and never replace Gemma, Gemini, selection, or rejection decisions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Cancel after current photo", role: .cancel) { model.cancelBenchmark() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryView(_ summary: BenchmarkSummary) -> some View {
        GroupBox("Results for \(summary.completed) photos") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("Average primary").foregroundStyle(.secondary)
                    Text(summary.averageBaseline, format: .number.precision(.fractionLength(1))).monospacedDigit()
                    Text("Evidence score").foregroundStyle(.secondary)
                    Text(summary.averageCandidate, format: .number.precision(.fractionLength(1))).monospacedDigit()
                }
                GridRow {
                    Text("Average delta").foregroundStyle(.secondary)
                    Text(signed(summary.averageDelta)).monospacedDigit()
                    Text("Keeper agreement").foregroundStyle(.secondary)
                    Text(summary.keeperAgreementRate, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
                GridRow {
                    Text("Evidence time/photo").foregroundStyle(.secondary)
                    Text("\(summary.averageDurationSeconds, format: .number.precision(.fractionLength(1))) sec").monospacedDigit()
                    Text("Candidate model").foregroundStyle(.secondary)
                    Text(model.benchmarkModelID).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var comparisons: some View {
        if !model.evidenceBenchmarkedPhotos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Per-photo comparison").font(.headline)
                ForEach(model.evidenceBenchmarkedPhotos.sorted { lhs, rhs in
                    let lhsResult = lhs.evidenceBenchmarkResults.last { $0.modelID == model.benchmarkModelID }
                    let rhsResult = rhs.evidenceBenchmarkResults.last { $0.modelID == model.benchmarkModelID }
                    let lhsDelta = lhsResult.map { $0.score.composite - lhs.score.composite } ?? 0
                    let rhsDelta = rhsResult.map { $0.score.composite - rhs.score.composite } ?? 0
                    return abs(lhsDelta) > abs(rhsDelta)
                }) { photo in
                    BenchmarkRow(photo: photo, modelID: model.benchmarkModelID)
                }
            }
        }
    }

    private func signed(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }
}

private struct BenchmarkRow: View {
    let photo: ScoredPhoto
    let modelID: String

    private var result: EvidenceBenchmarkResult? { photo.evidenceBenchmarkResults.last { $0.modelID == modelID } }
    private var delta: Double { (result?.score.composite ?? photo.score.composite) - photo.score.composite }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                LocalThumbnail(url: photo.fileURL, maxPixelSize: 240)
                    .frame(width: 110, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) {
                    Text(photo.filename).font(.headline).lineLimit(1)
                    Text(evidenceSummary)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                scoreColumn("Primary", value: photo.score.composite, keeper: photo.score.keepRecommendation)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                scoreColumn("Evidence", value: result?.score.composite ?? 0, keeper: result?.score.keepRecommendation ?? false)
                Text(String(format: "%+.1f", delta))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(abs(delta) >= 1 ? .orange : .secondary)
                    .frame(width: 54, alignment: .trailing)
            }
            if let consensus = photo.consensusAssessment {
                Text("Model agreement: \(consensus.summary). Scores are not averaged across uncalibrated models.")
                    .font(.caption2)
                    .foregroundStyle(consensus.decision == .split ? .orange : .secondary)
            }
            if let label = photo.manualReviewLabel {
                Text("Your ground-truth label: \(label.title)")
                    .font(.caption2)
                    .foregroundStyle(label == .keep ? .green : .red)
            }
            if comparisonHistory.count > 1 {
                Divider()
                HStack(spacing: 14) {
                    Text("Stored comparisons").foregroundStyle(.secondary)
                    ForEach(Array(comparisonHistory.enumerated()), id: \.offset) { item in
                        Text("\(item.element.0) \(item.element.1, format: .number.precision(.fractionLength(1)))")
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var evidenceSummary: String {
        guard let evidence = result?.evidence else { return "No evidence result" }
        return "Face: \(evidence.faceVisibility.rawValue) · Action: \(evidence.actionMoment.rawValue) · Obstruction: \(evidence.foregroundObstruction.rawValue)"
    }

    private var comparisonHistory: [(String, Double)] {
        var values = photo.evidenceBenchmarkResults.map { (shortName($0.modelID), $0.score.composite) }
        if let old = photo.benchmarkResult { values.append(("Gemma 4 direct", old.score.composite)) }
        if let gemini = photo.geminiBatchResult { values.append(("Gemini", gemini.score.composite)) }
        return values
    }

    private func shortName(_ modelID: String) -> String {
        if modelID.contains("9B") { return "Qwen 9B" }
        if modelID.contains("4B") && modelID.localizedCaseInsensitiveContains("qwen") { return "Qwen 4B" }
        if modelID.localizedCaseInsensitiveContains("gemma") { return "Gemma 4 evidence" }
        return modelID
    }

    private func scoreColumn(_ label: String, value: Double, keeper: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(1)))
                .font(.title3.bold().monospacedDigit())
            Text(keeper ? "Keep" : "Review")
                .font(.caption2)
                .foregroundStyle(keeper ? .green : .secondary)
        }
        .frame(width: 78, alignment: .trailing)
    }
}
