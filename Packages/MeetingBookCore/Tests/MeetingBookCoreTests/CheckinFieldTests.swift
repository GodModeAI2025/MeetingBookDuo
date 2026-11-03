import Foundation
import Testing
@testable import MeetingBookCore

struct CheckinFieldTests {
    @Test func sevenIndependentMetricsOccurExactlyOnce() throws {
        let catalog=try TemplateCatalog.builtIn()
        for locale in ["de","en"] {
            let labels=locale=="de" ? ["KFA %","Brust","Taille","Hüfte","Oberarm","Oberschenkel","Ruhepuls"] : ["Body fat %","Chest","Waist","Hips","Arm","Thigh","Resting HR"]
            var c=TemplateConfiguration();c.locale=locale
            let pages=try catalog.instantiate(id:"journal.checkins",configuration:c)
            let regions=pages.flatMap(\.writingRegions)
            for label in labels {
                #expect(regions.filter {$0.label==label}.count==1,"\(locale): \(label) must be one independent field")
            }
            #expect(regions.filter {labels.contains($0.label ?? "")}.compactMap(\.label)==labels)
            #expect(regions.filter {$0.label==(locale=="de" ? "Datum":"Date")}.count==1)
            #expect(regions.filter {$0.label==(locale=="de" ? "Gewicht":"Weight")}.count==1)
        }
    }
    @Test func genuineWideTableAnchorsStillRepeat() throws {
        var layout=TemplateLayout(id:"test.anchor",title:"Anchor",variant:"default",config:.init())
        let pages=try layout.resolve([.init(.table,items:["Date","A","B","C","D"],rows:1)])
        #expect(pages.flatMap(\.writingRegions).filter {$0.label=="Date · #1"}.count==2)
    }
}
