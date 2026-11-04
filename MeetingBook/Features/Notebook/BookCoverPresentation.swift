import SwiftUI
import UIKit

@MainActor @Observable final class BookCoverPresentation {
    enum HingeState: Equatable {case unknown,closed,partiallyOpen,fullyOpen}
    private(set) var isOpen=false
    private(set) var lastHinge: HingeState?
    func open() {isOpen=true}
    func close() {isOpen=false}
    func updateHinge(_ state: HingeState?) {
        guard let state,state != .unknown,state != lastHinge else {return}
        lastHinge=state
        isOpen=state != .closed
    }
}

extension EnvironmentValues {
    @Entry var coverPresentation: BookCoverPresentation? = nil
    @Entry var coverTitleFont: Font = .custom("Caveat",size:38,relativeTo:.largeTitle)
    @Entry var notebookCovered=false
}

/// The interaction belongs to this view's scene; detachment is not a fold.
struct NotebookHingeObserver: UIViewRepresentable {
    let presentation: BookCoverPresentation
    func makeUIView(context: Context) -> UIView {
        let view=UIView();view.isUserInteractionEnabled=false
        if #available(iOS 27.1, *) {
            let interaction=UIHingeInteraction { [weak presentation] _,update in
                let state:BookCoverPresentation.HingeState?
                switch update.hinge?.status {
                case .unknown: state = .unknown
                case .closed: state = .closed
                case .partiallyOpen: state = .partiallyOpen
                case .fullyOpen: state = .fullyOpen
                case nil: state=nil
                @unknown default: state=nil
                }
                presentation?.updateHinge(state)
            }
            view.addInteraction(interaction)
        }
        return view
    }
    func updateUIView(_ uiView: UIView,context: Context) {}
    static func dismantleUIView(_ uiView: UIView,coordinator: ()) {
        for interaction in uiView.interactions {uiView.removeInteraction(interaction)}
    }
}

/// Apply at presentation boundaries, so an open draft is covered without dismissal.
private struct BookCoverShield: ViewModifier {
    @Environment(\.coverPresentation) private var presentation
    @Environment(\.bookCover) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var customizing=false
    var allowInitiallyClosed=false
    @State private var hasBeenOpen=false
    private var covered: Bool {presentation?.isOpen == false && (!allowInitiallyClosed || hasBeenOpen)}
    func body(content: Content) -> some View {
        ZStack {
            content
                .environment(\.notebookCovered,covered)
                .opacity(covered ? 0 : 1)
                .accessibilityHidden(covered)
                .allowsHitTesting(!covered)
            if covered,let presentation {
                    BookCoverView(configuration:store?.snapshot.configuration ?? BookCoverConfiguration(),open:presentation.open,customize:{customizing=true})
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion:.opacity,removal:.modifier(active:CoverOpening(angle:-88,opacity:0),identity:CoverOpening(angle:0,opacity:1))))
            }
        }
            .background {CoverSheetKeyboard(covered:covered).frame(width:0,height:0)}
            #if DEBUG
            .overlay(alignment:.topTrailing) {
                if ProcessInfo.processInfo.environment["MEETINGBOOK_SYNTHETIC_HINGE"] == "1",
                   UUID(uuidString:ProcessInfo.processInfo.environment["MEETINGBOOK_TEST_LIBRARY"] ?? "") != nil,
                   let presentation {
                    Button(presentation.isOpen ? "Synthetic fold" : "Synthetic unfold") {
                        presentation.updateHinge(presentation.isOpen ? .closed : .fullyOpen)
                    }.accessibilityIdentifier("cover.syntheticHinge").buttonStyle(.bordered)
                }
            }
            #endif
            .animation(reduceMotion ? .easeOut(duration:0.15) : .easeInOut(duration:0.32),value:covered)
            .onChange(of:presentation?.isOpen,initial:true) {_,open in if open == true {hasBeenOpen=true}}
            .sheet(isPresented:$customizing) {if let store {CoverSettingsView(store:store).bookCoverShield(allowInitiallyClosed:true)}}
    }
}
private struct CoverOpening: ViewModifier {
    var angle: Double
    var opacity: Double
    func body(content:Content) -> some View {content.rotation3DEffect(.degrees(angle),axis:(x:0,y:1,z:0),anchor:.leading,perspective:0.35).opacity(opacity)}
}
extension View {
    func bookCoverShield(allowInitiallyClosed:Bool=false) -> some View {modifier(BookCoverShield(allowInitiallyClosed:allowInitiallyClosed))}
}

/// Only this attached window is inspected; editor text uses its own marked-text-preserving suspension.
private struct CoverSheetKeyboard: UIViewRepresentable {
    let covered: Bool
    final class Anchor: UIView {
        weak var suspended: UIView?
        var selection: UITextRange?
        func update(_ covered:Bool) {
            if covered {
                func firstResponder(_ view:UIView) -> UIView? {
                    if view.isFirstResponder {return view}
                    return view.subviews.lazy.compactMap {firstResponder($0)}.first
                }
                guard suspended == nil,let window,let view=firstResponder(window),!(view is TextBlockView),let input=view as? any UITextInput else {return}
                suspended=view;selection=input.selectedTextRange;view.resignFirstResponder()
            } else if let view=suspended {
                if view.window != nil {view.becomeFirstResponder();(view as? any UITextInput)?.selectedTextRange=selection}
                suspended=nil;selection=nil
            }
        }
    }
    func makeUIView(context:Context) -> Anchor {Anchor()}
    func updateUIView(_ view:Anchor,context:Context) {DispatchQueue.main.async {[weak view] in view?.update(covered)}}
}
