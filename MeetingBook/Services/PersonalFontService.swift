import Foundation
import PencilKit
import CoreText
import MeetingBookCore

struct PersonalFontBuild: Sendable { let version: FontVersion; let asset: StagedAsset }
struct GlyphIssue: Sendable, Equatable { let codePoint: UInt32; let reason: String }

/// Builds a private staged asset; the caller explicitly finalizes it and saves the project.
actor PersonalFontService {
    let assets: AssetStore
    init(assets: AssetStore) { self.assets=assets }
    func validate(project: FontProject) async throws -> [GlyphIssue] { try await extract(project:project).issues }
    func build(project: FontProject) async throws -> PersonalFontBuild {
        let input=try await extract(project:project)
        guard input.issues.isEmpty else { throw FontBuildError.invalidGlyphs(input.issues.map(\.codePoint)) }
        let id=UUID(),name="MeetingBook-"+id.uuidString.replacingOccurrences(of:"-",with:"")
        let data=try TrueTypeWriter.build(glyphs:input.outlines,postScriptName:name)
        try FontValidation.validateGenerated(data)
        _ = try Self.verifiedFont(data:data,name:name)
        try Task.checkCancellation()
        let asset=try await assets.stage(data:data)
        try Task.checkCancellation()
        return PersonalFontBuild(version:FontVersion(id:id,assetHash:asset.hash,postScriptName:name,metrics:FontMetrics()),asset:asset)
    }
    /// Reopen a previously finalized immutable version before asking UIKit for its UIFont.
    func register(version: FontVersion) async throws {
        let lease=assets.protection.retain(hashes:[version.assetHash]);defer {withExtendedLifetime(lease){}}
        let data=try await assets.read(hash:version.assetHash)
        let candidate=try Self.validatedCandidate(version:version,data:data)
        let url=try await assets.verifiedURL(hash:version.assetHash)
        try Task.checkCancellation()
        // No suspension between this presence check and registration; other service actors may still race.
        if Self.matchesRegisteredFont(candidate,name:version.postScriptName) { assets.protection.register(version.assetHash);return }
        var registrationError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL,.process,&registrationError) { assets.protection.register(version.assetHash);return }
        guard let error=registrationError?.takeRetainedValue(),
              CFErrorGetDomain(error) as String == kCTFontManagerErrorDomain as String,
              CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue,
              Self.matchesRegisteredFont(candidate,name:version.postScriptName) else { throw FontBuildError.registration }
        assets.protection.register(version.assetHash)
    }
    /// Import preview validates bytes and existing process identity without registering temporary files.
    static func validateForImport(version: FontVersion,data: Data) throws {
        let candidate=try validatedCandidate(version:version,data:data)
        let existing=CTFontCreateWithName(version.postScriptName as CFString,30,nil)
        if CTFontCopyPostScriptName(existing) as String == version.postScriptName {
            guard matchesRegisteredFont(candidate,name:version.postScriptName) else { throw FontBuildError.registration }
        }
    }
    private static func validatedCandidate(version: FontVersion,data: Data) throws -> CGFont {
        guard version.postScriptName == "MeetingBook-"+version.id.uuidString.replacingOccurrences(of:"-",with:"") else { throw FontBuildError.invalidFont }
        try version.metrics?.validate();try FontValidation.validateGenerated(data)
        return try verifiedFont(data:data,name:version.postScriptName)
    }
    private static func matchesRegisteredFont(_ candidate: CGFont, name: String) -> Bool {
        let existing=CTFontCreateWithName(name as CFString,30,nil)
        guard CTFontCopyPostScriptName(existing) as String == name else { return false }
        let expected=CTFontCreateWithGraphicsFont(candidate,30,nil,nil)
        let tables=[kCTFontTableOS2,kCTFontTableCmap,kCTFontTableGlyf,kCTFontTableHead,kCTFontTableHhea,kCTFontTableHmtx,kCTFontTableLoca,kCTFontTableMaxp,kCTFontTableName,kCTFontTablePost]
        return tables.allSatisfy { tag in
            guard let actual=CTFontCopyTable(existing,CTFontTableTag(tag),[]),let wanted=CTFontCopyTable(expected,CTFontTableTag(tag),[]) else { return false }
            return actual as Data == wanted as Data
        }
    }
    private func extract(project: FontProject) async throws -> (outlines:[UInt32:GlyphOutline],issues:[GlyphIssue]) {
        let lease=assets.protection.retain(hashes:Set(project.glyphAssetHashes.values));defer {withExtendedLifetime(lease){}}
        try Task.checkCancellation()
        guard (2...3).contains(project.formatVersion),project.glyphAssetHashes.count <= 4096 else { throw FontBuildError.invalidFont }
        var outlines: [UInt32:GlyphOutline]=[32:GlyphOutline(contours:[],advanceWidth:300)],issues=[GlyphIssue]()
        for code in FontCoverage.required where code != 32 {
            try Task.checkCancellation()
            guard let hash=project.glyphAssetHashes[code] else { issues.append(.init(codePoint:code,reason:"missingDrawing"));continue }
            guard let metrics=project.glyphMetrics[code] else { issues.append(.init(codePoint:code,reason:"missingMetrics"));continue }
            do {
                let data=try await assets.read(hash:hash)
                guard data.count <= 2_000_000 else { throw FontBuildError.tooComplex }
                outlines[code]=try PencilGlyphExtractor.outline(drawing:PKDrawing(data:data),metrics:metrics)
            } catch is CancellationError { throw CancellationError() }
            catch let error as FontBuildError { issues.append(.init(codePoint:code,reason:String(describing:error))) }
            catch { issues.append(.init(codePoint:code,reason:"invalidDrawing")) }
        }
        return (outlines,issues)
    }
    private static func verifiedFont(data: Data,name: String) throws -> CGFont {
        guard let provider=CGDataProvider(data:data as CFData),let cg=CGFont(provider) else { throw FontBuildError.invalidFont }
        let font=CTFontCreateWithGraphicsFont(cg,30,nil,nil)
        guard CTFontCopyPostScriptName(font) as String == name else { throw FontBuildError.invalidFont }
        var characters=FontCoverage.required.map(UInt16.init),glyphs=Array(repeating:CGGlyph(0),count:FontCoverage.required.count)
        guard CTFontGetGlyphsForCharacters(font,&characters,&glyphs,glyphs.count),glyphs.allSatisfy({ $0 != 0 }) else { throw FontBuildError.invalidFont }
        for glyph in glyphs.dropFirst() {
            guard let path=CTFontCreatePathForGlyph(font,glyph,nil),!path.isEmpty else { throw FontBuildError.invalidFont }
        }
        guard let bitmap=CGContext(data:nil,width:640,height:80,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FontBuildError.invalidFont }
        bitmap.textPosition=CGPoint(x:4,y:30)
        let sample=NSAttributedString(string:"ij ÄÖÜ äöü ß oB8 €",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font])
        CTLineDraw(CTLineCreateWithAttributedString(sample),bitmap)
        guard bitmap.makeImage() != nil else { throw FontBuildError.invalidFont }
        return cg
    }
}

