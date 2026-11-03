import XCTest
import PencilKit
import CoreText
import PDFKit
import MeetingBookCore
@testable import MeetingBook

@MainActor final class FontServiceTests: XCTestCase {
    let metrics=GlyphCaptureMetrics(baselineY:80,emSize:100,xHeight:50,capHeight:70,advanceWidth:70,leftBearing:5)
    func stroke(_ points: [CGPoint], width: CGFloat = 4, height: CGFloat? = nil) -> PKStroke {
        PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points.enumerated().map { i,p in
            PKStrokePoint(location:p,timeOffset:Double(i)*0.05,size:CGSize(width:width,height:height ?? width),opacity:1,force:1,azimuth:0,altitude:.pi/2)
        },creationDate:Date(timeIntervalSince1970:0)))
    }
    func ring(_ x: CGFloat = 30, _ y: CGFloat = 55, _ rx: CGFloat = 18, _ ry: CGFloat = 22) -> PKStroke {
        stroke((0...48).map { i in let angle=Double(i)/48 * 2 * .pi;return CGPoint(x:x+cos(angle)*rx,y:y+sin(angle)*ry) })
    }
    func sample(_ character: Character) -> PKDrawing {
        let body=stroke([CGPoint(x:20,y:42),CGPoint(x:20,y:77)])
        let dot=stroke([CGPoint(x:20,y:25),CGPoint(x:20.01,y:25)],width:6)
        switch character {
        case "i": return PKDrawing(strokes:[body,dot])
        case "j": return PKDrawing(strokes:[stroke([CGPoint(x:25,y:42),CGPoint(x:25,y:90),CGPoint(x:15,y:96)]),dot])
        case "o": return PKDrawing(strokes:[ring()])
        case "ö","ä","ü","Ä","Ö","Ü": return PKDrawing(strokes:[ring(),stroke([CGPoint(x:20,y:20),CGPoint(x:20.01,y:20)],width:5),stroke([CGPoint(x:40,y:20),CGPoint(x:40.01,y:20)],width:5)])
        case "8": return PKDrawing(strokes:[ring(30,30,17,17),ring(30,64,17,17)])
        case "B":
            let arcs=[CGFloat(30),CGFloat(64)].map { y in stroke((0...24).map { i in let a=Double(i)/24 * .pi - .pi/2;return CGPoint(x:30+cos(a)*17,y:y+sin(a)*17) }) }
            return PKDrawing(strokes:arcs+[stroke([CGPoint(x:30,y:13),CGPoint(x:30,y:81)])])
        case "ß": return PKDrawing(strokes:[stroke([CGPoint(x:14,y:80),CGPoint(x:14,y:30),CGPoint(x:25,y:16),CGPoint(x:40,y:20),CGPoint(x:40,y:35),CGPoint(x:26,y:43),CGPoint(x:45,y:55),CGPoint(x:43,y:72),CGPoint(x:25,y:78)])])
        default: return PKDrawing(strokes:[stroke([CGPoint(x:12,y:77),CGPoint(x:30,y:14),CGPoint(x:48,y:77)]),stroke([CGPoint(x:20,y:56),CGPoint(x:40,y:56)])])
        }
    }
    func path(_ outline: GlyphOutline) -> CGPath {
        let path=CGMutablePath()
        for contour in outline.contours { path.move(to:CGPoint(x:contour[0].x,y:contour[0].y));for point in contour.dropFirst() { path.addLine(to:CGPoint(x:point.x,y:point.y)) };path.closeSubpath() }
        return path
    }
    func testPencilContoursPreserveDotsHolesAndUniteOverlappingStrokes() throws {
        let i=try PencilGlyphExtractor.outline(drawing:sample("i"),metrics:metrics);XCTAssertEqual(i.contours.count,2)
        let j=try PencilGlyphExtractor.outline(drawing:sample("j"),metrics:metrics);XCTAssertEqual(j.contours.count,2)
        let o=try PencilGlyphExtractor.outline(drawing:sample("o"),metrics:metrics);XCTAssertEqual(o.contours.count,2)
        // x is shifted from drawing minX to the explicit 50-unit left bearing.
        XCTAssertFalse(path(o).contains(CGPoint(x:250,y:250),using:.winding));XCTAssertTrue(path(o).contains(CGPoint(x:70,y:250),using:.winding))
        let umlaut=try PencilGlyphExtractor.outline(drawing:sample("ö"),metrics:metrics);XCTAssertEqual(umlaut.contours.count,4)
        for character: Character in ["B","8"] { let shape=try PencilGlyphExtractor.outline(drawing:sample(character),metrics:metrics);XCTAssertEqual(shape.contours.count,3) }
        let sharp=try PencilGlyphExtractor.outline(drawing:sample("ß"),metrics:metrics);XCTAssertFalse(sharp.contours.isEmpty)
        let crossing=PKDrawing(strokes:[stroke([CGPoint(x:10,y:50),CGPoint(x:50,y:50)]),stroke([CGPoint(x:30,y:30),CGPoint(x:30,y:70)])])
        XCTAssertEqual(try PencilGlyphExtractor.outline(drawing:crossing,metrics:metrics).contours.count,1)
    }
    func testInvalidGlyphDiagnosticsAreSpecificAndKeepDraftSources() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),assets=try AssetStore(root:root)
        let source=sample("i").strokes[0],drawing=PKDrawing(strokes:[PKStroke(ink:PKInk(.marker,color:.black),path:source.path)])
        let asset=try await assets.stage(data:drawing.dataRepresentation()),hash=try await assets.finalize(asset)
        var project=FontProject(name:"Unsupported ink",glyphAssetHashes:[65:hash],glyphMetrics:[65:metrics])
        let service=PersonalFontService(assets:assets),issues=try await service.validate(project:project)
        XCTAssertEqual(issues.first { $0.codePoint == 65 }?.reason,"unsupportedInk")
        var bad=metrics;bad.emSize=0;project.glyphMetrics[65]=bad
        let invalid=try await service.validate(project:project)
        XCTAssertEqual(invalid.first { $0.codePoint == 65 }?.reason,"invalidMetrics")
        let retained=try await assets.read(hash:hash);XCTAssertEqual(retained,drawing.dataRepresentation())
    }
    func testMaskIsAppliedBeforeTransformAndAnisotropicNibIsPreserved() throws {
        let source=stroke([CGPoint(x:10,y:50),CGPoint(x:50,y:50)])
        let clipped=PKStroke(ink:source.ink,path:source.path,transform:CGAffineTransform(translationX:20,y:10),mask:UIBezierPath(rect:CGRect(x:8,y:47,width:22,height:6)))
        let outline=try PencilGlyphExtractor.outline(drawing:PKDrawing(strokes:[clipped]),metrics:metrics)
        let bounds=path(outline).boundingBoxOfPath
        XCTAssertEqual(bounds.minX,50,accuracy:1);XCTAssertEqual(bounds.width,220,accuracy:1);XCTAssertEqual(bounds.minY,180,accuracy:1);XCTAssertEqual(bounds.height,40,accuracy:1)
        let nib=PKDrawing(strokes:[stroke([CGPoint(x:20,y:20),CGPoint(x:20,y:60)],width:4,height:10)])
        let nibBounds=path(try PencilGlyphExtractor.outline(drawing:nib,metrics:metrics)).boundingBoxOfPath
        XCTAssertEqual(nibBounds.width,40,accuracy:1);XCTAssertEqual(nibBounds.height,500,accuracy:1)
    }
    func testMissingInvalidAndCancelledBuildPreserveDraft() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assets=try AssetStore(root:root.appendingPathComponent("assets")),service=PersonalFontService(assets:assets),store=try await NotebookStore.open(root:root.appendingPathComponent("library"))
        let project=FontProject(name:"Draft");try await store.saveFontProject(project)
        let issues=try await service.validate(project:project);XCTAssertEqual(issues.count,102);XCTAssertFalse(issues.contains { $0.codePoint == 32 })
        do { _=try await service.build(project:project);XCTFail("incomplete build accepted") } catch {}
        let task=Task { withUnsafeCurrentTask { $0?.cancel() };return try await service.build(project:project) }
        do { _=try await task.value;XCTFail("cancelled build accepted") } catch { XCTAssertTrue(error is CancellationError) }
        let after=await store.fontProjects();XCTAssertEqual(after,[project]);XCTAssertTrue(after[0].versions.isEmpty)
        XCTAssertThrowsError(try PencilGlyphExtractor.outline(drawing:PKDrawing(),metrics:metrics))
    }
}

