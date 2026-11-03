#if DEBUG
import Foundation
import PencilKit
import MeetingBookCore

/// Explicit UI-test fixture. Repeated synthetic strokes prove the pipeline, not handwriting quality.
@MainActor enum FontStudioFixture {
    static func installIfRequested(store: NotebookStore) async throws {
        if let count=ProcessInfo.processInfo.environment["MEETINGBOOK_FONT_PROJECT_COUNT"].flatMap(Int.init),
           (1...50).contains(count),await store.fontProjects().isEmpty {
            for index in 1...count {try await store.saveFontProject(FontProject(name:"QA project \(index)"))}
        }
        guard ProcessInfo.processInfo.environment["MEETINGBOOK_FONT_FIXTURE"] == "1",await store.fontProjects().isEmpty else { return }
        let points=[CGPoint(x:90,y:300),CGPoint(x:180,y:90),CGPoint(x:270,y:300)]
        let path=PKStrokePath(controlPoints:points.enumerated().map { index,point in
            PKStrokePoint(location:point,timeOffset:Double(index)*0.1,size:CGSize(width:6,height:6),opacity:1,force:1,azimuth:0,altitude:.pi/2)
        },creationDate:Date(timeIntervalSince1970:0))
        let drawing=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:path)])
        let staged=try await store.assets.stage(data:drawing.dataRepresentation()),hash=try await store.assets.finalize(staged)
        var project=FontProject(name:"QA synthetic · repeated strokes")
        for code in FontCoverage.required where code != 32 {
            project.glyphAssetHashes[code]=hash
            project.glyphMetrics[code]=GlyphCaptureMetrics(baselineY:300,emSize:300,xHeight:150,capHeight:210,advanceWidth:650,leftBearing:40)
        }
        try await store.saveFontProject(project)
    }
}
#endif