enum PencilGlyphExtractor {
    static func outline(drawing: PKDrawing, metrics: GlyphCaptureMetrics) throws -> GlyphOutline {
        try Task.checkCancellation();try metrics.validate()
        guard !drawing.strokes.isEmpty,drawing.strokes.count <= 128 else { throw FontBuildError.invalidDrawing }
        let scale=1000/metrics.emSize,combined=CGMutablePath();var samples=0
        for stroke in drawing.strokes {
            try Task.checkCancellation()
            // Font capture uses a solid pen; textured/translucent ink has no faithful monochrome outline.
            guard stroke.ink.inkType == .pen else { throw FontBuildError.unsupportedInk }
            guard stroke.path.count <= 8192,!stroke.path.isEmpty,stroke.path.allSatisfy({ point in
                [point.location.x,point.location.y,point.size.width,point.size.height,point.azimuth,point.timeOffset].allSatisfy { $0.isFinite && abs($0) <= 10000 } && point.size.width > 0 && point.size.height > 0
            }) else { throw FontBuildError.invalidDrawing }
            let transform=stroke.transform
            guard [transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty].allSatisfy({ $0.isFinite && abs($0) <= 10000 }),abs(transform.a*transform.d-transform.b*transform.c) > 0.0001 else { throw FontBuildError.invalidDrawing }
            let minWidth=stroke.path.map { min($0.size.width,$0.size.height) }.min() ?? 0
            guard minWidth.isFinite,minWidth*scale >= 1 else { throw FontBuildError.invalidDrawing }
            let distance=min(2/scale,minWidth/3),footprints=CGMutablePath()
            for point in stroke.path.interpolatedPoints(by:.distance(distance)) {
                samples += 1
                guard samples <= 16000 else { throw FontBuildError.tooComplex }
                if samples % 128 == 0 { try Task.checkCancellation() }
                let values=[point.location.x,point.location.y,point.size.width,point.size.height,point.azimuth,point.opacity]
                guard values.allSatisfy({ $0.isFinite && abs($0) <= 10000 }),point.size.width > 0,point.size.height > 0,point.opacity > 0 else { throw FontBuildError.invalidDrawing }
                var placement=CGAffineTransform(rotationAngle:point.azimuth)
                placement.tx=point.location.x;placement.ty=point.location.y
                footprints.addEllipse(in:CGRect(x:-point.size.width/2,y:-point.size.height/2,width:point.size.width,height:point.size.height),transform:placement)
            }
            var path=footprints.normalized(using:.winding)
            if let mask=stroke.mask { path=path.intersection(mask.cgPath,using:.winding) }
            var placement=transform
            guard let transformed=path.copy(using:&placement) else { throw FontBuildError.invalidDrawing }
            combined.addPath(transformed.normalized(using:.winding))
        }
        let union=combined.normalized(using:.winding)
        guard !union.isEmpty else { throw FontBuildError.invalidDrawing }
        // Keep the shared baseline; only the horizontal origin is fitted to the measured bearing.
        var coordinates=CGAffineTransform(a:scale,b:0,c:0,d:-scale,tx:metrics.leftBearing*scale-union.boundingBoxOfPath.minX*scale,ty:metrics.baselineY*scale)
        guard let normalized=union.copy(using:&coordinates) else { throw FontBuildError.invalidDrawing }
        let flattened=normalized.flattened(threshold:0.5)
        var contours=[[GlyphOutline.Point]](),current=[GlyphOutline.Point](),invalid=false,outOfBounds=false,total=0
        flattened.applyWithBlock { pointer in
            let element=pointer.pointee
            switch element.type {
            case .moveToPoint: if !current.isEmpty { invalid=true };current=[];fallthrough
            case .addLineToPoint:
                let p=element.points[0]
                guard p.x.isFinite,p.y.isFinite,abs(p.x) < 10000,abs(p.y) < 10000 else { invalid=true;return }
                let point=GlyphOutline.Point(Int(p.x.rounded()),Int(p.y.rounded()))
                if !(-200...2200).contains(point.x) || !(-250...850).contains(point.y) { outOfBounds=true }
                if current.last != point { current.append(point);total += 1 }
            case .closeSubpath:
                if current.first == current.last { current.removeLast() }
                // Integer quantization can collapse normalized slivers to a point or line.
                if current.count >= 3 { contours.append(current) };current=[]
            default: invalid=true
            }
        }
        guard !outOfBounds else { throw FontBuildError.invalidOutline }
        guard !invalid,current.isEmpty,!contours.isEmpty else { throw FontBuildError.invalidDrawing }
        guard total <= 8192,contours.count <= 128 else { throw FontBuildError.tooComplex }
        let outline=GlyphOutline(contours:contours,advanceWidth:Int((metrics.advanceWidth*scale).rounded()))
        // Reuse the writer's bounds/area validation, without generating a whole font here.
        try outline.validateForFont()
        return outline
    }
}

