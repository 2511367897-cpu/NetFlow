import SwiftUI

@MainActor
enum AppChrome {
    static var pagePadding: CGFloat {
        UIScreen.main.bounds.width <= 390 ? 10 : 14
    }

    static var cardPadding: CGFloat {
        UIScreen.main.bounds.width <= 390 ? 12 : 16
    }

    static var spacing: CGFloat {
        UIScreen.main.bounds.width <= 390 ? 10 : 14
    }
}

extension View {
    func netFlowSectionTitle() -> some View {
        font(.headline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    func netFlowCard(cornerRadius: CGFloat = 18) -> some View {
        padding(AppChrome.cardPadding)
            .foregroundStyle(.primary)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.75)
            )
    }

    func netFlowPageBackground() -> some View {
        background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}
