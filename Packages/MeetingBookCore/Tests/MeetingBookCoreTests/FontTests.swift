import Testing
import Foundation
import CoreText
@testable import MeetingBookCore

private let square=GlyphOutline(contours:[[.init(50,0),.init(50,700),.init(550,700),.init(550,0)]],advanceWidth:600)
private func glyphs() -> [UInt32:GlyphOutline] {
    var result=Dictionary(uniqueKeysWithValues: ((32...126).map(UInt32.init)+[196,214,220,228,246,252,223,8364]).map { ($0,square) })
    result[32]=GlyphOutline(contours:[],advanceWidth:300)
    return result
}
private func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    bytes[offset..<offset+4].reduce(0) { ($0 << 8) | UInt32($1) }
}
@Test func generatedFontHasValidTablesChecksumCoverageAndMetrics() throws {
    let data=try TrueTypeWriter.build(glyphs:glyphs(),postScriptName:"MeetingBook-Test")
    let bytes=Array(data);var sum: UInt32=0
    for offset in stride(from:0,to:bytes.count,by:4) { sum &+= word(bytes,offset) }
    #expect(sum == 0xB1B0AFBA)
    let provider=try #require(CGDataProvider(data:data as CFData));let cg=try #require(CGFont(provider))
    let font=CTFontCreateWithGraphicsFont(cg,1000,nil,nil)
    #expect(CTFontCopyPostScriptName(font) as String == "MeetingBook-Test")
    var chars=Array(" ijÄÖÜäöüß€".utf16),ids=Array(repeating:CGGlyph(0),count:11)
    #expect(CTFontGetGlyphsForCharacters(font,&chars,&ids,chars.count))
    #expect(ids.allSatisfy { $0 != 0 })
    var a=UniChar(65),id=CGGlyph(0);#expect(CTFontGetGlyphsForCharacters(font,&a,&id,1))
    let path=try #require(CTFontCreatePathForGlyph(font,id,nil))
    #expect(path.boundingBoxOfPath == CGRect(x:50,y:0,width:500,height:700))
    var advance=CGSize.zero;CTFontGetAdvancesForGlyphs(font,.horizontal,&id,&advance,1);#expect(advance.width == 600)
}
@Test func writerRejectsMissingEmptyDegenerateAndUnboundedOutlines() {
    var input=glyphs();input[65]=nil
    #expect(throws:FontBuildError.missingGlyphs([65])) { try TrueTypeWriter.build(glyphs:input,postScriptName:"Test") }
    for outline in [GlyphOutline(contours:[],advanceWidth:600), GlyphOutline(contours:[[.init(0,0),.init(1,1),.init(2,2)]],advanceWidth:600),GlyphOutline(contours:[[.init(-40000,0),.init(0,700),.init(500,0)]],advanceWidth:600)] {
        input=glyphs();input[65]=outline
        #expect(throws:FontBuildError.invalidOutline) { try TrueTypeWriter.build(glyphs:input,postScriptName:"Test") }
    }
}
@Test func cancelledWriterDoesNotReturnFont() async {
    let task=Task { withUnsafeCurrentTask { $0?.cancel() };return try TrueTypeWriter.build(glyphs:glyphs(),postScriptName:"Cancelled") }
    do { _=try await task.value;Issue.record("cancelled writer returned bytes") } catch { #expect(error is CancellationError) }
}

@Test func structuralValidationRejectsCorruptionAndTruncation() throws {
    let good=try TrueTypeWriter.build(glyphs:glyphs(),postScriptName:"Validate")
    try FontValidation.validateGenerated(good)
    var bad=good;bad[bad.count-1] ^= 1
    #expect(throws:FontBuildError.invalidFont) { try FontValidation.validateGenerated(bad) }
    #expect(throws:FontBuildError.invalidFont) { try FontValidation.validateGenerated(good.prefix(60)) }
}
@Test func legacyFontDraftRetainsSourcesWithoutInventedMetrics() throws {
    let id=UUID(),version=UUID(),hash=String(repeating:"a",count:64)
    let data=Data("{\"id\":\"\(id)\",\"name\":\"Legacy\",\"glyphAssetHashes\":[65,\"\(hash)\"],\"versions\":[{\"id\":\"\(version)\",\"assetHash\":\"\(hash)\",\"postScriptName\":\"Legacy\"}]}".utf8)
    let project=try JSONDecoder().decode(FontProject.self,from:data)
    #expect(project.id == id);#expect(project.glyphAssetHashes[65] == hash);#expect(project.glyphMetrics.isEmpty)
    #expect(project.versions.first?.metrics == nil);#expect(project.formatVersion == 2)
}

@Test func writerBoundsComplexityAndInternalNames() {
    var input=glyphs()
    input[65]=GlyphOutline(contours:[Array(repeating:square.contours[0],count:2049).flatMap { $0 }],advanceWidth:600)
    #expect(throws:FontBuildError.tooComplex) { try TrueTypeWriter.build(glyphs:input,postScriptName:"TooLarge") }
    #expect(throws:FontBuildError.invalidFont) { try TrueTypeWriter.build(glyphs:glyphs(),postScriptName:"Invalid Name") }
}
@Test func metadataRejectsUnknownVersionAndDanglingCaptureMetrics() throws {
    var project=FontProject(name:"Draft")
    project.glyphMetrics[65]=GlyphCaptureMetrics(baselineY:80,emSize:100,xHeight:50,capHeight:70,advanceWidth:60,leftBearing:5)
    #expect(throws:NotebookError.invalidModel) { try project.validateMetadata() }
    project.glyphMetrics=[:];project.formatVersion=3
    #expect(throws:NotebookError.unsupportedVersion) { try JSONDecoder().decode(FontProject.self,from:JSONEncoder().encode(project)) }
}

@Test func fontMetadataDescribesActualXHeightAndEuroRange() throws {
    let data=try TrueTypeWriter.build(glyphs:glyphs(),postScriptName:"Metadata")
    let provider=try #require(CGDataProvider(data:data as CFData)),cg=try #require(CGFont(provider)),font=CTFontCreateWithGraphicsFont(cg,1000,nil,nil)
    let table=try #require(CTFontCopyTable(font,CTFontTableTag(kCTFontTableOS2),[]) as Data?)
    #expect(word(Array(table),46) & 2 == 2) // OpenType OS/2 Unicode bit33: Currency Symbols.
    #expect(CTFontGetXHeight(font) == 700)
    #expect(CTFontGetCapHeight(font) == 700)
}