#if DEBUG
/// Licensed synthetic capture data for isolated QA, never a person's handwriting.
@MainActor enum LicensedFontCaptureFixture {
    struct Capture {
        let codePoint: UInt32
        let source: CGPath
        let drawing: PKDrawing
        let metrics: GlyphCaptureMetrics
    }
    static func captures() throws -> [Capture] {
        let font=HandwritingFontCatalog.font(catalogID:"bundled.caveat",size:200) as CTFont
        guard CTFontCopyPostScriptName(font) as String == "Caveat-Regular" else { throw FontBuildError.invalidFont }
        return try FontCoverage.required.filter { $0 != 32 }.map { code in
            var character=UInt16(code),glyph=CGGlyph(0),advance=CGSize.zero
            guard CTFontGetGlyphsForCharacters(font,&character,&glyph,1),glyph != 0,
                  let source=CTFontCreatePathForGlyph(font,glyph,nil) else { throw FontBuildError.invalidFont }
            CTFontGetAdvancesForGlyphs(font,.horizontal,&glyph,&advance,1)
            var transform=CGAffineTransform(a:1,b:0,c:0,d:-1,tx:40,ty:240)
            guard let mask=source.copy(using:&transform) else { throw FontBuildError.invalidDrawing }
            let bounds=mask.boundingBoxOfPath,diameter=hypot(bounds.width,bounds.height)+4
            let points=[CGPoint(x:bounds.midX,y:bounds.midY),CGPoint(x:bounds.midX+0.01,y:bounds.midY)]
            let path=PKStrokePath(controlPoints:points.enumerated().map { index,point in
                PKStrokePoint(location:point,timeOffset:Double(index)*0.05,size:CGSize(width:diameter,height:diameter),opacity:1,force:1,azimuth:0,altitude:.pi/2)
            },creationDate:Date(timeIntervalSince1970:0))
            let drawing=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:path,mask:UIBezierPath(cgPath:mask))])
            // Three source bearings exceed capture's 0.2em limit; retain their shapes and advances.
            let metrics=GlyphCaptureMetrics(baselineY:240,emSize:200,xHeight:CTFontGetXHeight(font),capHeight:CTFontGetCapHeight(font),advanceWidth:advance.width,leftBearing:min(39,source.boundingBoxOfPath.minX))
            return Capture(codePoint:code,source:source,drawing:drawing,metrics:metrics)
        }
    }
    static func project(assets: AssetStore) async throws -> FontProject {
        var project=FontProject(name:"QA synthetic · Caveat-derived")
        for capture in try captures() {
            let staged=try await assets.stage(data:capture.drawing.dataRepresentation()),hash=try await assets.finalize(staged)
            project.glyphAssetHashes[capture.codePoint]=hash;project.glyphMetrics[capture.codePoint]=capture.metrics
        }
        return project
    }
    /// Keep this sidecar beside QA artifacts and any derived test font, including the full OFL.
    static func provenance(project: FontProject) throws -> Data {
        struct Provenance: Encodable {
            let synthetic: Bool
            let sourceFont: String
            let sourceFontSHA256: String
            let license: String
            let derivation: String
            let glyphMetrics: [UInt32:GlyphCaptureMetrics]
            let drawingAssetHashes: [UInt32:String]
            let versions: [FontVersion]
        }
        guard let entry=HandwritingFontCatalog.entries.first(where: { $0.id == "bundled.caveat" }),
              let url=Bundle.main.url(forResource:entry.file,withExtension:"ttf") else { throw FontBuildError.invalidFont }
        let provenance=Provenance(synthetic:true,sourceFont:entry.postScriptName,sourceFontSHA256:AssetStore.hash(try Data(contentsOf:url)),license:try HandwritingFontCatalog.licenseText(for:entry),derivation:"Native PKDrawing masks from licensed Caveat outlines at 200 capture units/em; baseline 240; source shapes and advances retained; three excessive left bearings capped at 39 capture units (195/1000 em). Not user handwriting.",glyphMetrics:project.glyphMetrics,drawingAssetHashes:project.glyphAssetHashes,versions:project.versions)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return try encoder.encode(provenance)
    }
}
#endif
