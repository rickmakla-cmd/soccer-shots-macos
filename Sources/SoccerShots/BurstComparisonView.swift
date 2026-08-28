import SwiftData
import SwiftUI

struct BurstComparisonView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var selectedBurstID: String?
    @FocusState private var acceptsKeyboardInput: Bool

    private var bursts: [PhotoBurst] { model.photoBursts }
    private var currentBurst: PhotoBurst? {
        bursts.first { $0.id == selectedBurstID } ?? bursts.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if bursts.isEmpty {
                ContentUnavailableView(
                    "No scored bursts",
                    systemImage: "square.grid.2x2",
                    description: Text("A burst needs at least two scored photos captured within two seconds.")
                )
            } else {
                HSplitView {
                    burstList
                    comparison
                }
            }
            shortcutBar
        }
        .frame(minWidth: 1_120, minHeight: 720)
        .focusable()
        .focused($acceptsKeyboardInput)
        .onAppear {
            acceptsKeyboardInput = true
            if selectedBurstID == nil, let first = bursts.first { selectBurst(first) }
        }
        .onKeyPress(.leftArrow) { movePhoto(by: -1); return .handled }
        .onKeyPress(.rightArrow) { movePhoto(by: 1); return .handled }
        .onKeyPress(.upArrow) { moveBurst(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveBurst(by: 1); return .handled }
        .onKeyPress(.space) {
            if let id = model.selectedPhotoID { model.toggleExportSelection(for: id, modelContext: modelContext) }
            return .handled
        }
        .onKeyPress("x") {
            if let id = model.selectedPhotoID { model.toggleManualReject(for: id, modelContext: modelContext) }
            return .handled
        }
        .onKeyPress("w") { chooseWinner(); return .handled }
    }

    private var header: some View {
        HStack {
            Label("Rapid Burst Comparison", systemImage: "bolt.fill").font(.title2.bold())
            Spacer()
            if let currentBurst, let index = bursts.firstIndex(where: { $0.id == currentBurst.id }) {
                Text("Burst \(index + 1) of \(bursts.count) · \(currentBurst.photos.count) frames")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Close") { isPresented = false }.keyboardShortcut(.cancelAction)
        }
        .padding().background(.bar)
    }

    private var burstList: some View {
        List(bursts, selection: $selectedBurstID) { burst in
            Button { selectBurst(burst) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(burst.capturedAt, style: .time).font(.headline)
                        Spacer()
                        Text(String(format: "%.1f", burst.bestScore)).monospacedDigit()
                    }
                    Text("\(burst.photos.count) frames · \(burst.selectedCount) selected")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .tag(burst.id)
        }
        .frame(minWidth: 210, idealWidth: 240, maxWidth: 280)
    }

    @ViewBuilder private var comparison: some View {
        if let burst = currentBurst {
            VStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(burst.photos) { photo in
                            BurstFrameCard(photo: photo, isFocused: model.selectedPhotoID == photo.id)
                                .frame(width: frameWidth(for: burst), height: 570)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectPhoto(photo.id) }
                        }
                    }
                    .padding(20)
                }
                HStack {
                    if let selected = selectedPhoto(in: burst) {
                        Text("Focused: \(selected.filename) · \(String(format: "%.1f", selected.score.composite))")
                            .font(.headline).monospacedDigit()
                    }
                    Spacer()
                    Button("Toggle Keep") {
                        if let id = model.selectedPhotoID {
                            model.toggleExportSelection(for: id, modelContext: modelContext)
                        }
                    }
                    Button("Choose Winner · Reject Rest") { chooseWinner() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedPhoto(in: burst) == nil)
                }
                .padding().background(.bar)
            }
        }
    }

    private var shortcutBar: some View {
        HStack(spacing: 18) {
            Text("← → frame")
            Text("↑ ↓ burst")
            Text("Space keep")
            Text("X reject")
            Text("W choose winner")
            Spacer()
            Text("Choosing a winner keeps it and rejects the other frames. Decisions remain reversible.")
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
        .background(.bar)
    }

    private func selectBurst(_ burst: PhotoBurst) {
        selectedBurstID = burst.id
        let focused = burst.photos.first { $0.id == model.selectedPhotoID }
        let best = burst.photos.max { $0.score.composite < $1.score.composite }
        model.selectPhoto((focused ?? best)?.id)
    }

    private func moveBurst(by offset: Int) {
        guard !bursts.isEmpty else { return }
        let index = currentBurst.flatMap { current in bursts.firstIndex { $0.id == current.id } } ?? 0
        selectBurst(bursts[min(bursts.count - 1, max(0, index + offset))])
    }

    private func movePhoto(by offset: Int) {
        guard let burst = currentBurst, !burst.photos.isEmpty else { return }
        let index = burst.photos.firstIndex { $0.id == model.selectedPhotoID } ?? 0
        model.selectPhoto(burst.photos[min(burst.photos.count - 1, max(0, index + offset))].id)
    }

    private func chooseWinner() {
        guard let burst = currentBurst, let winner = selectedPhoto(in: burst) else { return }
        model.markBurstWinner(winner.id, in: burst, modelContext: modelContext)
    }

    private func selectedPhoto(in burst: PhotoBurst) -> ScoredPhoto? {
        burst.photos.first { $0.id == model.selectedPhotoID }
    }

    private func frameWidth(for burst: PhotoBurst) -> CGFloat {
        burst.photos.count == 2 ? 470 : 380
    }
}

private struct BurstFrameCard: View {
    let photo: ScoredPhoto
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                LocalThumbnail(url: photo.fileURL, maxPixelSize: 1_800, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 450)
                    .background(.black)
                    .opacity(photo.isManuallyRejected ? 0.42 : 1)
                Text(String(format: "%.1f", photo.score.composite))
                    .font(.title2.bold().monospacedDigit()).padding(8)
                    .background(.black.opacity(0.72), in: Capsule()).foregroundStyle(.white).padding(10)
            }
            Text(photo.filename).font(.headline).lineLimit(1)
            HStack {
                Label(photo.score.actionType.rawValue.capitalized, systemImage: "figure.soccer")
                Spacer()
                if photo.isManuallyRejected { Label("Rejected", systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                else if photo.isSelectedForExport { Label("Keep", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            .font(.caption)
            HStack(spacing: 12) {
                metric("Sharp", photo.score.sharpness)
                metric("Face", photo.score.faceEyes)
                metric("Action", photo.score.peakAction)
                metric("Conv.", photo.score.convergence)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 4)
        }
    }

    private func metric(_ label: String, _ value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(value.map { String(format: "%.0f", $0) } ?? "—").font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
