import XCTest
import UIKit
import PencilKit
import Darwin
import PDFKit
import ImageIO
import MeetingBookCore
@testable import MeetingBook

@MainActor final class ExportTests: XCTestCase {
    func testFinalPDFSemanticTextAndPNGDimensionsAndTXTOmissions() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("store"))
        let note=try await store.createNote(title:"Export")
        var page=try await store.openPage(id:note.pageIDs[0]);page.content.version=2
        var text=TextBlock(text:"ÄÖÜ äöü ß € MeetingBook");text.fontCatalogID="bundled.caveat";page.content.textBlocks=[text]
        let exporter=ExportService(store:store,root:root.appendingPathComponent("exports"))
        let pdf=try await exporter.export(.init(format:.pdf,pages:[page],fonts:[],unsaved:true))
        let document=try XCTUnwrap(PDFDocument(url:pdf.urls[0]))
        XCTAssertEqual(document.pageCount,1);XCTAssertTrue(document.string?.contains("MeetingBook") == true)
        XCTAssertEqual(document.page(at:0)?.bounds(for:.mediaBox),CGRect(x:0,y:0,width:720,height:1000))
        let png=try await exporter.export(.init(format:.png,pages:[page],fonts:[],unsaved:true))
        let source=try XCTUnwrap(CGImageSourceCreateWithURL(png.urls[0] as CFURL,nil))
        let properties=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int,1440)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int,2000)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary]);XCTAssertNil(properties[kCGImagePropertyExifDictionary])
        let txt=try await exporter.export(.init(format:.txt,pages:[page],fonts:[],unsaved:true))
        let body=try String(contentsOf:txt.urls[0],encoding:.utf8)
        XCTAssertTrue(body.contains(text.text));XCTAssertTrue(body.contains("UNSAVED"));XCTAssertTrue(body.contains("Drawings") || body.contains("Zeichnungen"))
        try await exporter.remove(pdf);XCTAssertFalse(FileManager.default.fileExists(atPath:pdf.urls[0].path))
    }
}

@MainActor final class RecoveryWindowTests: XCTestCase {
    func testRestoreGateRetainsOtherWindowDraftAndOpenGlyphEditor() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root)
        let note=try await store.createNote(title:"Windows")
        let session=EditorSession(store:store,snapshot:try await store.openNote(id:note.id))
        let model=LibraryModel();model.register(session)
        var content=session.activeContent;content.textBlocks=[TextBlock(text:"unsaved other window")]
        session.setDraft(content,pageID:session.activePageID)
        XCTAssertThrowsError(try model.beginRestore())
        XCTAssertEqual(session.activeContent,content);XCTAssertFalse(model.restoring)
        let clean=LibraryModel(),token=UUID();clean.openFontStudios.insert(token)
        XCTAssertThrowsError(try clean.beginRestore());XCTAssertFalse(clean.restoring)
        clean.openFontStudios.remove(token);try clean.beginRestore();XCTAssertTrue(clean.restoring)
        clean.endRestore(committed:false);XCTAssertFalse(clean.restoring);XCTAssertEqual(clean.restoreGeneration,0)
    }
}

