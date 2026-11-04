import SwiftUI

struct PaperAppearance: Equatable {
    let paper: String
    init(activePaper: String? = nil, defaultPaper: String = "classic") {
        paper = activePaper ?? defaultPaper
    }
    @MainActor var uiColor: UIColor { PageRenderer.paperColor(paper) }
    @MainActor var color: Color { Color(uiColor:uiColor) }
}

extension EnvironmentValues {
    @Entry var paperAppearance = PaperAppearance()
}

private struct PaperSurface: ViewModifier {
    @Environment(\.paperAppearance) private var paper
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(paper.color.ignoresSafeArea())
            .toolbarBackground(paper.color,for:.navigationBar,.bottomBar)
            .toolbarBackground(.visible,for:.navigationBar,.bottomBar)
    }
}

extension View {
    func paperSurface() -> some View { modifier(PaperSurface()) }
    func paperContext(_ paper: PaperAppearance) -> some View {
        environment(\.paperAppearance,paper)
            .environment(\.colorScheme,.light)
            .preferredColorScheme(.light)
    }
}
