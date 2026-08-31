import Foundation
import SwiftData
import SwiftUI

struct BenchmarkView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var sampleCount = 10
    @State private var candidateModelID = ""

    private var candidateCount: Int { model.visiblePhotos.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local Model A/B Benchmark").font(.title2.bold())
                    Text("Compare stored primary scores with Gemma 4 without changing keeper decisions.")
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
                    if let summary = model.benchmarkSummary { summaryView(summary) }
                    comparisons
                }
                .padding(24)
            }
        }
        .frame(minWidth: 780, minHeight: 650)
        .onAppear {
            candidateModelID = model.benchmarkModelID
            sampleCount = min(10, max(1, candidateCount))
        }
    }

    private var configuration: some View {
        GroupBox("Benchmark setup") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Candidate Hugging Face model ID", text: $candidateModelID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isBenchmarking)
                Text("The default 8-bit E4B model avoids the known 4-bit vision-projection loader defect. Its first run downloads about 8.9 GB.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Stepper(value: $sampleCount, in: 1...max(1, candidateCount)) {
                    LabeledContent("Sample", value: "\(sampleCount) of \(candidateCount) photos")
                }
                .disabled(model.isBenchmarking || candidateCount == 0)
                Text("The sample is spread evenly across the current \(model.galleryFilter.rawValue) score range rather than taking only the highest-ranked photos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        model.updateBenchmarkModelID(candidateModelID)
                        model.startBenchmark(sampleCount: sampleCount, modelContext: modelContext)
                    } label: {
                        Label("Run Gemma 4 A/B", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBenchmarking || candidateCount == 0 || candidateModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if candidateCount > 1 {
                        Button("Use All \(candidateCount)") { sampleCount = candidateCount }
                            .disabled(model.isBenchmarking)
                    }
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
                Text("SoccerShots unloads the primary model before Gemma 4 is loaded, keeping both models from occupying unified memory together.")
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
                    Text("Average candidate").foregroundStyle(.secondary)
                    Text(summary.averageCandidate, format: .number.precision(.fractionLength(1))).monospacedDigit()
                }
                GridRow {
                    Text("Average delta").foregroundStyle(.secondary)
                    Text(signed(summary.averageDelta)).monospacedDigit()
                    Text("Keeper agreement").foregroundStyle(.secondary)
                    Text(summary.keeperAgreementRate, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
                GridRow {
                    Text("Gemma 4 time/photo").foregroundStyle(.secondary)
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
        if !model.benchmarkedPhotos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Per-photo comparison").font(.headline)
                ForEach(model.benchmarkedPhotos.sorted { lhs, rhs in
                    let lhsDelta = lhs.benchmarkResult.map { $0.score.composite - lhs.score.composite } ?? 0
                    let rhsDelta = rhs.benchmarkResult.map { $0.score.composite - rhs.score.composite } ?? 0
                    return abs(lhsDelta) > abs(rhsDelta)
                }) { photo in
                    BenchmarkRow(photo: photo)
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

    private var result: ModelBenchmarkResult? { photo.benchmarkResult }
    private var delta: Double { (result?.score.composite ?? photo.score.composite) - photo.score.composite }

    var body: some View {
        HStack(spacing: 14) {
            LocalThumbnail(url: photo.fileURL, maxPixelSize: 240)
                .frame(width: 110, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(photo.filename).font(.headline).lineLimit(1)
                Text(result?.score.actionType.rawValue.capitalized ?? "No candidate result")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            scoreColumn("Primary", value: photo.score.composite, keeper: photo.score.keepRecommendation)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            scoreColumn("Gemma 4", value: result?.score.composite ?? 0, keeper: result?.score.keepRecommendation ?? false)
            Text(String(format: "%+.1f", delta))
                .font(.headline.monospacedDigit())
                .foregroundStyle(abs(delta) >= 1 ? .orange : .secondary)
                .frame(width: 54, alignment: .trailing)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
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
