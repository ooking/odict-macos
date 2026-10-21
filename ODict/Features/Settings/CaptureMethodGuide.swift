import SwiftUI

/// Static, resolution-independent guides. Only the selected guide is mounted;
/// no image decoding, animation, event monitoring or capture service is needed.
struct CaptureMethodGuide: View {
    let method: CaptureMethod
    let instruction: String

    var body: some View {
        VStack(spacing: 14) {
            illustration
                .frame(maxWidth: .infinity)
                .frame(height: 132)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                .accessibilityHidden(true)
            Text(instruction)
                .font(AppTypography.secondary)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var illustration: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: method == .screenshot ? "photo" : "doc.text")
                Text(method == .screenshot ? "图片或视频中的文字" : "其他应用中的文字")
            }
            .font(AppTypography.caption)
            .foregroundColor(.secondary)

            HStack(spacing: 6) {
                Text("Say")
                Text("hello")
                    .foregroundColor(method == .selection ? Color.accentColor : .primary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(method == .selection ? Color.accentColor.opacity(0.18) : Color.clear)
                    .cornerRadius(3)
                    .overlay(alignment: .bottomTrailing) {
                        if method == .hover {
                            Image(systemName: "cursorarrow")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(.accentColor)
                                .offset(x: 10, y: 13)
                        }
                    }
                Text("to the world.")
            }
            .font(.system(size: 19, weight: .medium, design: .serif))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay {
                if method == .screenshot {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "plus").font(.system(size: 16, weight: .medium))
                                .foregroundColor(.accentColor).offset(x: 8, y: 8)
                        }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.down").foregroundColor(.secondary)
                Text("hello").fontWeight(.medium)
                Text("你好；打招呼").foregroundColor(.secondary)
            }
            .font(AppTypography.secondary)
        }
        .padding(12)
    }
}
