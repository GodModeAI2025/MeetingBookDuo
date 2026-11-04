import Foundation
import Testing
@testable import MeetingBookCore

struct HydrationOrderTests {
    @Test(arguments: ["journal.wellness_day","journal.vitals_day"], ["de","en"])
    func hydrationReplacesItsSourceLabelWithoutLosingWritingCapacity(id:String,locale:String) throws {
        let catalog=try TemplateCatalog.builtIn()
        let entry=try #require(catalog.entries.first {$0.id==id})
        let de=locale=="de",wellness=id=="journal.wellness_day"
        let hydration=wellness ? (de ? "Wasser":"Water") : (de ? "Flüssigkeit (Gläser)":"Fluids (glasses)")
        let date=de ? "Datum":"Date",sleep=de ? "Schlaf (h)":"Sleep (h)",notes=de ? "Notizen":"Notes"
        let blocks=try #require(entry.variants[locale]?.first?.blocks)
        let expected:[TemplateBlock]
        var expectedLines:[String:Int]
        if wellness {
            let meals=de ? ["Frühstück","Mittag","Abend","Snacks"]:["Breakfast","Lunch","Dinner","Snacks"]
            let movement=de ? "Bewegung":"Movement",symptoms=de ? "Symptome / Beschwerden":"Symptoms / complaints"
            expected=[.init(.fields,items:[date]),.init(.fields,items:[sleep]),
                      .init(.scale,de ? "Schlafqualität":"Sleep quality",rows:5),.init(.scale,hydration,rows:8),
                      .init(.scale,de ? "Energie":"Energy",rows:5),.init(.scale,de ? "Stimmung":"Mood",rows:5),
                      .init(.scale,"Stress",rows:5)]+meals.map {.init(.fields,items:[$0])}+[
                      .init(.fields,items:[movement]),.init(.prompt,symptoms,rows:6),.init(.prompt,notes,rows:9),
                      .init(.checks,items:[de ? "Medikamente genommen":"Medication taken"],rows:2)]
            expectedLines=[date:1,sleep:1,movement:1,symptoms:6,notes:9]
            for meal in meals {expectedLines[meal]=1}
        } else {
            let weight=de ? "Gewicht":"Weight",symptoms=de ? "Symptome / Befinden":"Symptoms / condition"
            let measurements=de ? ["Uhrzeit","Blutdruck","Puls","Temp. °C","SpO2 %","Blutzucker","Notiz"] :
                                 ["Time","Blood pressure","Pulse","Temp. °C","SpO2 %","Glucose","Note"]
            let medications=de ? ["Medikament","Uhrzeit","Dosis"]:["Medication","Time","Dose"]
            expected=[.init(.fields,items:[date]),.init(.fields,items:[weight]),
                      .init(.table,items:measurements,rows:8,weights:[0.8,1.2,0.7,0.9,0.8,1,2],
                            rowLabels:["06:00","09:00","12:00","15:00","18:00","21:00","__:__","__:__"]),
                      .init(.prompt,symptoms,rows:2),.init(.text,de ? "Medikamente heute":"Medication today"),
                      .init(.table,items:medications,rows:3,weights:[3,1,1]),.init(.scale,hydration,rows:8),
                      .init(.fields,items:[sleep]),.init(.prompt,notes,rows:10)]
            expectedLines=[date:1,weight:1,sleep:1,symptoms:2,notes:10]
            for column in measurements.dropFirst() {for row in 1...8 {expectedLines[column+" · #\(row)"]=1}}
            for column in medications {for row in 1...3 {expectedLines[column+" · #\(row)"]=1}}
        }
        #expect(blocks==expected)
        #expect(blocks.filter {$0.label==hydration}.count==1)
        #expect(blocks.filter {$0.type == .scale && $0.label==hydration && $0.rows==8}.count==1)
        #expect(!blocks.contains {$0.type == .text && $0.label==hydration})
        for size in [24.0,30,36] {
            var c=TemplateConfiguration();c.locale=locale;c.textSize=size;c.inkAscent=size*1.02;c.inkDescent=size*0.3
            let pages=try catalog.instantiate(id:id,configuration:c)
            for page in pages {try TemplateValidation.validate(page)}
            let primitives=pages.flatMap(\.primitives),text=primitives.filter {$0.kind == .text}.map(\.text)
            #expect(text.filter {$0==hydration}.count==1)
            let position=try #require(primitives.firstIndex {$0.kind == .text && $0.text==hydration})
            try #require(primitives.count>position+16)
            let control=Array(primitives[(position+1)...(position+16)])
            #expect(control.filter {$0.kind == .ellipse}.count==8)
            #expect(control.filter {$0.kind == .text}.map(\.text)==(1...8).map(String.init))
            let hydrationIndex=try #require(text.firstIndex(of:hydration))
            if wellness {
                let before=try #require(text.firstIndex(of:de ? "Schlafqualität":"Sleep quality"))
                let after=try #require(text.firstIndex(of:de ? "Energie":"Energy"))
                #expect(before<hydrationIndex && hydrationIndex<after)
            } else {
                let before=try #require(text.firstIndex(of:de ? "Medikamente heute":"Medication today"))
                let after=try #require(text.firstIndex(of:sleep)),note=try #require(text.firstIndex(of:notes))
                #expect(before<hydrationIndex && hydrationIndex<after && after<note)
            }
            let lines=Dictionary(grouping:pages.flatMap(\.writingRegions),by:{$0.label ?? ""})
                .mapValues {$0.reduce(0) {$0+$1.baselines.count}}
            #expect(lines==expectedLines)
        }
    }
}
