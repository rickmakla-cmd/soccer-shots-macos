import AppKit
import ImageIO
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var model: AppModel
    @State private var isShowingBurstComparison = false
    @State private var isShowingBenchmark = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Session") {
                    Button("Choose Photo Folder…", systemImage: "folder") {
                        model.chooseFolder(modelContext: modelContext)
                    }
                    .disabled(model.isLoadingFolder || model.isBenchmarking)
                    if let folder = model.selectedFolder {
                        LabeledContent("Folder", value: folder.lastPathComponent)
                        LabeledContent("Photos", value: "\(model.discoveredPhotos.count)")
                        Button("Compare \(model.photoBursts.count) Bursts…", systemImage: "square.grid.2x2") {
                            isShowingBurstComparison = true
                        }
                        .disabled(model.photoBursts.isEmpty)
                        Button("Close Session", systemImage: "xmark.circle") { model.closeSession() }
                            .disabled(model.isBenchmarking)
                    }
                }
                if model.isLoadingFolder {
                    Section("Folder Scan") {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(model.isRestoringSession ? "Restoring session…" : "Reading RAW metadata…")
                        }
                        Button("Cancel Folder Scan", role: .cancel) { model.cancelFolderLoading() }
                    }
                }
                if !model.discoveredPhotos.isEmpty {
                    Section("Run") {
                        Button("Score \(model.discoveredPhotos.count) Originals", systemImage: "sparkles") {
                            model.startScoring(modelContext: modelContext)
                        }
                        .disabled(model.isScoring || model.isBenchmarking || model.isLoadingFolder)
                        if model.isScoring {
                            Button("Cancel after current photo", role: .cancel) { model.cancelScoring() }
                        }
                        if !model.completedScores.isEmpty {
                            Button("A/B Benchmark…", systemImage: "arrow.left.arrow.right") {
                                isShowingBenchmark = true
                            }
                            .disabled(model.isScoring || model.isBenchmarking || model.isDeepReviewing)
                        }
                        if model.isBenchmarking {
                            Button("Cancel A/B after current photo", role: .cancel) { model.cancelBenchmark() }
                        }
                    }
                }
                Section("Configuration") {
                    Button("Settings…", systemImage: "gearshape") { model.isShowingSettings = true }
                    LabeledContent("Primary", value: "Gemma local")
                    LabeledContent("Deep Review", value: model.isGeminiConfigured ? "Configured" : "Optional")
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            Group {
                if model.isLoadingFolder {
                    FolderLoadingView()
                } else if model.selectedFolder == nil {
                    ContentUnavailableView(
                        "Score Soccer Photos Locally",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Choose a folder to find supported photos. Nothing is uploaded during scoring.")
                    )
                } else if model.completedScores.isEmpty {
                    ReadyToScoreView()
                } else {
                    ScoreGallery()
                }
            }
            .safeAreaInset(edge: .bottom) { statusBar }
        }
        .task { model.restoreSessionIfAvailable(modelContext: modelContext) }
        .sheet(isPresented: $model.isShowingSettings) { SettingsView() }
        .sheet(isPresented: $isShowingBurstComparison) {
            BurstComparisonView(isPresented: $isShowingBurstComparison)
        }
        .sheet(isPresented: $isShowingBenchmark) {
            BenchmarkView(isPresented: $isShowingBenchmark)
        }
        .alert("SoccerShots", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) { Button("OK") { model.presentedError = nil } } message: {
            Text(model.presentedError ?? "")
        }
    }

    private var statusBar: some View {
        HStack {
            if model.isScoring || model.isBenchmarking || model.isDeepReviewing || model.isLoadingFolder {
                ProgressView().controlSize(.small)
            }
            Text(statusMessage)
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text("Gemma local · offline primary").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var statusMessage: String {
        if model.isBenchmarking { return model.benchmarkProgress.message }
        if model.isDeepReviewing { return "Gemini is performing an explicit Deep Review…" }
        return model.progress.message
    }
}

private struct FolderLoadingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(model.isRestoringSession ? "Restoring your last session" : "Reading the photo folder")
                .font(.title2.bold())
            Text("SoccerShots is reading RAW metadata in the background. The app remains usable, and you can cancel from the sidebar.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
        .padding(40)
    }
}

