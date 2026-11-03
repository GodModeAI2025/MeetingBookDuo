import Foundation
import CloudKit
import MeetingBookCore

/// One immutable wire body per asset; inline metadata stays well below the native 1 MB limit.
struct CloudKitRecordCodec: Sendable {
    static let recordType="MeetingBookWire1"
    static let zoneID=CKRecordZone.ID(zoneName:"MeetingBookPrivate1",ownerName:CKCurrentUserDefaultName)
    struct Metadata {let id:String;let kind:SyncWireRecord.Kind;let hash:String}
    struct Outgoing {let record:CKRecord;let file:URL}
    func metadata(_ record:CKRecord) throws -> Metadata {
        guard record.recordType==Self.recordType,record.recordID.zoneID==Self.zoneID,
              record["version"] as? Int == 1,
              let raw=record["kind"] as? String,let kind=SyncWireRecord.Kind(rawValue:raw),
              let hash=record["hash"] as? String,PageContent.isHash(hash) else {throw NotebookError.invalidModel}
        guard record["body"]==nil || record["body"] is CKAsset else {throw NotebookError.invalidModel}
        let id=record.recordID.recordName
        guard id.utf8.count<=128,id.hasPrefix(kind.rawValue+"-") else {throw NotebookError.invalidModel}
        let suffix=String(id.dropFirst(kind.rawValue.count+1))
        if kind == .asset {guard suffix==hash else {throw NotebookError.hashMismatch}}
        else {guard let uuid=UUID(uuidString:suffix),uuid.uuidString==suffix else {throw NotebookError.invalidModel}}
        // Unknown app fields are rejected rather than permitting unbounded inline content.
        guard Set(record.allKeys()).isSubset(of:["version","kind","hash","body"]) else {throw NotebookError.unsupportedVersion}
        return Metadata(id:id,kind:kind,hash:hash)
    }
    func decode(_ record:CKRecord) throws -> SyncWireRecord? {
        let info=try metadata(record)
        guard let asset=record["body"] as? CKAsset,let url=asset.fileURL else {return nil}
        let handle=try PackageIO.openRegular(url);defer{try? handle.close()}
        let length=try handle.seekToEnd();guard length<=SyncWireRecord.assetBudget else {throw NotebookError.invalidModel}
        try handle.seek(toOffset:0)
        let bytes=try handle.read(upToCount:Int(length)+1) ?? Data()
        guard bytes.count==length,AssetStore.hash(bytes)==info.hash else {throw NotebookError.hashMismatch}
        let wire=SyncWireRecord(id:info.id,kind:info.kind,bytes:bytes);try wire.validate();return wire
    }
    func systemFields(_ record:CKRecord) throws -> Data {
        let archive=NSKeyedArchiver(requiringSecureCoding:true)
        record.encodeSystemFields(with:archive);archive.finishEncoding()
        guard archive.encodedData.count<=1_000_000 else {throw NotebookError.invalidModel}
        return archive.encodedData
    }
    func encode(_ wire:SyncWireRecord,systemFields:Data,directory:URL) throws -> Outgoing {
        try wire.validate()
        let id=CKRecord.ID(recordName:wire.id,zoneID:Self.zoneID),record:CKRecord
        if systemFields.isEmpty {record=CKRecord(recordType:Self.recordType,recordID:id)}
        else {
            guard systemFields.count<=1_000_000 else {throw NotebookError.invalidModel}
            let unarchiver=try NSKeyedUnarchiver(forReadingFrom:systemFields)
            unarchiver.requiresSecureCoding=true;defer{unarchiver.finishDecoding()}
            guard let restored=CKRecord(coder:unarchiver),restored.recordID==id,restored.recordType==Self.recordType else {throw NotebookError.invalidModel}
            record=restored
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:AssetStore.protection)
        let file=directory.appendingPathComponent(UUID().uuidString)
        try wire.bytes.write(to:file,options:[.atomic,.completeFileProtection])
        record["version"]=1 as CKRecordValue;record["kind"]=wire.kind.rawValue as CKRecordValue
        record["hash"]=AssetStore.hash(wire.bytes) as CKRecordValue;record["body"]=CKAsset(fileURL:file)
        return Outgoing(record:record,file:file)
    }
}