extension FontServiceTests {
    func makeProject(assets: AssetStore) async throws -> FontProject {
        var project=FontProject(name:"Topology fixture")
        // Coverage scaffolding only: representative characters below have distinct handwriting fixtures.
        // This repeated A is not evidence of an aesthetically complete handwritten alphabet.
        for code in FontCoverage.required where code != 32 {
            let drawing=sample(Character(String(Unicode.Scalar(code)!)))
            let staged=try await assets.stage(data:drawing.dataRepresentation()),hash=try await assets.finalize(staged)
            project.glyphAssetHashes[code]=hash;project.glyphMetrics[code]=metrics
        }
        return project
    }
    func registrationFixture(assets: AssetStore, id: UUID = UUID(), advance: Int = 600) async throws -> FontVersion {
        let name="MeetingBook-"+id.uuidString.replacingOccurrences(of:"-",with:"")
        let outline=GlyphOutline(contours:[[.init(50,0),.init(50,700),.init(550,700),.init(550,0)]],advanceWidth:advance)
        var glyphs=Dictionary(uniqueKeysWithValues:FontCoverage.required.map { ($0,outline) })
        glyphs[32]=GlyphOutline(contours:[],advanceWidth:300)
        let data=try TrueTypeWriter.build(glyphs:glyphs,postScriptName:name)
        let staged=try await assets.stage(data:data),hash=try await assets.finalize(staged)
        return FontVersion(id:id,assetHash:hash,postScriptName:name,metrics:FontMetrics())
    }
    func testConcurrentRegistrationOfSameImmutableFontIsIdempotent() async throws {
        let assets=try AssetStore(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let first=PersonalFontService(assets:assets),second=PersonalFontService(assets:assets)
        for useTwoServices in [false,true] {
            let version=try await registrationFixture(assets:assets)
            let successes=await withTaskGroup(of:Bool.self) { group in
                for index in 0..<32 {
                    let service=useTwoServices && index.isMultiple(of:2) ? second : first
                    group.addTask { do { try await service.register(version:version);return true } catch { return false } }
                }
                var count=0;for await success in group { if success { count += 1 } };return count
            }
            XCTAssertEqual(successes,32,"All concurrent reopens must use the same verified font")
            XCTAssertEqual(HandwritingFontCatalog.font(catalogID:nil,personalVersion:version,size:30).fontName,version.postScriptName)
        }
    }
    func testRegistrationRejectsDifferentFontWithSameNameAndInvalidBytes() async throws {
        let assets=try AssetStore(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),service=PersonalFontService(assets:assets)
        let original=try await registrationFixture(assets:assets);try await service.register(version:original)
        let collision=try await registrationFixture(assets:assets,id:original.id,advance:900)
        XCTAssertNotEqual(collision.assetHash,original.assetHash)
        do { try await service.register(version:collision);XCTFail("Different font accepted solely because its name matched") }
        catch { XCTAssertEqual(error as? FontBuildError,.registration) }
        let staged=try await assets.stage(data:Data("not a font".utf8)),badHash=try await assets.finalize(staged)
        let invalid=FontVersion(id:original.id,assetHash:badHash,postScriptName:original.postScriptName)
        do { try await service.register(version:invalid);XCTFail("Invalid bytes accepted for an existing name") }
        catch { XCTAssertEqual(error as? FontBuildError,.invalidFont) }
        try await service.register(version:original)
        let font=CTFontCreateWithName(original.postScriptName as CFString,1000,nil)
        var character=UniChar(65),glyph=CGGlyph(0),advance=CGSize.zero
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font,&character,&glyph,1));CTFontGetAdvancesForGlyphs(font,.horizontal,&glyph,&advance,1)
        XCTAssertEqual(advance.width,600)
    }
    func testBuildVersionsAreRealImmutableFontsAndSourcesRemainEditable() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assets=try AssetStore(root:root.appendingPathComponent("assets")),service=PersonalFontService(assets:assets)
        let original=try await makeProject(assets:assets)
        let first=try await service.build(project:original),second=try await service.build(project:original)
        XCTAssertNotEqual(first.version.id,second.version.id);XCTAssertNotEqual(first.version.postScriptName,second.version.postScriptName);XCTAssertNotEqual(first.version.assetHash,second.version.assetHash)
        XCTAssertTrue(original.versions.isEmpty)
        let firstHash=try await assets.finalize(first.asset);XCTAssertEqual(firstHash,first.version.assetHash)
        let before=try await assets.read(hash:firstHash);try await service.register(version:first.version)
        let stableURL=try await assets.verifiedURL(hash:firstHash);XCTAssertEqual(try Data(contentsOf:stableURL),before)
        let fontAttachment=XCTAttachment(data:before,uniformTypeIdentifier:"public.truetype-ttf-font");fontAttachment.name="generated-personal-font";fontAttachment.lifetime = .keepAlways;add(fontAttachment)
        _=try await assets.finalize(second.asset)
        let after=try await assets.read(hash:firstHash);XCTAssertEqual(before,after)
        let drawingData=try await assets.read(hash:try XCTUnwrap(original.glyphAssetHashes[105]));XCTAssertEqual(try PKDrawing(data:drawingData).strokes.count,2)
        let font=HandwritingFontCatalog.font(catalogID:nil,personalVersion:first.version,size:30)
        XCTAssertEqual(font.fontName,first.version.postScriptName)
        for size: CGFloat in [24,30,36] { try verifyTextAndPDF(font:HandwritingFontCatalog.font(catalogID:nil,personalVersion:first.version,size:size),label:"personal-\(size)") }
        let store=try await NotebookStore.open(root:root)
        var published=original;published.versions=[first.version];try await store.saveFontProject(published)
        var changed=published;changed.versions=[FontVersion(id:first.version.id,assetHash:second.version.assetHash,postScriptName:second.version.postScriptName)]
        do { try await store.saveFontProject(changed);XCTFail("immutable version replaced") } catch { XCTAssertEqual(error as? NotebookError,.invalidModel) }
        let reopened=try await NotebookStore.open(root:root);let saved=await reopened.fontProjects();XCTAssertEqual(saved,[published])
        let task=Task { try await service.build(project:original) }
        try await Task.sleep(for:.milliseconds(5));task.cancel()
        do { _=try await task.value;XCTFail("cancelled work returned a version") } catch { XCTAssertTrue(error is CancellationError) }
        let files=try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("assets/staging").path);XCTAssertTrue(files.isEmpty)
        let unchanged=await store.fontProjects();XCTAssertEqual(unchanged,[published])
    }
    func testBundledLargeGlyphEnvelopesFitRuling() {
        let gochi=HandwritingFontCatalog.font(catalogID:"bundled.gochi-hand",size:36)
        XCTAssertEqual(HandwritingFontCatalog.mandatoryGlyphBounds(for:gochi).height,36.650390625,accuracy:0.001)
        let caveat=HandwritingFontCatalog.font(catalogID:"bundled.caveat",size:36)
        XCTAssertEqual(HandwritingFontCatalog.mandatoryGlyphBounds(for:caveat).height,38.556,accuracy:0.001)
        XCTAssertTrue(HandwritingFontCatalog.fitsRuling(font:caveat,spacing:40))
        XCTAssertFalse(HandwritingFontCatalog.fitsRuling(font:caveat,spacing:30))
        XCTAssertFalse(HandwritingFontCatalog.fitsRuling(font:caveat,spacing:.nan))
    }
    func testBundledFontsLicensesCoverageAndActualBaselineGeometry() throws {
        for entry in HandwritingFontCatalog.entries {
            let license=try HandwritingFontCatalog.licenseText(for:entry);XCTAssertTrue(license.contains("SIL OPEN FONT LICENSE"))
            for size: CGFloat in [24,30,36] {
                let font=HandwritingFontCatalog.font(catalogID:entry.id,size:size);XCTAssertEqual(font.fontName,entry.postScriptName);XCTAssertLessThanOrEqual(HandwritingFontCatalog.mandatoryGlyphBounds(for:font).height,40)
                var chars=FontCoverage.required.map(UInt16.init),glyphs=Array(repeating:CGGlyph(0),count:103)
                XCTAssertTrue(CTFontGetGlyphsForCharacters(font as CTFont,&chars,&glyphs,103));XCTAssertFalse(glyphs.contains(0))
                let table=try XCTUnwrap(CTFontCopyTable(font as CTFont,CTFontTableTag(kCTFontTableOS2),[]) as Data?)
                XCTAssertEqual(table[8],0);XCTAssertEqual(table[9],0) // fsType: installable, unrestricted embedding.
                try verifyTextAndPDF(font:font,label:entry.id+"-\(size)")
            }
        }
        XCTAssertEqual(HandwritingFontCatalog.font(catalogID:"unknown",size:30).fontName,UIFont.systemFont(ofSize:30).fontName)
    }
    func verifyTextAndPDF(font: UIFont,label: String) throws {
        let text="ij ÄÖÜ äöü ß oB8 € e\u{301} 漢字 👩🏽‍💻\n"+String(repeating:"oB8 äöü ß ",count:12)
        let storage=NSTextStorage(string:text,attributes:[.font:font,.foregroundColor:UIColor.black])
        let layout=NSLayoutManager(),container=NSTextContainer(size:CGSize(width:260,height:2000)),ruling=RuledFontLayout()
        layout.delegate=ruling;layout.addTextContainer(container);storage.addLayoutManager(layout);container.lineFragmentPadding=0
        let view=UITextView(frame:CGRect(x:0,y:0,width:260,height:1000),textContainer:container);view.textContainerInset = .zero;view.backgroundColor = .clear
        view.layoutIfNeeded()
        layout.ensureLayout(for:container)
        XCTAssertEqual(view.text,text)
        view.selectedRange=NSRange(location:0,length:(text as NSString).length)
        let old=UIPasteboard.general.items;defer { UIPasteboard.general.items=old }
        view.copy(nil);XCTAssertEqual(UIPasteboard.general.string,text)
        var baselines=[CGFloat]()
        layout.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:layout.numberOfGlyphs)) { rect,_,_,range,_ in
            baselines.append(rect.minY+layout.location(forGlyphAt:range.location).y)
        }
        XCTAssertGreaterThan(baselines.count,3)
        for (index,y) in baselines.enumerated() { XCTAssertEqual(y,40+CGFloat(index)*40,accuracy:0.5,"\(label) line \(index)") }
        let pdf=UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:300,height:1200)).pdfData { context in
            context.beginPage();layout.drawGlyphs(forGlyphRange:NSRange(location:0,length:layout.numberOfGlyphs),at:.zero)
        }
        let document=try XCTUnwrap(PDFDocument(data:pdf)),extracted=try XCTUnwrap(document.string)
        XCTAssertTrue(extracted.components(separatedBy:.whitespacesAndNewlines).joined().contains("ijÄÖÜäöüßoB8€"),"PDF Unicode: \(extracted)")
        let attachment=XCTAttachment(data:pdf,uniformTypeIdentifier:"com.adobe.pdf");attachment.name=label;attachment.lifetime = .keepAlways;add(attachment)
        let image=UIGraphicsImageRenderer(size:CGSize(width:300,height:500)).image { context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:300,height:500));UIColor.lightGray.setStroke()
            for y in stride(from:40,through:480,by:40) { context.cgContext.move(to:CGPoint(x:0,y:y));context.cgContext.addLine(to:CGPoint(x:300,y:y)) };context.cgContext.strokePath()
            view.layer.render(in:context.cgContext)
        }
        let visual=XCTAttachment(image:image);visual.name=label;visual.lifetime = .keepAlways;add(visual)
    }
}

