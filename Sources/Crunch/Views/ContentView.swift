import CrunchCore
import SwiftUI

struct ContentView: View {
    @State private var viewModel = CompressionViewModel()

    var body: some View {
        ZStack {
            content
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 8)),
                    removal: .opacity
                ))
        }
        .frame(minWidth: 520, minHeight: 680)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: viewModel.stateID)
        .onChange(of: viewModel.settings) { _, _ in
            viewModel.requestEstimate()
        }
        .alert("Error", isPresented: alertBinding) {
            Button("OK") { viewModel.alertMessage = nil }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }

    // MARK: - State routing

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .empty:
            DropZoneView(compact: false) { viewModel.addFiles($0) }
                .id("empty")

        case .loaded:
            loadedView.id("loaded")

        case .compressing(let completed, let total):
            ProgressBarView(
                completed: completed,
                total: total,
                onCancel: { viewModel.cancelCompression() }
            )
            .id("compressing")

        case .results:
            resultsView.id("results")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )
    }

    // MARK: - Loaded

    private var loadedView: some View {
        VStack(spacing: 0) {
            HeaderBar(
                title: "\(viewModel.files.count) image\(viewModel.files.count == 1 ? "" : "s") ready",
                subtitle: "Total \(viewModel.totalOriginalSize.formattedBytes)",
                trailing: {
                    Button("Clear") {
                        withAnimation { viewModel.clearAll() }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            )

            DropZoneView(compact: true) { viewModel.addFiles($0) }
                .padding(.top, 4)
                .padding(.bottom, 8)

            FileListView(
                files: viewModel.files,
                resolutionPercent: viewModel.settings.resolutionPercent,
                onRemove: { viewModel.removeFile($0) }
            )

            ControlsView(settings: $viewModel.settings)

            EstimatePreviewView(
                originalSize: viewModel.totalOriginalSize,
                estimatedSize: viewModel.estimatedCompressedSize,
                reduction: viewModel.estimatedReduction,
                isEstimating: viewModel.isEstimating,
                missingToolFormat: viewModel.estimateMissingToolFormat,
                unsupportedFormat: viewModel.estimateUnsupportedFormat
            )
            .animation(
                .spring(response: 0.45, dampingFraction: 0.85),
                value: viewModel.estimatedCompressedSize
            )

            CompressButton(enabled: viewModel.canCompress) {
                Task { await viewModel.compress() }
            }
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
    }

    // MARK: - Results

    private var resultsView: some View {
        VStack(spacing: 0) {
            HeaderBar(
                title: "Done",
                subtitle: "\(viewModel.results.count) file\(viewModel.results.count == 1 ? "" : "s") compressed",
                trailing: { EmptyView() }
            )

            ResultsView(results: viewModel.results)

            SummaryBarView(
                fileCount: viewModel.results.count,
                originalSize: viewModel.results.reduce(0) { $0 + $1.originalSize },
                compressedSize: viewModel.totalCompressedSize,
                reduction: viewModel.totalReduction
            )

            Button {
                withAnimation { viewModel.reset() }
            } label: {
                Label("Compress More", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
    }
}

// MARK: - Header bar

/// Lightweight section header that sits under the hidden titlebar and gives
/// the window a clear focal point in each state.
private struct HeaderBar<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 22)
        .padding(.top, 32) // leaves room for the hidden titlebar traffic lights
        .padding(.bottom, 8)
    }
}
