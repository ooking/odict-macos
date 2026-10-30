import SwiftUI

/// Shared, static placeholders. No timers, animation loops or retained result data.
/// Dictionary lookup and page rendering use identical geometry through every stage.
struct LookupSkeletonView: View {
    var showsHeading = false
    let accessibilityText: String
    private let paragraphWidths: [[CGFloat]] = [
        [1, 0.94, 0.68], [1, 0.86, 0.54], [0.96, 0.72]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeading {
                line(width: 0.42, height: 30)
                line(width: 0.26, height: 14)
                Divider()
            }
            ForEach(paragraphWidths.indices, id: \.self) { paragraph in
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(paragraphWidths[paragraph].indices, id: \.self) { index in
                        line(width: paragraphWidths[paragraph][index], height: 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func line(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.08))
                .frame(width: geometry.size.width * width)
        }.frame(height: height)
    }
}

struct DictionaryLoadingView: View {
    var status = "正在查询词典…"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LookupSkeletonView(showsHeading: true, accessibilityText: status)
            Text(status).font(AppTypography.secondary).foregroundColor(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