@MainActor final class ExportEvidenceTests: XCTestCase {
    func testMixedGeneratedFontArtifactsResponsivenessAndCancellation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Task6Evidence-"+UUID().uuidString)
        let store=try await NotebookStore.open(root:root.appendingPathComponent("store"))
        let id=UUID(),name="MeetingBook-"+id.uuidString.replacingOccurrences(of:"-",with:"")
        let outline=GlyphOutline(contours:[[.init(50,0),.init(50,650),.init(500,650),.init(500,0)]],advanceWidth:600)
        var glyphs=Dictionary(uniqueKeysWithValues:FontCoverage.required.map{($0,outline)})
        glyphs[32]=GlyphOutline(contours:[],advanceWidth:300)
        let ttf=try TrueTypeWriter.build(glyphs:glyphs,postScriptName:name)
        let asset=try await store.assets.stage(data:ttf),hash=try await store.assets.finalize(asset)
        let font=FontVersion(id:id,assetHash:hash,postScriptName:name,metrics:FontMetrics())
        let path=PKStrokePath(controlPoints:[CGPoint(x:80,y:440),CGPoint(x:180,y:390),CGPoint(x:280,y:440)].enumerated().map { index,point in PKStrokePoint(location:point,timeOffset:Double(index)*0.1,size:CGSize(width:5,height:5),opacity:1,force:1,azimuth:0,altitude:.pi/2) },creationDate:Date())
        let drawing=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.systemBlue),path:path)])
        let ink=try await store.assets.stage(data:drawing.dataRepresentation()),inkHash=try await store.assets.finalize(ink)
        let metrics=GlyphCaptureMetrics(baselineY:300,emSize:300,xHeight:150,capHeight:210,advanceWidth:600,leftBearing:40)
        let project=FontProject(name:"Synthetic export font",glyphAssetHashes:[65:inkHash],glyphMetrics:[65:metrics],versions:[font]);try await store.saveFontProject(project)
        let image=try await ImageImportService(assets:store.assets).importData(solidPNG(width:240,height:160,color:.systemRed))
        let preview=try await ImageImportService(assets:store.assets).importData(solidPNG(width:120,height:80,color:.systemBlue))
        var content=PageContent();content.version=2;content.style.paper="cream"
        content.template.writingRegions[0].baselines=[104,151,205,259,313,367,421,475,529,583,637,691,745,799,853,907]
        let region=content.template.writingRegions[0]
        var bundled=TextBlock(text:"Bundled ÄÖÜ äöü ß €\ne\u{301} 👩🏽‍💻 日本語");bundled.fontCatalogID="bundled.caveat";bundled.writingRegionID=region.id;bundled.baselineIndex=0
        var personal=TextBlock(text:"PERSONAL ÄÖÜ äöü ß €",frame:.init(x:56,y:275,width:608,height:120),fontVersionID:font.id);personal.writingRegionID=region.id;personal.baselineIndex=4
        content.textBlocks=[bundled,personal];content.drawingAssetHash=inkHash
        var element=ImageElement(frame:.init(x:380,y:500,width:240,height:160),zIndex:1,assetHash:image.assetHash,altText:"Red original, blue preview fixture")
        element.previewAssetHash=preview.assetHash;content.images=[element]
        let note=try await store.createNote(title:"Export evidence",contents:[content]),page=note.pages[0]
        let exporter=ExportService(store:store,root:root.appendingPathComponent("exports"))
        let frozen=ExportRequest(format:.pdf,pages:[page],fonts:[font],unsaved:false)
        var changed=content;changed.textBlocks[0].text="CHANGED AFTER CAPTURE"
        _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:changed))
        let pdf=try await exporter.export(frozen),png=try await exporter.export(.init(format:.png,pages:[page],fonts:[font],unsaved:false))
        let txt=try await exporter.export(.init(format:.txt,pages:[page],fonts:[font],unsaved:false))
        let document=try XCTUnwrap(PDFDocument(url:pdf.urls[0])),extracted=document.string ?? ""
        XCTAssertTrue(try Data(contentsOf:txt.urls[0]).range(of:Data(bundled.text.utf8)) != nil)
        XCTAssertFalse(pdf.warnings.isEmpty,"fallback extraction limitation must be disclosed");XCTAssertTrue(extracted.contains("Bundled"));XCTAssertTrue(extracted.contains("PERSONAL"));XCTAssertFalse(extracted.contains("CHANGED AFTER CAPTURE"))
        for scalar in "ÄÖÜäöüß€".unicodeScalars { XCTAssertTrue(extracted.unicodeScalars.contains(scalar),"PDF lost \(scalar)") }
        let imageFile=try XCTUnwrap(UIImage(contentsOfFile:png.urls[0].path)),cg=try XCTUnwrap(imageFile.cgImage)
        var pixel=[UInt8](repeating:0,count:4)
        pixel.withUnsafeMutableBytes { bytes in
            let context=CGContext(data:bytes.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x:-1000,y:-900);context.draw(cg,in:CGRect(x:0,y:0,width:1440,height:2000))
        }
        XCTAssertGreaterThan(pixel[0],200);XCTAssertLessThan(pixel[2],100,"export used the blue preview instead of red original")
        let previewImage=try await PageRenderer.resources(for:content,store:store)
        let native=try PageRenderer.image(content,resources:previewImage)
        let attachment=XCTAttachment(image:imageFile);attachment.name="Final mixed PNG export with original image";attachment.lifetime = .keepAlways;add(attachment)
        let nativeAttachment=XCTAttachment(image:native);nativeAttachment.name="Shared native preview uses blue working image";nativeAttachment.lifetime = .keepAlways;add(nativeAttachment)
        let package=try await NotebookPackage(root:root.appendingPathComponent("packages")).create(store:store)
        let restored=try await NotebookStore.open(root:root.appendingPathComponent("restored")),restore=RestoreService(store:restored,root:root.appendingPathComponent("imports"))
        let inspection=try await restore.inspectImport(url:package);try await restore.restore(inspection,policy:.replace)
        let restoredProjects=await restored.fontProjects();XCTAssertEqual(restoredProjects,[project])
        let restoredPage=try await restored.openPage(id:page.id);XCTAssertEqual(restoredPage.content,changed)
        let recovered=try await restored.recoverPrevious(pageID:page.id);XCTAssertEqual(recovered.content,content)
        var warmPDF:[Double]=[],warmPNG:[Double]=[],warmPDFPhases:[ExportPageTiming]=[],warmPNGPhases:[ExportPageTiming]=[]
        for _ in 0..<3 {
            let warm=try await exporter.export(frozen);warmPDF+=warm.pageDrawMilliseconds;warmPDFPhases+=warm.pageTimings;try await exporter.remove(warm)
            let warmImage=try await exporter.export(.init(format:.png,pages:[page],fonts:[font],unsaved:false));warmPNG+=warmImage.pageDrawMilliseconds;warmPNGPhases+=warmImage.pageTimings;try await exporter.remove(warmImage)
        }
        let stress=try await ImageImportService(assets:store.assets).importData(solidPNG(width:6000,height:6000,color:.systemGreen))
        var stressPage=page;stressPage.content.images=[ImageElement(frame:.init(x:56,y:500,width:600,height:400),assetHash:stress.assetHash,altText:"36 megapixel stress fixture")]
        let stressArtifact=try await exporter.export(.init(format:.png,pages:[stressPage],fonts:[font],unsaved:false))
        let extra=try await ImageImportService(assets:store.assets).importData(solidPNG(width:2100,height:2000,color:.systemOrange))
        var overBudget=stressPage;overBudget.content.images.append(ImageElement(frame:.init(x:56,y:100,width:100,height:100),assetHash:extra.assetHash,altText:"Budget boundary"))
        do { _ = try await exporter.export(.init(format:.png,pages:[overBudget],fonts:[font],unsaved:false));XCTFail("over-budget page published") }
        catch { guard case TransferError.pageTooLarge = error else { throw error } }

        var stressResident:[UInt64]=[residentBytes()]
        for _ in 0..<2 {
            let repeatStress=try await exporter.export(.init(format:.png,pages:[stressPage],fonts:[font],unsaved:false));try await exporter.remove(repeatStress)
            stressResident.append(residentBytes())
        }
        let many=(0..<100).map { _ in PageSnapshot(noteID:page.noteID,orderKey:0,content:content) }
        let task=Task { try await exporter.export(.init(format:.pdf,pages:many,fonts:[font],unsaved:false)) }
        try await Task.sleep(for:.milliseconds(30));let cancelledAt=ContinuousClock.now;task.cancel()
        do { _ = try await task.value;XCTFail("cancelled export published") } catch { XCTAssertTrue(error is CancellationError) }
        let duration=cancelledAt.duration(to:.now),cancelMS=Double(duration.components.seconds)*1000+Double(duration.components.attoseconds)/1e15
        let pins=await store.assets.pinnedHashes;XCTAssertTrue(pins.isEmpty)
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let report:[String:Any] = ["normalPDFDrawMilliseconds":pdf.pageDrawMilliseconds,"warmPDFDrawMilliseconds":warmPDF,"warmPDFPhases":try JSONSerialization.jsonObject(with:JSONEncoder().encode(warmPDFPhases)),"warmPNGPhases":try JSONSerialization.jsonObject(with:JSONEncoder().encode(warmPNGPhases)),"warmPNGDrawMilliseconds":warmPNG,"residentBytesAfterRepeatedStress":stressResident,"normalPDFPhases":try JSONSerialization.jsonObject(with:JSONEncoder().encode(pdf.pageTimings)),"normalPNGPhases":try JSONSerialization.jsonObject(with:JSONEncoder().encode(png.pageTimings)),"stressPhases":try JSONSerialization.jsonObject(with:JSONEncoder().encode(stressArtifact.pageTimings)),"normalPNGDrawMilliseconds":png.pageDrawMilliseconds,"stress36MPDrawMilliseconds":stressArtifact.pageDrawMilliseconds,"cancelMilliseconds":cancelMS,"processPeakResidentBytes":usage.ru_maxrss,"pdfText":extracted,"environment":ProcessInfo.processInfo.operatingSystemVersionString]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("metrics.json"))
        for (source,name) in [(pdf.urls[0],"mixed.pdf"),(png.urls[0],"mixed.png"),(txt.urls[0],"mixed.txt"),(package,"complete.notebookpkg"),(stressArtifact.urls[0],"stress.png")] { try FileManager.default.copyItem(at:source,to:root.appendingPathComponent(name)) }
        print("TASK6_EVIDENCE_ROOT=\(root.path)")
        XCTAssertLessThan(warmPDF.max() ?? 1000,100);XCTAssertLessThan(warmPNG.max() ?? 1000,100)
        XCTAssertLessThan(pdf.pageDrawMilliseconds.max() ?? 1000,100,"normal PDF main draw exceeded target")
        XCTAssertLessThan(png.pageDrawMilliseconds.max() ?? 1000,100,"normal PNG main draw exceeded target")
        XCTAssertLessThan(cancelMS,1000)
    }
    private func residentBytes() -> UInt64 {
        var info=mach_task_basic_info(),count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) }
        }
        XCTAssertEqual(result,KERN_SUCCESS);return info.resident_size
    }
    private func solidPNG(width: Int,height: Int,color: UIColor) -> Data {
        autoreleasepool {
            let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true
            return UIGraphicsImageRenderer(size:CGSize(width:width,height:height),format:format).image { renderer in color.setFill();renderer.fill(CGRect(x:0,y:0,width:width,height:height)) }.pngData()!
        }
    }
}
