import AppKit
import ImageIO
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List {
                Section("Session") {
                    Button("Choose Photo Folder…", systemImage: "folder") { model.chooseFolder() }
                    if let folder = model.selectedFolder {
                        LabeledContent("Folder", value: folder.lastPathComponent)
                        LabeledContent("Photos", value: "\(model.discoveredPhotos.count)")
                    }
                }
                if !model.discoveredPhotos.isEmpty {
                    Section("Run") {
                        Button("Score \(model.discoveredPhotos.count) Originals", systemImage: "sparkles") {
                            model.startScoring(modelContext: modelContext)
                        }
                        .disabled(model.isScoring)
                        if model.isScoring {
                            Button("Cancel after current photo", role: .cancel) { model.cancelScoring() }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            Group {
                if model.selectedFolder == nil {
                    ContentUnavailableView(
                        "Score Soccer Photos Locally",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Choose a folder to find supported photos. Nothing is uploaded during scoring.")
                    )
                } else if model.completedScores.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)
                        Text("\(model.discoveredPhotos.count) photos ready")
                            .font(.title2.bold())
                        Text("RAW+JPEG pairs have been deduplicated. Scoring runs one photo at a time with local Gemma.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                        if model.isScoring { ProgressView().controlSize(.large) }
                    }
                    .padding(40)
                } else {
                    ScoreGallery(photos: model.completedScores)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if model.isScoring { ProgressView().controlSize(.small) }
                    Text(model.progress.message).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("Gemma local · offline").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
            }
        }
        .alert("SoccerShots", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) { Button("OK") { model.presentedError = nil } } message: {
            Text(model.presentedError ?? "")
        }
    }
}

private struct ScoreGallery: View {
    let photos: [ScoredPhoto]
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(photos.sorted { $0.score.composite > $1.score.composite }) { photo in
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            LocalThumbnail(url: photo.fileURL)
                                .frame(height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(String(format: "%.1f", photo.score.composite))
                                .font(.headline.monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(.black.opacity(0.72), in: Capsule())
                                .foregroundStyle(.white).padding(8)
                        }
                        Text(photo.filename).font(.headline).lineLimit(1)
                        HStack {
                            Text(photo.score.actionType.rawValue.capitalized)
                            Spacer()
                            Text(photo.score.keepRecommendation ? "Keeper" : "Review")
                                .foregroundStyle(photo.score.keepRecommendation ? .green : .secondary)
                        }.font(.caption)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                }
            }.padding(20)
        }
    }
}

private struct LocalThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(.quaternary).overlay { ProgressView() } }
        }
        .clipped()
        .task(id: url) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600
                  ] as CFDictionary) else { return }
            image = NSImage(cgImage: cg, size: .zero)
        }
    }
}