extension FontServiceTests {
    func maskedDrawing(_ rectangles: [CGRect]) -> PKDrawing {
        let mask=UIBezierPath()
        for rectangle in rectangles { mask.append(UIBezierPath(rect:rectangle)) }
        let pen=stroke([CGPoint(x:50,y:40),CGPoint(x:50.01,y:40)],width:300)
        return PKDrawing(strokes:[PKStroke(ink:pen.ink,path:pen.path,mask:mask)])
    }
    func testCollapsedMaskedContourPreservesBodyAndOneUnitDot() throws {
        let drawing=maskedDrawing([CGRect(x:20,y:40,width:20,height:30),CGRect(x:45.01,y:50,width:0.01,height:0.1),CGRect(x:48,y:50,width:0.1,height:0.1)])
        let outline=try PencilGlyphExtractor.outline(drawing:PKDrawing(data:drawing.dataRepresentation()),metrics:metrics)
        XCTAssertEqual(outline.contours.count,2)
        XCTAssertTrue(path(outline).contains(CGPoint(x:330.5,y:299.5),using:.winding),"A representable one-square-unit dot must remain filled")
    }
    func testCollapsedMaskCannotHideOutOfBoundsInkOrBecomeEmptyGlyph() throws {
        let body=CGRect(x:20,y:40,width:20,height:30)
        let outside=CGRect(x:45.01,y:-5.1,width:0.01,height:0.1)
        XCTAssertThrowsError(try PencilGlyphExtractor.outline(drawing:maskedDrawing([body,outside]),metrics:metrics))
        XCTAssertThrowsError(try PencilGlyphExtractor.outline(drawing:maskedDrawing([CGRect(x:45.01,y:50,width:0.01,height:0.1)]),metrics:metrics))
    }
    func testLicensedGlyphMasksSurviveNativeExtraction() throws {
        func areas(_ path: CGPath) -> [Double] {
            var points=[CGPoint](),result=[Double]()
            path.flattened(threshold:0.5).applyWithBlock { item in
                switch item.pointee.type {
                case .moveToPoint: points=[item.pointee.points[0]]
                case .addLineToPoint: points.append(item.pointee.points[0])
                case .closeSubpath:
                    if let first=points.first {result.append(zip(points,points.dropFirst()+[first]).reduce(0) {$0+Double($1.0.x*$1.1.y-$1.1.x*$1.0.y)}/2)}
                    points=[]
                default: break
                }
            }
            return result
        }
        let font=HandwritingFontCatalog.font(catalogID:"bundled.caveat",size:200) as CTFont
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String,"Caveat-Regular")
        let captures=try LicensedFontCaptureFixture.captures();XCTAssertEqual(captures.count,102)
        for sample in captures {
            let code=sample.codePoint,source=sample.source,drawing=sample.drawing,capture=sample.metrics
            let mask=try XCTUnwrap(drawing.strokes.first?.mask?.cgPath)
            let outline: GlyphOutline
            do {outline=try PencilGlyphExtractor.outline(drawing:PKDrawing(data:drawing.dataRepresentation()),metrics:capture)}
            catch {
                print("MASK_ERROR code=\(code) error=\(error) sourceAreasCaptureUnits=\(areas(source.normalized(using:.winding))) maskAreasCaptureUnits=\(areas(mask.normalized(using:.winding)))")
                XCTFail("glyph \(code) native extraction: \(error)");continue
            }
            let native=path(outline)
            // Three source glyph bearings exceed capture's0.2em limit. Normalize their
            // horizontal placement to195/1000; shape and advance remain source-derived.
            var fitting=CGAffineTransform(a:5,b:0,c:0,d:5,tx:(capture.leftBearing-source.boundingBoxOfPath.minX)*5,ty:0)
            let expected=try XCTUnwrap(source.copy(using:&fitting)).normalized(using:.winding)
            let expectedBounds=expected.boundingBoxOfPath,actual=native.boundingBoxOfPath
            XCTAssertEqual(actual.minX,expectedBounds.minX,accuracy:2,"glyph \(code)")
            XCTAssertEqual(actual.minY,expectedBounds.minY,accuracy:2,"glyph \(code)")
            XCTAssertEqual(actual.maxX,expectedBounds.maxX,accuracy:2,"glyph \(code)")
            XCTAssertEqual(actual.maxY,expectedBounds.maxY,accuracy:2,"glyph \(code)")
            // CoreGraphics normalization can emit zero-area numerical slivers. A
            // TrueType integer contour needs at least half a square font unit.
            let contours=areas(expected).filter { abs($0) >= 0.5 }.count
            if outline.contours.count != contours {print("MASK_TOPOLOGY code=\(code) expected1000Areas=\(areas(expected)) nativeAreas=\(areas(native)) sourceCaptureAreas=\(areas(source.normalized(using:.winding)))")}
            XCTAssertEqual(outline.contours.count,contours,"glyph \(code) counter/dot topology")
            // Native path normalization/flattening and integer TrueType points move
            // edges slightly. Require exact winding occupancy outside a2font-unit edge corridor.
            let edge=expected.copy(strokingWithWidth:4,lineCap:.round,lineJoin:.round,miterLimit:1)
            var interiorChecks=0
            for x in stride(from:expectedBounds.minX,to:expectedBounds.maxX,by:10) {for y in stride(from:expectedBounds.minY,to:expectedBounds.maxY,by:10) {
                let point=CGPoint(x:x,y:y)
                if !edge.contains(point,using:.winding) {
                    interiorChecks += 1
                    XCTAssertEqual(native.contains(point,using:.winding),expected.contains(point,using:.winding),"glyph \(code) interior silhouette")
                }
            }}
            XCTAssertGreaterThan(interiorChecks,0,"glyph \(code)")
        }
    }
    func testLicensedSyntheticProjectBuildsPublishesAndRegistersReadableFont() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root),assets=await store.assets
        let project=try await LicensedFontCaptureFixture.project(assets:assets)
        XCTAssertEqual(project.glyphAssetHashes.count,102);XCTAssertEqual(Set(project.glyphAssetHashes.values).count,102)
        try await store.saveFontProject(project)
        let service=PersonalFontService(assets:assets),issues=try await service.validate(project:project)
        XCTAssertTrue(issues.isEmpty,"\(issues)")
        let result=try await service.build(project:project)
        let finalized=try await assets.finalize(result.asset);XCTAssertEqual(finalized,result.version.assetHash)
        try await service.register(version:result.version)
        let published=try await store.publishFontVersion(projectID:project.id,version:result.version)
        XCTAssertEqual(published.versions,[result.version])
        let reopened=try await NotebookStore.open(root:root),versions=try await reopened.fontVersions()
        XCTAssertEqual(versions,[result.version])
        let provenance=try LicensedFontCaptureFixture.provenance(project:published)
        let metadata=try XCTUnwrap(JSONSerialization.jsonObject(with:provenance) as? [String:Any])
        XCTAssertEqual(metadata["synthetic"] as? Bool,true)
        XCTAssertEqual((metadata["sourceFontSHA256"] as? String)?.count,64)
        XCTAssertTrue((metadata["license"] as? String)?.contains("SIL OPEN FONT LICENSE") == true)
        let sidecar=XCTAttachment(data:provenance,uniformTypeIdentifier:"public.json");sidecar.name="licensed-synthetic-personal-font-provenance";sidecar.lifetime = .keepAlways;add(sidecar)
        let fontData=try await assets.read(hash:result.version.assetHash)
        let file=XCTAttachment(data:fontData,uniformTypeIdentifier:"public.truetype-ttf-font");file.name="licensed-synthetic-personal-font";file.lifetime = .keepAlways;add(file)
        for size: CGFloat in [24,30,36] {
            let font=HandwritingFontCatalog.font(catalogID:nil,personalVersion:result.version,size:size)
            XCTAssertEqual(font.fontName,result.version.postScriptName)
            try verifyTextAndPDF(font:font,label:"licensed-synthetic-personal-\(size)")
        }
    }
}
