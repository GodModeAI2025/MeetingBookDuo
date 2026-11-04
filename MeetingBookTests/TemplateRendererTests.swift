import XCTest
import UIKit
import CoreText
import MeetingBookCore
@testable import MeetingBook

final class TemplateRendererTests: XCTestCase {
    @MainActor func testMeasuredFontsFitStoredRegionsAndDrawnRules() throws {
        let catalog=try TemplateCatalog.builtIn()
        for fontID in ["bundled.caveat","bundled.gochi-hand","system"] {
            for size in [24.0,30,36] {
                let font=HandwritingFontCatalog.font(catalogID:fontID,size:size)
                var configuration=TemplateConfiguration();configuration.textSize=size
                configuration=try TemplateRenderer.measuredConfiguration(configuration,font:font)
                let pages=try catalog.instantiate(id:"meetingbook.lined",configuration:configuration)
                let page=pages[0],bounds=HandwritingFontCatalog.mandatoryGlyphBounds(for:font)
                for region in page.writingRegions {
                    XCTAssertGreaterThanOrEqual(region.baselines.first!-bounds.maxY,region.frame.y)
                    XCTAssertLessThanOrEqual(region.baselines.last!-bounds.minY,region.frame.y+region.frame.height)
                    for baseline in region.baselines {
                        XCTAssertTrue(page.primitives.contains {$0.kind == .line && abs($0.points[0].y-baseline)<0.5})
                    }
                }
                var monthConfiguration=configuration;monthConfiguration.variant="month"
                let timePages=try catalog.instantiate(id:"tool.zeiterfassung",configuration:monthConfiguration)
                let timeRegion=timePages.flatMap(\.writingRegions).first {$0.label?.hasPrefix("Beginn") == true}!
                let value=CTLineCreateWithAttributedString(NSAttributedString(string:"23:59",attributes:[.font:font]))
                XCTAssertLessThanOrEqual(CTLineGetTypographicBounds(value,nil,nil,nil),timeRegion.frame.width)
                let image=try TemplateRenderer.preview(page)
                XCTAssertEqual(image.size,CGSize(width:720,height:1000))
            }
        }
    }
    @MainActor func testSourcePromptCycleLabelsRenderAtLargeSize() throws {
        let catalog=try TemplateCatalog.builtIn()
        for locale in ["de","en"] {
            for (id,variant,count) in [("journal.prompts","default",25),("journal.selfcare_day","default",25),("journal.gratitude_day","full",22),("journal.gratitude_day","compact",23),("journal.travel_day","memories",13),("journal.prayer_day","default",13)] {
                var c=TemplateConfiguration();c.locale=locale;c.variant=variant;c.count=count;c.textSize=36
                for page in try catalog.instantiate(id:id,configuration:c) {XCTAssertNotNil(try TemplateRenderer.preview(page).cgImage)}
            }
        }
    }
    @MainActor func testMeasuredGridFontsUseVisibleStoredRules() throws {
        let catalog=try TemplateCatalog.builtIn()
        for fontID in ["bundled.caveat","bundled.gochi-hand","system"] {for size in [24.0,30,36] {
            let font=HandwritingFontCatalog.font(catalogID:fontID,size:size)
            for (id,variant) in [("journal.grid","default"),("planner.note","grid")] {
                var c=TemplateConfiguration();c.variant=variant
                c=try TemplateRenderer.measuredConfiguration(c,font:font)
                for page in try catalog.instantiate(id:id,configuration:c) {
                    for region in page.writingRegions {for baseline in region.baselines {
                        XCTAssertTrue(page.primitives.contains {$0.kind == .line && $0.points.count==2 && abs($0.points[0].y-baseline)<0.5 && abs($0.points[1].y-baseline)<0.5})
                    }}
                    XCTAssertNotNil(try TemplateRenderer.preview(page).cgImage)
                }
            }
        }}
    }
    @MainActor func testLegacyAndResolvedTemplateSurviveStoreReopen() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root),note=try await store.createNote(title:"Templates")
        let initial=try await store.openPage(id:note.pageIDs[0])
        var legacy=initial.content;legacy.template.version=1
        _=try await store.commit(.init(pageID:initial.id,expectedRevisionID:initial.currentRevisionID,content:legacy))
        let oldStore=try await NotebookStore.open(root:root)
        let oldPage=try await oldStore.openPage(id:initial.id);XCTAssertEqual(oldPage.content,legacy)
        var next=oldPage.content
        next.template=try TemplateCatalog.builtIn().instantiate(id:"journal.cornell",configuration:.init())[0]
        let saved=try await oldStore.commit(.init(pageID:oldPage.id,expectedRevisionID:oldPage.currentRevisionID,content:next))
        var changedDefaults=TemplateConfiguration();changedDefaults.inkAscent=60
        _=try TemplateCatalog.builtIn().instantiate(id:"meetingbook.lined",configuration:changedDefaults)
        let reopened=try await NotebookStore.open(root:root),actual=try await reopened.openPage(id:oldPage.id)
        XCTAssertEqual(actual.content,next);XCTAssertEqual(actual.currentRevisionID,saved.revision.id)
        let previous=try await reopened.recoverPrevious(pageID:oldPage.id);XCTAssertEqual(previous.content,legacy)
    }
    // Generated by compiling unchanged Models/Geometry at 76df174; never encoded by the new model.
    @MainActor func testOriginalLegacyPayloadHashAndStoreReopen() async throws {
        let bytes=Data(#"{"images":[],"style":{"fontSize":30,"ink":"black","paper":"ivory"},"template":{"definitionID":"meetingbook.lined","geometry":{"height":1000,"horizontalMargin":56,"ruling":40,"version":1,"verticalMargin":64,"width":720},"version":1,"writingRegions":[{"baselines":[104,144,184,224,264,304,344,384,424,464,504,544,584,624,664,704,744,784,824,864,904],"frame":{"height":872,"width":608,"x":56,"y":64},"id":"22222222-2222-2222-2222-222222222222"}]},"textBlocks":[{"frame":{"height":872,"width":608,"x":56,"y":64},"id":"33333333-3333-3333-3333-333333333333","text":"Ältere Notiz € – unverändert","zIndex":0}],"version":1}"#.utf8)
        let originalHash="b359314a8f2bc9fc76f2277cefd1b716920140e5a3ef03511779003076849a33"
        XCTAssertEqual(AssetStore.hash(bytes),originalHash)
        let old=try JSONDecoder().decode(PageContent.self,from:bytes)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        XCTAssertEqual(try encoder.encode(old),bytes)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root),note=try await store.createNote(title:"Original fixture")
        let backup=try await store.migrationBackup()
        var envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:backup)) as! [String:Any]
        var records=(envelope["records"] as! [[String:String]]).filter{["library","page","revision","outbox","pageTombstone"].contains($0["kind"]!)}
        let libraryIndex=try XCTUnwrap(records.firstIndex{$0["kind"]=="library"})
        var legacyLibrary=try JSONSerialization.jsonObject(with:Data(base64Encoded:records[libraryIndex]["payload"]!)!) as! [String:Any]
        legacyLibrary["version"]=1;legacyLibrary.removeValue(forKey:"ownership")
        legacyLibrary["notes"]=(legacyLibrary["notes"] as? [[String:Any]])?.map { note in
            var legacy=note;legacy.removeValue(forKey:"createdAt");legacy.removeValue(forKey:"modifiedAt");return legacy
        }
        records[libraryIndex]["payload"]=try JSONSerialization.data(withJSONObject:legacyLibrary,options:[.sortedKeys]).base64EncodedString()
        envelope["version"]=1
        let content=try JSONSerialization.jsonObject(with:bytes)
        for i in records.indices where records[i]["kind"]=="page" || records[i]["kind"]=="revision" {
            var value=try JSONSerialization.jsonObject(with:Data(base64Encoded:records[i]["payload"]!)!) as! [String:Any]
            value["content"]=content
            if records[i]["kind"]=="revision" {value["contentHash"]=originalHash}
            records[i]["payload"]=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).base64EncodedString()
        }
        envelope["records"]=records
        // Establish genuine predecessor bytes before this revision identity is ever materialized here.
        let destinationRoot=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination=try await NotebookStore.open(root:destinationRoot),fixture=try await destination.migrationBackup()
        try JSONSerialization.data(withJSONObject:envelope,options:[.sortedKeys]).write(to:fixture)
        try await destination.rollbackMigrationBackup(at:fixture)
        let reopened=try await NotebookStore.open(root:destinationRoot)
        let page=try await reopened.openPage(id:note.pageIDs[0])
        XCTAssertEqual(page.content,old)
        XCTAssertEqual(AssetStore.hash(try encoder.encode(page.content)),originalHash)
    }
    @MainActor func testDistinctNativeDiagramAndContinuationPreviews() throws {
        let catalog=try TemplateCatalog.builtIn()
        for (id,variant) in [("journal.body_map","front"),("journal.body_map","back"),("journal.exercises","breath"),("journal.exercises","senses"),("journal.exercises","body-scan"),("journal.gratitude_day","compact"),("journal.fever_curve","default"),("journal.life_wheel","default"),("planner.day_2","default"),("tool.jahreskalender","full-year")] {
            var c=TemplateConfiguration();c.variant=variant;c.textSize=36
            let pages=try catalog.instantiate(id:id,configuration:c)
            for page in pages {let image=try TemplateRenderer.preview(page);XCTAssertNotNil(image.cgImage)}
        }
    }
}

