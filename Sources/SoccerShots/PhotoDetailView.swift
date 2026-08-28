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
                LocalThumbnail(url: current.fileURL, maxPixelSize: 2_400, contentMode: .fit)
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        scoreHeader
                        scoreBreakdown
                        suggestions
                        metadata
                        deepReview
                    }.padding(20)
                }
                .frame(minWidth: 350, idealWidth: 420, maxWidth: 520)
            }
        }
        .frame(minWidth: 980, minHeight: 700)
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
                } else {
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
                .disabled(model.isDeepReviewing)
                if !model.isGeminiConfigured {
                    Button("Configure Gemini in Settings") { model.isShowingSettings = true }
                        .buttonStyle(.link)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
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
