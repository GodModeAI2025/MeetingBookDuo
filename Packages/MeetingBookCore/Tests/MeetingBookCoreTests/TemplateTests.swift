import Foundation
import Testing
@testable import MeetingBookCore

struct TemplateTests {
    @Test func catalogHasEverySourceIDAndRealLayouts() throws {
        let url = Bundle.module.url(forResource: "template-inventory", withExtension: "json")!
        let inventory = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let modules = inventory["modules"] as! [[String: Any]]
        let catalog = try TemplateCatalog.builtIn()
        for module in modules {
            let id = "journal." + (module["id"] as! String)
            #expect(catalog.entries.contains { $0.id == id })
            let pages = try catalog.instantiate(id: id, configuration: .init())
            #expect(!pages.isEmpty)
            for page in pages { try TemplateValidation.validate(page) }
        }
    }
    @Test func defaultRulingAndLegacyRoundTrip() throws {
        let catalog = try TemplateCatalog.builtIn()
        let page = try catalog.instantiate(id: "meetingbook.lined", configuration: .init()).first!
        #expect(page.geometry.width == 720)
        #expect(page.writingRegions[0].baselines[0] == 104)
        #expect(page.writingRegions[0].baselineStep == 40)
        let bytes = try JSONEncoder().encode(page)
        #expect(try JSONDecoder().decode(TemplateInstance.self, from: bytes) == page)
        let legacy = Data(#"{"version":1,"definitionID":"old","geometry":{"version":1,"width":720,"height":1000,"horizontalMargin":56,"verticalMargin":64,"ruling":40},"writingRegions":[{"id":"22222222-2222-2222-2222-222222222222","frame":{"x":56,"y":64,"width":608,"height":872},"baselines":[104,144]}]}"#.utf8)
        let restored = try JSONDecoder().decode(TemplateInstance.self, from: legacy)
        #expect(restored.writingRegions[0].baselines == [104,144])
        try TemplateValidation.validate(restored)
    }
    @Test func rejectsInvalidStoredRegions() throws {
        var page = TemplateInstance()
        page.writingRegions[0].baselines = []
        #expect(throws: (any Error).self) { try TemplateValidation.validate(page) }
        page = TemplateInstance(); page.writingRegions.append(page.writingRegions[0])
        #expect(throws: (any Error).self) { try TemplateValidation.validate(page) }
    }
    @Test func calendarBoundaries() throws {
        #expect(try CalendarLayout.days(year: 2024, month: 2) == 29)
        #expect(try CalendarLayout.days(year: 2025, month: 2) == 28)
        #expect(try CalendarLayout.isoWeek(year: 2021, month: 1, day: 1).year == 2020)
        #expect(try CalendarLayout.isoWeek(year: 2021, month: 1, day: 1).week == 53)
        #expect(try CalendarLayout.monthCells(year: 2026, month: 2, mondayFirst: true).first! == nil)
        #expect(try CalendarLayout.monthCells(year: 2026, month: 2, mondayFirst: false).first! == 1)
    }
}

struct TemplateCoverageTests {
    @Test func allVariantsSizesLocalesAndNativePages() throws {
        let catalog=try TemplateCatalog.builtIn()
        for entry in catalog.entries {
            for locale in ["de","en"] { for size in [24.0,30,36] {
                for variant in entry.variants[locale]! {
                    var c=TemplateConfiguration();c.locale=locale;c.textSize=size;c.inkAscent=size*0.85;c.inkDescent=size*0.25;c.variant=variant.id
                    let pages=try catalog.instantiate(id:entry.id,configuration:c)
                    #expect(!pages.isEmpty)
                    for page in pages {
                        try TemplateValidation.validate(page)
                        for region in page.writingRegions {
                            #expect(region.baselines.first!-region.frame.y >= c.inkAscent)
                            #expect(region.frame.y+region.frame.height-region.baselines.last! >= c.inkDescent)
                        }
                    }
                }
            } }
        }
    }
    @Test func hostileDefinitionsAndConfiguration() throws {
        #expect(throws:(any Error).self) {try TemplateValidation.decodeBlocks(Data(#"[{"type":"unknown"}]"#.utf8))}
        var b=TemplateBlock(.table,items:["A","B"],rows:2,weights:[1,-1])
        #expect(throws:(any Error).self) {try TemplateValidation.validate([b])}
        b.weights=[1];#expect(throws:(any Error).self) {try TemplateValidation.validate([b])}
        b.weights=[];b.rows=Int.max;#expect(throws:(any Error).self) {try TemplateValidation.validate([b])}
        var c=TemplateConfiguration();c.count=Int.max
        #expect(throws:(any Error).self) {try TemplateCatalog.builtIn().instantiate(id:"journal.lined",configuration:c)}
        c=TemplateConfiguration();c.inkAscent = .nan
        #expect(throws:(any Error).self) {try TemplateValidation.validate(c)}
        c=TemplateConfiguration();c.month=2;c.day=31
        #expect(throws:(any Error).self) {try TemplateValidation.validate(c)}
    }
    @Test func officialHolidayFixturesAndSchoolYear() throws {
        let de=try CalendarLayout.holidays(year:2026,jurisdiction:"DE")
        #expect(de.count==9)
        #expect(de.contains { $0.name=="Karfreitag" && $0.date == (try? CalendarLayout.date(year:2026,month:4,day:3)) })
        #expect(try CalendarLayout.holidays(year:2026,jurisdiction:"BB").count==12)
        #expect(try CalendarLayout.holidays(year:2028,jurisdiction:"BE").contains { $0.date == (try? CalendarLayout.date(year:2028,month:6,day:17)) })
        #expect(!(try CalendarLayout.holidays(year:2026,jurisdiction:"BY")).contains { $0.name=="Mariä Himmelfahrt" })
        #expect(try CalendarLayout.holidays(year:2026,jurisdiction:"none").isEmpty)
        let months=CalendarLayout.months(year:2026,schoolYear:true)
        #expect(months.first!.month==8 && months.last!.year==2027 && months.last!.month==7)
    }
    @Test func deterministicResolvedPlansAndPreservedReopen() throws {
        let catalog=try TemplateCatalog.builtIn();var c=TemplateConfiguration();c.variant="back"
        let a=try catalog.instantiate(id:"journal.body_map",configuration:c)
        #expect(a == (try catalog.instantiate(id:"journal.body_map",configuration:c)))
        for id in ["meetingbook.lined","meetingbook.blank","planner.year","custom.adr_journal.decision"] {
            #expect(try catalog.instantiate(id:id,configuration:.init())==catalog.instantiate(id:id,configuration:.init()))
        }
        let bytes=try JSONEncoder().encode(a);c.inkAscent=70
        _=try catalog.instantiate(id:"journal.body_map",configuration:c)
        #expect(try JSONDecoder().decode([TemplateInstance].self,from:bytes)==a)
    }
    @Test func allSourceFamiliesPresetsAndExamplesCovered() throws {
        let data=try Data(contentsOf:Bundle.module.url(forResource:"template-inventory",withExtension:"json")!)
        let source=try JSONSerialization.jsonObject(with:data) as! [String:Any],catalog=try TemplateCatalog.builtIn()
        #expect(catalog.presets.count==17)
        for (id,value) in source["presets"] as! [String:[Any]] {
            let expected=value[1] as! [[Any]],actual=catalog.presets.first {$0.id=="preset."+id}!.items
            #expect(actual.count==expected.count)
            for (item,row) in zip(actual,expected) {#expect(item.id=="journal."+(row[0] as! String));#expect(item.count==(row[1] as! Int))}
        }
        for id in source["singlePageExport"] as! [String] {#expect(catalog.entries.contains {$0.id=="journal."+id})}
        for id in source["plannerPageFunctions"] as! [String] {#expect(catalog.entries.contains {$0.sourceID==id})}
        for id in source["tools"] as! [String] {#expect(catalog.entries.contains {$0.id=="tool."+id})}
        #expect(catalog.entries.filter {$0.id.hasPrefix("custom.")}.count==20)
        for id in source["customBlockTypes"] as! [String] {#expect(TemplateBlockType(rawValue:id) != nil)}
        for preset in catalog.presets {for item in preset.items {#expect(catalog.entries.contains {$0.id==item.id})}}
    }
}

struct TemplatePersistenceTests {
    @Test func legacyFieldSetIsUnchangedForRevisionHashes() throws {
        let bytes=Data(#"{"version":1,"definitionID":"meetingbook.lined","geometry":{"version":1,"width":720,"height":1000,"horizontalMargin":56,"verticalMargin":64,"ruling":40},"writingRegions":[{"id":"22222222-2222-2222-2222-222222222222","frame":{"x":56,"y":64,"width":608,"height":872},"baselines":[104,144]}]}"#.utf8)
        let old=try JSONSerialization.jsonObject(with:bytes) as! NSDictionary
        let model=try JSONDecoder().decode(TemplateInstance.self,from:bytes)
        let reopened=try JSONSerialization.jsonObject(with:JSONEncoder().encode(model)) as! NSDictionary
        #expect(old==reopened)
    }
    @Test func compactOddCountAndWeeklyReflection() throws {
        let catalog=try TemplateCatalog.builtIn();var c=TemplateConfiguration();c.count=8;c.variant="compact"
        let p=try catalog.instantiate(id:"journal.gratitude_day",configuration:c)
        #expect(p.last?.variant=="review")
        #expect(p.first?.primitives.contains {$0.text.contains("Tage 1–2")}==true)
        c.locale="en"
        let english=try catalog.instantiate(id:"journal.gratitude_day",configuration:c)
        #expect(english.first?.primitives.contains {$0.text.contains("Days 1–2")}==true)
        c.locale="de"
        c.count=1
        let single=try catalog.instantiate(id:"journal.gratitude_day",configuration:c)
        #expect(single.flatMap(\.primitives).filter {$0.kind == .text && $0.text=="Tag 2"}.isEmpty)
        #expect(catalog.specialistNotebooks.count==4)
        for preset in catalog.specialistNotebooks {for item in preset.items {#expect(catalog.entries.contains {$0.id==item.id})}}
    }
    @Test func allTwentyOneBlocksRender() throws {
        let types:[TemplateBlockType]=[.fields,.heading,.text,.prompt,.table,.scale,.checks,.checklist,.lines,.dots,.weekdays,.faces,.battery,.box,.band,.linescale,.wheel,.rating_list,.paragraphs,.breath,.spacer]
        for type in types {
            let block=TemplateBlock(type,"Label",items:type == .breath ? ["A","B","C","D"]:["A","B","C"],rows:3,height:120)
            try TemplateValidation.validate([block])
            var layout=TemplateLayout(id:"test."+type.rawValue,title:type.rawValue,variant:"default",config:.init())
            let pages=try layout.resolve([block]);#expect(!pages.isEmpty)
            if type != .spacer {#expect(pages.contains {$0.primitives.count>1 || !$0.writingRegions.isEmpty})}
        }
    }
}

struct TemplateSemanticTests {
    @Test func rejectsUnknownVariantForEveryEntry() throws {
        let catalog=try TemplateCatalog.builtIn();var c=TemplateConfiguration();c.variant="missing-variant"
        for entry in catalog.entries {#expect(throws:(any Error).self) {try catalog.instantiate(id:entry.id,configuration:c)}}
    }
    @Test func titlesDoNotRepeatTheirOwnPrefix() throws {
        let catalog=try TemplateCatalog.builtIn()
        for id in ["journal.body_map","journal.lined","custom.adr_journal.decision"] {
            let title=try catalog.instantiate(id:id,configuration:.init())[0].primitives.first {$0.kind == .text}!.text
            #expect(!title.contains("Körperkarte · Körperkarte"))
            #expect(!title.contains("ADR · ADR"))
            #expect(!title.contains("Linierte Seiten · Linierte Seiten"))
        }
    }
    @Test func navigationTargetsAndSplitRowsRetainIdentity() throws {
        let catalog=try TemplateCatalog.builtIn()
        let projects=catalog.entries.first {$0.id=="planner.projects_home"}!,wellness=catalog.entries.first {$0.id=="planner.wellness_home"}!
        #expect(projects.navigationDestinationIDs != wellness.navigationDestinationIDs)
        #expect(projects.navigationDestinationIDs.allSatisfy {$0.hasPrefix("planner.project_")})
        for id in ["custom.adr_journal.adr_index","journal.todo"] {
            let pages=try catalog.instantiate(id:id,configuration:.init())
            #expect(pages.flatMap(\.primitives).filter {$0.text=="#1"}.count>=2)
        }
    }
    @Test func wideMeasuredTimeValuesReflowWithoutTruncation() throws {
        let catalog=try TemplateCatalog.builtIn();var c=TemplateConfiguration();c.variant="month";c.timeFieldWidth=600
        let pages=try catalog.instantiate(id:"tool.zeiterfassung",configuration:c)
        #expect(!pages.isEmpty)
        for p in pages {try TemplateValidation.validate(p)}
        let impossible=CalendarInterval(start:Date(timeIntervalSince1970:1e100),end:Date(timeIntervalSince1970:1e100),title:"bad",source:"import")
        #expect(throws:(any Error).self) {try impossible.validate()}
    }
}


struct TemplateReviewRegressionTests {
    @Test func gridRulesUseStoredBaselines() throws {
        let catalog=try TemplateCatalog.builtIn()
        for (id,variant) in [("journal.grid","default"),("planner.note","grid")] {
            var c=TemplateConfiguration();c.variant=variant
            for ascent in [20.4,25.5,30.6] {
                c.inkAscent=ascent
                for page in try catalog.instantiate(id:id,configuration:c) {
                    for baseline in page.writingRegions.flatMap(\.baselines) {
                        #expect(page.primitives.contains {$0.kind == .line && $0.points.count==2 && abs($0.points[0].y-baseline)<0.5 && abs($0.points[1].y-baseline)<0.5})
                    }
                }
            }
        }
    }
    @Test func promptCyclesPreserveSuccessiveEntriesAndWraparound() throws {
        let data=try Data(contentsOf:Bundle.module.url(forResource:"prompt-cycles",withExtension:"json")!)
        let fixture=try JSONDecoder().decode([String:[String:[String]]].self,from:data)
        let catalog=try TemplateCatalog.builtIn()
        for locale in ["de","en"] {
            for (id,key,variants) in [("journal.prompts","sc_prompt_list",["default"]),("journal.selfcare_day","sc_prompt_list",["default"]),("journal.gratitude_day","gj_prompt_list",["full","compact"]),("journal.travel_day","tj_prompt_list",["memories"]),("journal.prayer_day","pj_prompt_list",["default"])] {
                let expected=fixture[locale]![key]!
                for variant in variants {
                    var c=TemplateConfiguration();c.locale=locale;c.variant=variant;c.count=expected.count+1
                    let pages=try catalog.instantiate(id:id,configuration:c)
                    let actual=pages.flatMap(\.primitives).filter {$0.kind == .text}.compactMap {p in expected.first {p.text.hasSuffix($0)}}
                    #expect(actual == expected+[expected[0]])
                }
            }
        }
        let preset=try catalog.instantiate(id:"preset.selfcare",configuration:.init())
        let expected=fixture["de"]!["sc_prompt_list"]!
        let actual=preset.filter {$0.definitionID=="journal.prompts"}.flatMap(\.primitives).filter {$0.kind == .text}.compactMap {p in expected.first {p.text.hasSuffix($0)}}
        #expect(actual==Array(expected.prefix(20)))
    }
    @Test func undatedMealAndSleepAgreeWithMetadata() throws {
        let catalog=try TemplateCatalog.builtIn()
        for locale in ["de","en"] {for id in ["planner.meal","planner.sleep"] {
            let entry=catalog.entries.first {$0.id==id}!
            #expect(!entry.isDated);#expect(!entry.configurationFields.contains("year"))
            var c=TemplateConfiguration();c.locale=locale
            let first=try catalog.instantiate(id:id,configuration:c)
            c.year=2032;c.month=7;c.day=14
            let second=try catalog.instantiate(id:id,configuration:c)
            #expect(first.map(\.primitives)==second.map(\.primitives))
            if id=="planner.meal" {#expect(first.flatMap(\.primitives).contains {$0.text==(locale=="de" ? "Montag":"Monday")})}
            else {#expect(first.flatMap(\.writingRegions).contains {$0.label?.hasPrefix(locale=="de" ? "Datum":"Date")==true})}
        }}
    }
    @Test func malformedDiagramShapesThrowBeforeResolution() throws {
        let malformed:[TemplateBlock]=[.init(.markGrid,items:[],rows:1),.init(.markGrid,items:["A"],rows:0),.init(.wheel,items:["A","B"]),.init(.breath,items:["A"]),.init(.cornell,items:["A","B"]),.init(.quadrants,items:["A"]),.init(.chart,rows:0),.init(.weekdays),.init(.linescale,items:["A"]),.init(.scale,rows:1)]
        for block in malformed {
            let data=try JSONEncoder().encode([block])
            #expect(throws:(any Error).self) {try TemplateValidation.decodeBlocks(data)}
        }
        // Public Codable catalogs must validate before resolving, including the original crash.
        for block in malformed {
            let entry=TemplateEntry(id:"external.test",title:["de":"Test"],category:"paper",classification:"writing",variants:["de":[.init(id:"default",title:"Test",blocks:[block])]],sourceID:"external")
            let bytes=try JSONEncoder().encode(TemplateCatalog(entries:[entry],presets:[],specialistNotebooks:[]))
            let decoded=try JSONDecoder().decode(TemplateCatalog.self,from:bytes)
            #expect(throws:(any Error).self) {try decoded.instantiate(id:"external.test",configuration:.init())}
        }
        let valid:[TemplateBlock]=[.init(.markGrid,items:["A"],rows:1),.init(.wheel,items:["A","B","C"]),.init(.breath),.init(.cornell),.init(.quadrants),.init(.chart,rows:1),.init(.weekdays,items:["A"]),.init(.linescale,items:["A","B"]),.init(.scale,rows:2)]
        for block in valid {
            let blocks=try TemplateValidation.decodeBlocks(JSONEncoder().encode([block]))
            let entry=TemplateEntry(id:"external.valid",title:["de":"Test"],category:"paper",classification:"writing",variants:["de":[.init(id:"default",title:"Test",blocks:blocks)]],sourceID:"external")
            let decoded=try JSONDecoder().decode(TemplateCatalog.self,from:JSONEncoder().encode(TemplateCatalog(entries:[entry],presets:[],specialistNotebooks:[])))
            #expect(!(try decoded.instantiate(id:"external.valid",configuration:.init())).isEmpty)
        }
    }
    @Test func originalResolvedGridBytesRemainUnchanged() throws {
        let bytes=try Data(contentsOf:Bundle.module.url(forResource:"legacy-grid-v2",withExtension:"json")!)
        let page=try JSONDecoder().decode(TemplateInstance.self,from:bytes)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        #expect(try encoder.encode(page)==bytes)
        #expect(abs(page.writingRegions[0].baselines[0]-144.6)<0.001)
        try TemplateValidation.validate(page)
        _=try TemplateCatalog.builtIn().instantiate(id:"journal.grid",configuration:.init())
        #expect(try encoder.encode(page)==bytes)
    }
}

struct TravelOverviewBoundaryTests {
    // Actual UIFont measurements from the nine native enumeration pairs.
    private let metrics: [(Double,Double,Double,Double)] = [(24,20.232,5.472,66),(30,20.6396484375,9.90234375,96),(36,30.203999999999994,8.1,90),(24,16.51171875,7.921875,81),(30,25.169999999999998,6.75,78),(36,30.348,8.208,90),(24,20.136000000000003,5.4,66),(30,25.289999999999996,6.84,78),(36,24.767578125,11.8828125,112)]
    @Test(arguments: [100,101,500], ["all","summary"])
    func maximumOverviewRetainsGlobalKeysAndWritableCells(count:Int,variant:String) throws {
        let catalog=try TemplateCatalog.builtIn()
        for locale in ["de","en"] {for (size,ascent,descent,timeWidth) in metrics {
            var c=TemplateConfiguration();c.locale=locale;c.count=count;c.variant=variant=="all" ? nil:variant
            c.textSize=size;c.inkAscent=ascent;c.inkDescent=descent;c.timeFieldWidth=timeWidth
            let pages=try catalog.instantiate(id:"tool.reisekosten",configuration:c)
            for page in pages {try TemplateValidation.validate(page)}
            let summary=pages.filter{$0.variant=="summary"}
            let regions=summary.flatMap(\.writingRegions)
            #expect(regions.count==count*6)
            for row in 1...count {
                let labels=regions.compactMap(\.label).filter{$0.hasSuffix(" · #\(row)")}
                #expect(labels.count==6)
                #expect(labels.filter{$0.hasPrefix(locale=="de" ? "Reise / Datum":"Trip / date")}.count==2)
                let visible=summary.flatMap(\.primitives).filter{$0.kind == .text && $0.text=="#\(row)"}
                #expect(visible.count==2)
            }
            if count==100 {
                let entry=try #require(catalog.entries.first{$0.id=="tool.reisekosten"})
                var layout=TemplateLayout(id:entry.id,title:entry.title(locale:locale)+" · \(c.year)",variant:"summary",config:c)
                let columns=locale=="de" ? ["Reise / Datum","Ziel / Anlass","Von / bis","Gesamt","Erstattet"]:["Trip / date","Destination / purpose","From / to","Total","Reimbursed"]
                let unchanged=try layout.resolve([.init(.table,locale=="de" ? "Reiseübersicht":"Trip overview",items:columns,rows:100)])
                #expect(summary==unchanged)
            }
        }}
    }
}
