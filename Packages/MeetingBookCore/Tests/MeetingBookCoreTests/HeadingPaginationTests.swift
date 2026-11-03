import Foundation
import Testing
@testable import MeetingBookCore

struct HeadingPaginationTests {
    private var measured: TemplateConfiguration {
        var c=TemplateConfiguration();c.textSize=24;c.inkAscent=22.8515625;c.inkDescent=9.78515625;c.timeFieldWidth=81
        return c
    }
    @Test func numberedGoalsStayWithAllFourFields() throws {
        for locale in ["de","en"] {
            var c=measured;c.locale=locale
            let pages=try TemplateCatalog.builtIn().instantiate(id:"journal.goals",configuration:c)
            let fields=locale == "de" ? ["Ziel","Warum","Messbar woran","Zieldatum"]:["Goal","Why","How I measure it","Target date"]
            for number in 1...3 {
                let label=(locale == "de" ? "Ziel ":"Goal ")+String(number)
                let page=try #require(pages.first {$0.primitives.contains {$0.text==label}})
                let heading=try #require(page.primitives.first {$0.text==label})
                let following=page.writingRegions.filter {$0.frame.y>heading.frame.y}.prefix(4).compactMap(\.label)
                #expect(Array(following)==fields,"\(locale) \(label) is orphaned or split")
            }
            #expect(pages.flatMap(\.writingRegions).count==13)
        }
    }
    @Test func fieldGroupsFitOrKeepOnlyTheirFirstField() throws {
        for type in [TemplateBlockType.heading,.band,.text] {
            for count in [0,2,60] {
                let labels=(0..<count).map {"Field \($0)"}
                let blocks=[TemplateBlock(.prompt,"Before",rows:1),.init(.spacer,height:600),.init(type,"Section"),.init(.fields),.init(.fields,items:labels)]
                var layout=TemplateLayout(id:"test.group",title:"Group",variant:"default",config:measured)
                let pages=try layout.resolve(blocks)
                #expect(pages.count<12)
                #expect(pages.flatMap(\.writingRegions).compactMap(\.label)==["Before"]+labels)
                if let first=labels.first {
                    let page=try #require(pages.first {$0.primitives.contains {$0.text=="Section"}})
                    #expect(page.writingRegions.contains {$0.label==first})
                    if count==2 {#expect(labels.allSatisfy {label in page.writingRegions.contains {$0.label==label}})}
                }
            }
        }
    }
    @Test func oversizedLabelTerminatesWithoutDroppingContent() throws {
        let label=String(repeating:"Long heading ",count:150)
        var layout=TemplateLayout(id:"test.long",title:"Long",variant:"default",config:measured)
        let pages=try layout.resolve([.init(.text,label),.init(.fields,items:["First","Second"])])
        #expect(pages.count<=3)
        #expect(pages.flatMap(\.primitives).filter {$0.text==label}.count==1)
        #expect(pages.flatMap(\.writingRegions).compactMap(\.label)==["First","Second"])
    }
    @Test func wrappedFieldLabelsStayWithTheirHeading() throws {
        let label=String(repeating:"Long field label ",count:7)
        var layout=TemplateLayout(id:"test.wrapped",title:"Wrapped",variant:"default",config:measured)
        let pages=try layout.resolve([.init(.prompt,"Before",rows:1),.init(.spacer,height:600),.init(.text,"Section"),.init(.fields,items:[label,"Second"])])
        let page=try #require(pages.first {$0.primitives.contains {$0.text=="Section"}})
        #expect(page.writingRegions.compactMap(\.label)==[label,"Second"])
        #expect(pages.count==2)
    }

}