private struct ReadyToScoreView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.stack")
                .font(.system(size: 50)).foregroundStyle(.secondary)
            Text("\(model.discoveredPhotos.count) photos ready").font(.title2.bold())
            Text("RAW+JPEG pairs have been deduplicated. Scoring runs one photo at a time with local Gemma.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            if model.isScoring || model.isLoadingFolder { ProgressView().controlSize(.large) }
        }.padding(40)
    }
}

private struct ScoreGallery: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var model: AppModel
    @FocusState private var acceptsKeyboardInput: Bool
    @State private var isShowingDetail = false
    @State private var isShowingBurstComparison = false
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Filter", selection: $model.galleryFilter) {
                    ForEach(GalleryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Menu {
                    Picker("Sort", selection: $model.gallerySort) {
                        ForEach(GallerySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label(model.gallerySort.rawValue, systemImage: "arrow.up.arrow.down") }
                Button {
                    isShowingBurstComparison = true
                } label: {
                    Label("Compare Bursts", systemImage: "square.grid.2x2")
                }
                .disabled(model.photoBursts.isEmpty)
                Text("\(model.visiblePhotos.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(16).background(.bar)

            if model.visiblePhotos.isEmpty {
                ContentUnavailableView("No photos in this filter", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.visiblePhotos) { photo in
                            PhotoCard(photo: photo, isFocused: model.selectedPhotoID == photo.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectPhoto(photo.id) }
                                .onTapGesture(count: 2) {
                                    model.selectPhoto(photo.id)
                                    isShowingDetail = true
                                }
                        }
                    }.padding(20)
                }
            }
        }
        .focusable()
        .focused($acceptsKeyboardInput)
        .onAppear {
            acceptsKeyboardInput = true
            if model.selectedPhotoID == nil { model.selectPhoto(model.visiblePhotos.first?.id) }
        }
        .onKeyPress(.leftArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -3); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(by: 3); return .handled }
        .onKeyPress(.space) {
            if let id = model.selectedPhotoID { model.toggleExportSelection(for: id, modelContext: modelContext) }
            return .handled
        }
        .onKeyPress(.return) {
            if model.selectedPhoto != nil { isShowingDetail = true }
            return .handled
        }
        .onKeyPress("x") {
            if let id = model.selectedPhotoID { model.toggleManualReject(for: id, modelContext: modelContext) }
            return .handled
        }
        .sheet(isPresented: $isShowingDetail) {
            if let photo = model.selectedPhoto {
                PhotoDetailView(photo: photo, isPresented: $isShowingDetail)
            }
        }
        .sheet(isPresented: $isShowingBurstComparison) {
            BurstComparisonView(isPresented: $isShowingBurstComparison)
        }
    }
}

private struct PhotoCard: View {
    let photo: ScoredPhoto
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                LocalThumbnail(url: photo.fileURL)
                    .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 10))
                    .opacity(photo.isManuallyRejected ? 0.45 : 1)
                Text(String(format: "%.1f", photo.score.composite))
                    .font(.headline.monospacedDigit()).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.black.opacity(0.72), in: Capsule()).foregroundStyle(.white).padding(8)
                if photo.isSelectedForExport {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan)
                        .background(.black.opacity(0.6), in: Circle()).padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            Text(photo.filename).font(.headline).lineLimit(1)
            HStack {
                Text(photo.score.actionType.rawValue.capitalized)
                if let number = photo.score.jerseyNumber { Text("#\(number)") }
                Spacer()
                Text(photo.isManuallyRejected ? "Rejected" : photo.score.keepRecommendation ? "Keeper" : "Review")
                    .foregroundStyle(photo.isManuallyRejected ? .red : photo.score.keepRecommendation ? .green : .secondary)
            }.font(.caption)
            if let result = photo.benchmarkResult {
                HStack {
                    Text("Gemma 4")
                    Spacer()
                    Text(result.score.composite, format: .number.precision(.fractionLength(1))).monospacedDigit()
                    Text(String(format: "%+.1f", result.score.composite - photo.score.composite))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption2)
                .foregroundStyle(.purple)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 3)
        }
        .accessibilityLabel("\(photo.filename), score \(photo.score.composite)")
    }
}

struct LocalThumbnail: View {
    let url: URL
    var maxPixelSize: Int = 600
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                if contentMode == .fill {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            } else { Rectangle().fill(.quaternary).overlay { ProgressView() } }
        }
        .clipped()
        .task(id: url) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                  ] as CFDictionary) else { return }
            image = NSImage(cgImage: cg, size: .zero)
        }
    }
}
