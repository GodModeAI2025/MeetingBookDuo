import Testing
import Foundation
@testable import MeetingBookCore
@Test func unicodeAndStableIdentity() throws {
    let id=UUID();var content=PageContent();content.textBlocks=[TextBlock(id:id,text:"ÄÖÜäöüß € e\u{301} 漢字 👩🏽‍💻")]
    let reopened=try JSONDecoder().decode(PageContent.self,from:JSONEncoder().encode(content))
    #expect(reopened == content);#expect(reopened.textBlocks[0].id == id);try reopened.validate()
}
@Test func orderAndSpread() {
    let p1=UUID(),p2=UUID(),p3=UUID()
    let a=Note(title:"A",orderKey:2,pageIDs:[p2,p3]), b=Note(title:"B",orderKey:1,pageIDs:[p1])
    #expect(LibraryRules.displayNumbers(notes:[a,b]) == [p1:1,p2:2,p3:3])
    #expect(LibraryRules.spread(containing:1).left == nil)
    #expect(LibraryRules.spread(containing:3).left == 2)
    #expect(LibraryRules.spread(containing:4).right == 5)
}
@Test func rejectsHostileGeometry() {
    var content=PageContent();content.textBlocks=[TextBlock(text:"x",frame:.init(x:.nan,y:0,width:2,height:2))]
    #expect(throws: NotebookError.invalidModel) { try content.validate() }
    content=PageContent();content.version=3
    #expect(throws: NotebookError.unsupportedVersion) { try content.validate() }
}

@Test func noteAuthorDatesRoundTripWithoutClockOrdering() throws {
    let note=Note(title:"Times",orderKey:0,pageIDs:[UUID()])
    var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(note)) as! [String:Any]
    json["createdAt"]=100.0;json["modifiedAt"] = -100.0
    let decoded=try JSONDecoder().decode(Note.self,from:JSONSerialization.data(withJSONObject:json))
    let output=try JSONSerialization.jsonObject(with:JSONEncoder().encode(decoded)) as! [String:Any]
    #expect(output["createdAt"] as? Double == 100)
    #expect(output["modifiedAt"] as? Double == -100)
}

@Test func noteLegacyUnknownAndFiniteDates() throws {
    var note=Note(title:"Legacy",orderKey:0,pageIDs:[UUID()])
    let legacy=try JSONDecoder().decode(Note.self,from:JSONEncoder().encode(note))
    #expect(legacy.createdAt==nil && legacy.modifiedAt==nil)
    note.createdAt=Date(timeIntervalSince1970:.infinity)
    #expect(throws:NotebookError.invalidModel) {try note.validateAuthorDates()}
    note.createdAt=nil;note.modifiedAt=Date(timeIntervalSince1970:.nan)
    #expect(throws:NotebookError.invalidModel) {try note.validateAuthorDates()}
}
