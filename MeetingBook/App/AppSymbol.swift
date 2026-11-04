import SwiftUI

/// Stable function identifiers; labels at call sites retain their action-specific wording.
enum AppSymbol: String, CaseIterable, Identifiable, Codable, Sendable {
    case mode,reading,typing,drawing,selecting,pen,eraser,undo,redo,hideKeyboard
    case previous,next
    case openBook,closeBook,designCover
    case page,addPage,bookmark,appearance,readableText,customize,history,save,importImage,delete
    case library,newNote,search,fontStudio,exportRecovery,cloudRecovery,settings,favorite,exportCharacter,publishFont,appSymbols

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case writing,navigation,pages,library
        var id: String {rawValue}
        var title: LocalizedStringResource {
            switch self {
            case .writing: "Writing"
            case .navigation: "Navigation"
            case .pages: "Pages"
            case .library: "Library"
            }
        }
    }
    var id: String {rawValue}
    var category: Category {
        switch self {
        case .mode,.reading,.typing,.drawing,.selecting,.pen,.eraser,.undo,.redo,.hideKeyboard,.exportCharacter,.publishFont: .writing
        case .previous,.next: .navigation
        case .page,.addPage,.bookmark,.appearance,.readableText,.customize,.history,.save,.importImage,.delete: .pages
        default: .library
        }
    }
    var title: LocalizedStringResource {
        switch self {
        case .openBook: "Open book"
        case .closeBook: "Close book"
        case .designCover: "Design cover"
        case .mode: "Mode"
        case .reading: "Read"
        case .typing: "Type"
        case .drawing: "Draw"
        case .selecting: "Select"
        case .pen: "Pen"
        case .eraser: "Eraser"
        case .undo: "Undo"
        case .redo: "Redo"
        case .hideKeyboard: "Hide keyboard"
        case .previous: "Previous"
        case .next: "Next"
        case .page: "Page"
        case .addPage: "Add page"
        case .bookmark: "Bookmark"
        case .appearance: "Reading and appearance"
        case .readableText: "Readable text"
        case .customize: "Customize"
        case .history: "Page history"
        case .save: "Save locally"
        case .importImage: "Import image"
        case .delete: "Delete"
        case .library: "Your notebook"
        case .newNote: "New note"
        case .search: "Search"
        case .fontStudio: "Font Studio"
        case .exportRecovery: "Export and recovery"
        case .cloudRecovery: "iCloud and recovery"
        case .settings: "Settings"
        case .favorite: "Favorite"
        case .exportCharacter: "Export unsaved character"
        case .publishFont: "Validate and publish version"
        case .appSymbols: "Own app symbols"
        }
    }
    var standardSymbol: String {
        switch self {
        case .openBook: "book"
        case .closeBook: "book.closed"
        case .designCover: "book.closed.fill"
        case .mode: "pencil.and.outline"
        case .reading: "book"
        case .typing: "character.cursor.ibeam"
        case .drawing: "pencil.tip"
        case .selecting: "cursorarrow"
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .hideKeyboard: "keyboard.chevron.compact.down"
        case .previous: "chevron.left"
        case .next: "chevron.right"
        case .page: "doc"
        case .addPage: "doc.badge.plus"
        case .bookmark: "bookmark"
        case .appearance: "textformat"
        case .readableText: "text.alignleft"
        case .customize: "slider.horizontal.3"
        case .history: "clock.arrow.circlepath"
        case .save: "checkmark.circle"
        case .importImage: "photo"
        case .delete: "trash"
        case .library: "book.closed"
        case .newNote: "square.and.pencil"
        case .search: "magnifyingglass"
        case .fontStudio: "textformat.abc"
        case .exportRecovery,.exportCharacter: "square.and.arrow.up"
        case .cloudRecovery: "icloud"
        case .settings: "gearshape"
        case .favorite: "star"
        case .publishFont: "checkmark.seal"
        case .appSymbols: "square.grid.2x2"
        }
    }
    func systemName(selected: Bool=false) -> String {
        if selected && self == .bookmark {return "bookmark.fill"}
        if selected && self == .favorite {return "star.fill"}
        return standardSymbol
    }
    @MainActor func image(in store: PersonalSymbolStore, selected: Bool=false) -> Image {
        image(in:Optional(store),selected:selected)
    }
    @MainActor func image(in store: PersonalSymbolStore?, selected: Bool=false) -> Image {
        if let image=store?.customImage(for:self,selected:selected) {return Image(uiImage:image).renderingMode(.template)}
        return Image(systemName:systemName(selected:selected))
    }
}

extension EnvironmentValues {
    @Entry var personalSymbols: PersonalSymbolStore? = nil
}
