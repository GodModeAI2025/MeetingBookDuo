import Foundation
import WidgetKit

/// One writer for all windows. A rejected or failed update cannot replace valid bytes.
actor WidgetSnapshotPublisher {
    private let directory:URL?
    private let reload:@Sendable () -> Void
    private var newest:UInt64=0
    private var previous:WidgetSnapshot?
    init(directory:URL?=WidgetSnapshot.directory,reload:@escaping @Sendable () -> Void = {WidgetCenter.shared.reloadTimelines(ofKind:WidgetSnapshot.kind)}) {
        self.directory=directory;self.reload=reload
    }
    private static func sameTarget(_ a:WidgetSnapshot.Target?,_ b:WidgetSnapshot.Target?) -> Bool {
        switch (a,b) {
        case (nil,nil):return true
        case let (a?,b?):
            return a.noteID==b.noteID && a.pageID==b.pageID && a.preview.map{Data($0.utf8)}==b.preview.map{Data($0.utf8)}
        default:return false
        }
    }
    @discardableResult func publish(_ snapshot:WidgetSnapshot,revision:UInt64,commitGuard:StorePublicationGuard? = nil) throws -> Bool {
        guard revision>=newest else {return false};newest=revision
        let data=try snapshot.encoded()
        if let previous,previous.previewEnabled==snapshot.previewEnabled,Self.sameTarget(previous.last,snapshot.last),Self.sameTarget(previous.bookmark,snapshot.bookmark) {reload();return true}
        guard let directory else {throw CocoaError(.fileNoSuchFile)}
        let manager=FileManager.default
        try manager.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        try manager.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:directory.path)
        // Protect only our own derived directory, not other clients' App Group files.
        let file=directory.appendingPathComponent(WidgetSnapshot.filename)
        let write = {try data.write(to:file,options:[.atomic,.completeFileProtection])}
        if let commitGuard {try commitGuard.performCommittedRead(write)} else {try write()}
        var excluded=file;var values=URLResourceValues();values.isExcludedFromBackup=true
        try excluded.setResourceValues(values)
        previous=snapshot;reload();return true
    }
}
