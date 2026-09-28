import SwiftUI

@MainActor
enum AppChrome {
    static var pagePadding: CGFloat {
        UIScreen.main.bounds.width <= 390 ? 14 : 18
    }

    static var cardPadding: CGFloat {
        UIScreen.main.bounds.width <= 390 ? 16 : 18
    }

    static var spacing: CGFloat {
        UIScreen.main.bounds.width <= 390 ? 14 : 18
    }

    static let accent = Color.indigo
    static let download = Color.blue
    static let upload = Color.green
    static let cellular = Color.orange
    static let wifi = Color.cyan

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [Color.indigo, Color.blue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension View {
    func netFlowSectionTitle() -> some View {
        font(.headline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func netFlowCard(cornerRadius: CGFloat = 20) -> some View {
        padding(AppChrome.cardPadding)
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.045), radius: 10, x: 0, y: 4)
    }

    func netFlowPageBackground() -> some View {
        background(
            LinearGradient(
                colors: [
                    Color(uiColor: .systemGroupedBackground),
                    Color(uiColor: .secondarySystemGroupedBackground).opacity(0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }
}