@MainActor extension TemplateRendererTests {
    func testGeneratedFirstRegionAcceptsNativeFallbackAndSavesExactUnicode() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let specimen="ÄÖÜ äöü ß € e\u{301} é 👩🏽‍💻 日本語"
        for fontID in ["bundled.caveat","bundled.gochi-hand","system"] {
            for size in [24.0,30,36] {
                let font=HandwritingFontCatalog.font(catalogID:fontID,size:size)
                let expectedNames=["bundled.caveat":"Caveat-Regular","bundled.gochi-hand":"GochiHand-Regular"]
                if let expected=expectedNames[fontID] {XCTAssertEqual(font.fontName,expected)}
                XCTAssertEqual(font.pointSize,size)
                var configuration=TemplateConfiguration();configuration.locale="en"
                configuration=try TemplateRenderer.measuredConfiguration(configuration,font:font)
                for id in ["journal.lined","journal.grid","journal.cornell","planner.month","tool.zeiterfassung"] {
                    let sample=id == "journal.lined" ? specimen : "e\u{301} 👩🏽‍💻"
                    var content=PageContent();content.version=2
                    content.template=try TemplateCatalog.builtIn().instantiate(id:id,configuration:configuration)[0]
                    let region=try XCTUnwrap(content.template.writingRegions.first)
                    var block=TextBlock(text:sample,frame:region.frame)
                    block.fontCatalogID=fontID;block.fontSize=size
                    block.writingRegionID=region.id;block.baselineIndex=0
                    content.textBlocks=[block]
                    let text=TextBlockView(block:block,content:content,versions:[])
                    XCTAssertEqual(try XCTUnwrap(text.canonicalBaselines().first),try XCTUnwrap(region.baselines.first),accuracy:0.5)
                    XCTAssertNoThrow(try text.validateVisibleContent(),"\(id) \(fontID) \(size)")
                    let note=try await store.createNote(title:"Fallback regression",contents:[content])
                    let reopened=try await store.openPage(id:note.pages[0].id)
                    XCTAssertEqual(Array(reopened.content.textBlocks[0].text.utf8),Array(sample.utf8))
                }
            }
        }
    }
}

