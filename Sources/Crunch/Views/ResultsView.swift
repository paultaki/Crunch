import CrunchCore
import SwiftUI

struct ResultsView: View {
    let results: [CompressionResult]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { result in
                    ResultRowView(result: result)
                    if result.id != results.last?.id {
                        Divider()
                            .padding(.leading, 40)
                            .opacity(0.5)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}
