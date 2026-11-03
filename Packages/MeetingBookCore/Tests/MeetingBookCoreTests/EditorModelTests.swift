import Testing
import Foundation
@testable import MeetingBookCore

@Test func legacyTypographyEncodingDoesNotChange() throws {
    let block=TextBlock(text:"e\u{301} 👩🏽‍💻")
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    let before=try encoder.encode(block)
    let decoded=try JSONDecoder().decode(TextBlock.self,from:before)
    #expect(decoded.fontCatalogID == nil)
    #expect(decoded.fontSize == nil)
    #expect(try encoder.encode(decoded) == before)
}
@Test func boundTypographyValidatesAgainstStoredRegion() throws {
    var content=PageContent();content.version=2
    var block=TextBlock(text:"日本語")
    block.fontSize=24;block.ink="blue";block.fontCatalogID="bundled.caveat"
    block.writingRegionID=content.template.writingRegions[0].id;block.baselineIndex=0
    content.textBlocks=[block];try content.validate()
    content.textBlocks[0].baselineIndex=999
    #expect(throws: NotebookError.invalidModel) { try content.validate() }
}

@Test func editingPromotesVersionAndFreezesLegacyTypography() throws {
    var content=PageContent();content.style.fontSize=24;content.style.ink="blue";content.textBlocks=[TextBlock(text:"legacy")]
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    let legacy=try encoder.encode(content)
    content.prepareForEditing();content.style.fontSize=36;content.style.ink="red"
    #expect(content.version == 2);#expect(content.textBlocks[0].fontSize == 24);#expect(content.textBlocks[0].ink == "blue")
    try content.validate()
    content.version=1
    #expect(throws: NotebookError.unsupportedVersion) { try content.validate() }
    let old=try JSONDecoder().decode(PageContent.self,from:legacy)
    #expect(try encoder.encode(old) == legacy)
}

@Test func newElementDefaultsRequireNewPreferenceVersion() throws {
    var preferences=LibraryPreferences();preferences.textDefaults=TextDefaults(fontSize:36,ink:"blue",fontCatalogID:"bundled.caveat")
    #expect(throws: NotebookError.unsupportedVersion) { try preferences.validate() }
    preferences.version=2;try preferences.validate()
    #expect(try JSONDecoder().decode(LibraryPreferences.self,from:JSONEncoder().encode(preferences)) == preferences)
}