@MainActor extension TemplateRendererTests {
    func testWheelLabelClearanceNativePreviews() throws {
        let catalog = try TemplateCatalog.builtIn()
        for (profile, viewport, fontID) in [
            ("phone402x874-caveat24", CGSize(width: 402, height: 874), "bundled.caveat"),
            ("ipad1032x1376-gochi24", CGSize(width: 1032, height: 1376), "bundled.gochi-hand")
        ] {
            let font = HandwritingFontCatalog.font(catalogID: fontID, size: 24)
            for locale in ["de", "en"] {
                var config = TemplateConfiguration(); config.locale = locale
                config = try TemplateRenderer.measuredConfiguration(config, font: font)
                let pages = try catalog.instantiate(id: "journal.life_wheel", configuration: config)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let inputs = try encoder.encode(pages)
                let inputAttachment = XCTAttachment(data: inputs, uniformTypeIdentifier: "public.json")
                inputAttachment.name = "wheel-\(profile)-\(locale)-resolved-inputs"
                inputAttachment.lifetime = .keepAlways; add(inputAttachment)
                print("NATIVE_WHEEL_PLAN \(profile) \(locale) pages=\(pages.count) ascent=\(config.inkAscent) descent=\(config.inkDescent)")
                for (index, page) in pages.enumerated() {
                    var content = PageContent(); content.version = 2; content.template = page
                    content.style.fontSize = 24
                    let lowerRegion = try XCTUnwrap(page.writingRegions.last)
                    var sample = TextBlock(text: locale == "de" ? "Mein nächster Schritt" : "My next step", frame: lowerRegion.frame)
                    sample.fontCatalogID = fontID; sample.fontSize = 24
                    sample.writingRegionID = lowerRegion.id; sample.baselineIndex = 0
                    content.textBlocks = [sample]
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                    var failure: (any Error)?
                    let image = UIGraphicsImageRenderer(size: viewport, format: format).image { renderer in
                        let context = renderer.cgContext
                        context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(origin: .zero, size: viewport))
                        let scale = min(viewport.width / 720, viewport.height / 1000)
                        context.translateBy(x: (viewport.width - 720 * scale) / 2, y: (viewport.height - 1000 * scale) / 2)
                        context.scaleBy(x: scale, y: scale)
                        do { try PageRenderer.draw(content, resources: .init(), in: context) }
                        catch { failure = error }
                    }
                    if let failure { throw failure }
                    XCTAssertEqual(image.size, viewport)
                    let name = "wheel-\(profile)-\(locale)-page-\(index + 1)"
                    let attachment = XCTAttachment(image: image)
                    attachment.name = name
                    attachment.lifetime = .keepAlways; add(attachment)
                    let contentAttachment = XCTAttachment(data: try encoder.encode(content), uniformTypeIdentifier: "public.json")
                    contentAttachment.name = name + "-content"
                    contentAttachment.lifetime = .keepAlways; add(contentAttachment)
                }
            }
        }
    }
}
