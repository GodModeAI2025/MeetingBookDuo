import Foundation
import Testing
@testable import MeetingBookCore

struct WorkoutOrderTests {
    @Test func effortRatingImmediatelyPrecedesNotesInBothLocales() throws {
        let catalog=try TemplateCatalog.builtIn()
        let entry=try #require(catalog.entries.first {$0.id=="journal.workout_log"})
        for locale in ["de","en"] {
            let after=locale=="de" ? "Nachher: Anstrengung 1–10":"After: Effort 1–10"
            let effort=locale=="de" ? "Anstrengung 1–10":"Effort 1–10"
            let notes=locale=="de" ? "Notizen":"Notes"
            let blocks=try #require(entry.variants[locale]?.first?.blocks)
            let index=try #require(blocks.firstIndex {$0.label==after})
            #expect(blocks[index+1].type == .scale)
            #expect(blocks[index+1].label == effort)
            #expect(blocks[index+1].rows == 10)
            #expect(blocks[index+2].type == .prompt)
            #expect(blocks[index+2].label == notes)
            #expect(blocks[index+2].rows == 14)
            var c=TemplateConfiguration();c.locale=locale
            let pages=try catalog.instantiate(id:entry.id,configuration:c)
            let text=pages.flatMap(\.primitives).filter {$0.kind == .text}.map(\.text)
            let rating=try #require(text.firstIndex(of:effort)),note=try #require(text.firstIndex(of:notes))
            #expect(rating<note)
            #expect(Array(text[(rating+1)..<(rating+11)])==(1...10).map(String.init))
            #expect(pages.flatMap(\.writingRegions).filter {$0.label==notes}.reduce(0) {$0+$1.baselines.count}==14)
        }
    }
}
