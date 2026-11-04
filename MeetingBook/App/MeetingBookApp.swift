import SwiftUI
import MeetingBookCore
import CloudKit

@main struct MeetingBookApp: App {
    @State private var library=LibraryModel()
    @State private var personalSymbols=PersonalSymbolStore()
    @State private var bookCover=BookCoverStore()
    var body: some Scene {
        WindowGroup {
            NotebookView(library:library)
                .environment(\.personalSymbols,personalSymbols)
                .environment(\.bookCover,bookCover)
                .task {await personalSymbols.load()}
                .task {await bookCover.load()}
        }
    }
}

@MainActor @Observable final class LibraryModel {
    enum SyncStatus: Equatable { case local,disabled,inspecting,choice,pending,checked,accountBlocked,offline,quota,integrity }
    var syncStatus:SyncStatus = .local
    #if DEBUG
    private var syncFixtureInstalled=false
    #endif
    var syncBusy=false {didSet {if !syncBusy {scheduleSyncDrain()}}}
    @ObservationIgnored private var syncWakeup:(store:UUID,epoch:UUID)?
    @ObservationIgnored private var syncDrainTask:Task<Void,Never>?
    var syncMessage:String?
    var syncScope:SyncScope?
    var pendingSync:[SyncPendingTransaction]=[]
    var pageConflicts:[SyncConflict]=[]
    var transportIssues:[String:SyncTransportState.Issue]=[:]
    var conflictSubjects:[UUID:String]=[:]
    var syncFontNames:[UUID:String]=[:]
    var conflictToken:String?
    var syncService:CloudKitSyncService?
    var inspection:ColdRecoveryService.OwnedLibrary?
    var inspectionScope:SyncScope?
    var inspectionToken:String?
    var inspectionNotes=0
    var retainedRoots:[RetainedRoot]=[]
    struct RetainedRoot:Identifiable {let id:UUID;let scope:SyncScope;let notes:Int}
    @ObservationIgnored let accountEpoch=CloudKitAccountEpoch()
    @ObservationIgnored private var accountObserver:NSObjectProtocol?
    @ObservationIgnored private(set) var recoveryService:ColdRecoveryService?
    @ObservationIgnored private let requestedRoot:URL?
    @ObservationIgnored private let launchSync:LaunchSyncOperations
    @ObservationIgnored private(set) var launchResumeTask:Task<Void,Never>?
    private var launchResumeAttempted=false
    init(root:URL? = nil,launchSync:LaunchSyncOperations = .native,widgetPublisher:WidgetSnapshotPublisher = WidgetSnapshotPublisher(),widgetDefaults:UserDefaults = .standard) {
        self.widgetPublisher=widgetPublisher;self.widgetDefaults=widgetDefaults
        widgetPreviewEnabled=widgetDefaults.bool(forKey:"widgetTextPreview")
        widgetRevocationPending=widgetDefaults.bool(forKey:"widgetRevocationPending")
        requestedRoot=root;self.launchSync=launchSync
        accountObserver=NotificationCenter.default.addObserver(forName:.CKAccountChanged,object:nil,queue:nil) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.accountChanged() }
        }
    }
    @ObservationIgnored let widgetPublisher:WidgetSnapshotPublisher
    @ObservationIgnored private let widgetDefaults:UserDefaults
    @ObservationIgnored private var widgetRevision:UInt64=0
    var widgetPreviewEnabled:Bool
    var widgetRevocationPending:Bool
    var widgetPublicationFailed=false
    var storeReady=false
    var restoring=false
    var restoreGeneration=0
    private var routingGeneration=0
    @ObservationIgnored private var pendingRefresh=Set<UUID>()
    var openFontStudios=Set<UUID>()
    private final class WeakSession { weak var value: EditorSession?;init(_ value: EditorSession) { self.value=value } }
    @ObservationIgnored private var editors:[WeakSession]=[]
    func register(_ session: EditorSession) { editors.removeAll{$0.value == nil};if !editors.contains(where:{$0.value === session}) { editors.append(WeakSession(session)) } }
    func beginRestore() throws {
        guard !restoring else { throw EditorOperationError.inProgress }
        guard openFontStudios.isEmpty else { throw TransferError.openFontProject }
        guard editors.compactMap(\.value).filter({store == nil || $0.store.identity==store?.identity}).allSatisfy({$0.leasedPageIDs.isEmpty && !$0.busy && !$0.strokeActive && $0.pendingAssetWrites.isEmpty}) else { throw TransferError.unsavedWindows }
        restoring=true;for editor in editors.compactMap(\.value) { editor.navigationLocked=true }
    }
    func endRestore(committed: Bool) {
        for editor in editors.compactMap(\.value) { editor.navigationLocked=false }
        if committed { restoreGeneration+=1;bookmarkGeneration+=1;editors.removeAll{$0.value?.store.identity==store?.identity} }
        restoring=false
    }
    private(set) var transferDirectory: URL?
    private(set) var safetyDirectory: URL?
    private(set) var baseRoot: URL?
    private var cleanedRecoveryRoots=false
    private(set) var store: NotebookStore?
    private(set) var notes: [Note]=[]
    var bookmarkGeneration=0 {didSet {Task {await refreshWidget()}}}
    var error: String?
    private var opening: Task<NotebookStore,Error>?
    func open() async {
        let route=routingGeneration
        do {
            if opening == nil {
                opening=Task {
                    var root=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("NotebookLibrary")
                    #if DEBUG
                    if let value=ProcessInfo.processInfo.environment["MEETINGBOOK_TEST_LIBRARY"],let id=UUID(uuidString:value) { root=root.deletingLastPathComponent().appendingPathComponent("UITestLibraries").appendingPathComponent(id.uuidString) }
                    #endif
                    root=requestedRoot ?? root
                    baseRoot=root
                    let recovery=recoveryService ?? ColdRecoveryService(baseRoot:root);recoveryService=recovery
                    if !cleanedRecoveryRoots { try await recovery.cleanAbandonedImportFiles();cleanedRecoveryRoots=true }
                    root=try await recovery.selectedRoot()
                    if FileManager.default.fileExists(atPath:root.path),!FileManager.default.fileExists(atPath:root.appendingPathComponent("metadata.sqlite").path),!(try FileManager.default.contentsOfDirectory(atPath:root.path)).isEmpty { throw NotebookError.invalidModel }
                    let store:NotebookStore
                    if root.path != baseRoot?.path,let id=UUID(uuidString:root.lastPathComponent) {store=try await recovery.prepareOwnedLibrary(rootID:id).store}
                    else {store=try await NotebookStore.open(root:root)}
                    #if DEBUG
                    try await FontStudioFixture.installIfRequested(store:store)
                    #endif
                    return store
                }
            }
            let opened=try await opening!.value
            guard route==routingGeneration else {return}
            let same=store?.identity==opened.identity
            store=opened
            if let store {
                let root=store.root
                transferDirectory=root.appendingPathComponent("Transfers/Temporary");safetyDirectory=root.appendingPathComponent("RecoveryPackages")
                syncScope=try await store.syncScope()
                guard route==routingGeneration else {return}
                if !same {syncStatus=syncScope?.accountFingerprint == nil ? .local : .disabled}
                else {try await refreshSyncDiagnostics()}
            }
            try await reload(wakeSync:false)
            #if DEBUG
            try await installSyncUIFixtureIfRequested()
            #endif
            storeReady=true
            await refreshWidget()
            scheduleLaunchResume()
        } catch { self.error=error.localizedDescription }
    }
    func retry() async { opening=nil;await open() }
    func reload(wakeSync:Bool=true) async throws {
        guard let store else { return };let generation=restoreGeneration,route=routingGeneration
        let result=try await store.listNotes(includeDeleted:true)
        guard self.store?.identity==store.identity,restoreGeneration==generation,routingGeneration==route else {return};notes=result
        if wakeSync {syncForeground()}
        await refreshWidget()
    }
}

extension LibraryModel {
    /// Local open finishes first. Only this process's first selected-root startup can schedule a resume.
    private func scheduleLaunchResume() {
        guard !launchResumeAttempted else {return};launchResumeAttempted=true
        guard let target=store,let scope=syncScope,scope.enabled,scope.accountFingerprint != nil,
              scope.receiveOnly != true,scope.archived != true,target.root.path != baseRoot?.path else {return}
        let route=routingGeneration,token=accountEpoch.read()
        launchResumeTask=Task { [weak self] in
            await Task.yield()
            guard let self,!self.syncBusy else {return}
            self.syncBusy=true;defer{self.syncBusy=false}
            var connected:CloudKitSyncService?
            do {
                let configuration:CloudKitConfiguration
                do {configuration=try self.launchSync.configuration()} catch {
                    self.syncMessage=String(localized:"iCloud is not available in this version. Your notebook stays on this device.");return
                }
                try await self.checkLaunchRoute(target,scope:scope,route:route,token:token)
                guard scope.container==configuration.container,scope.environment==configuration.environment else {throw SyncChoiceError.accountMismatch}
                let fingerprint=try await self.launchSync.discover(configuration)
                try await self.checkLaunchRoute(target,scope:scope,route:route,token:token)
                guard scope.accountFingerprint==fingerprint else {
                    self.syncScope=try await target.archiveScope(expected:scope)
                    throw SyncChoiceError.accountMismatch
                }
                let resumed=try await target.bindAccountAfterConsent(fingerprint:fingerprint,container:configuration.container,environment:configuration.environment,expected:scope,engineID:UUID())
                try await self.checkLaunchRoute(target,scope:resumed,route:route,token:token)
                let native=try await self.launchSync.connect(target,resumed,configuration);connected=native
                try await self.checkLaunchRoute(target,scope:resumed,route:route,token:token)
                self.syncService=native;self.syncScope=resumed
                try await self.requestRefreshingLocal(store:target,scope:resumed,token:token) {try await self.launchSync.request(native)}
                try await self.checkLaunchRoute(target,scope:resumed,route:route,token:token)
                try await self.refreshAfterSync(store:target,scope:resumed)
            } catch {
                await connected?.disconnect()
                if self.syncService === connected {self.syncService=nil}
                if token != self.accountEpoch.read() {
                    await self.accountChanged()
                    do {_ = try await self.recoverInterruptedSelection()}
                    catch {self.syncMessage=error.localizedDescription}
                } else {await self.syncFailed(error)}
            }
        }
    }
    private func checkLaunchRoute(_ target:NotebookStore,scope:SyncScope,route:Int,token:UUID) async throws {
        try check(token)
        guard !Task.isCancelled,store?.identity==target.identity,routingGeneration==route,inspection==nil,let recoveryService else {throw NotebookError.revisionConflict}
        try await target.requireScope(scope);try check(token)
        let selected=try await recoveryService.selectedRoot();try check(token)
        guard selected.path==target.root.path,store?.identity==target.identity,routingGeneration==route,inspection==nil else {throw NotebookError.revisionConflict}
        try await target.requireScope(scope);try check(token)
    }
    func configuredCloud() throws -> CloudKitConfiguration {
        try CloudKitConfiguration(container:Bundle.main.object(forInfoDictionaryKey:"MeetingBookCloudKitContainer") as? String,environment:Bundle.main.object(forInfoDictionaryKey:"MeetingBookCloudKitEnvironment") as? String)
    }
    private func check(_ token:UUID) throws {try accountEpoch.withCurrent(token,{})}
    private func quiesce() async throws {
        guard !restoring,openFontStudios.isEmpty else {throw TransferError.openFontProject}
        restoring=true
        let participating=editors.compactMap(\.value).filter{$0.store.identity==store?.identity}
        for editor in participating {editor.navigationLocked=true}
        do {for editor in participating {try await editor.leave()}}
        catch {endTransition();throw error}
    }
    private func endTransition() {
        for editor in editors.compactMap(\.value) {editor.navigationLocked=false}
        restoring=false
    }
    private func publish(_ selected:NotebookStore,token:UUID) async throws {
        let newNotes=try await selected.listNotes(includeDeleted:true),root=selected.root,scope=try await selected.syncScope()
        try accountEpoch.withCurrent(token) {
            routingGeneration+=1;store=selected;notes=newNotes;syncScope=scope
            transferDirectory=root.appendingPathComponent("Transfers/Temporary");safetyDirectory=root.appendingPathComponent("RecoveryPackages")
            opening=Task {selected};bookmarkGeneration+=1
        }
        storeReady=true
        await refreshWidget();try check(token)
        if pendingRefresh.remove(selected.identity) != nil {try await reload();try check(token)}
    }
    /// A receipt remains with its originating store; it cannot reload a newly selected account.
    /// Events coalesce across windows; a commit during a request retains one trailing drain.
    func syncForeground() {
        guard let store,storeReady,inspection==nil,let scope=syncScope,scope.enabled,
              scope.accountFingerprint != nil,scope.receiveOnly != true,scope.archived != true,
              syncStatus != .accountBlocked,store.root.path != baseRoot?.path else {return}
        syncWakeup=(store.identity,accountEpoch.read());scheduleSyncDrain()
    }
    private func scheduleSyncDrain() {
        guard syncWakeup != nil,!syncBusy,syncDrainTask==nil else {return}
        syncDrainTask=Task { [weak self] in
            do {try await Task.sleep(for:.milliseconds(500))} catch {return}
            guard let self else {return}
            self.syncDrainTask=nil
            guard !self.syncBusy,let wakeup=self.syncWakeup else {return}
            self.syncWakeup=nil
            guard let target=self.store,target.identity==wakeup.store,wakeup.epoch==self.accountEpoch.read(),
                  self.inspection==nil,!self.restoring,let scope=self.syncScope,scope.enabled,
                  scope.receiveOnly != true,scope.archived != true,self.syncStatus != .accountBlocked else {return}
            let route=self.routingGeneration
            self.syncBusy=true;defer{self.syncBusy=false}
            do {
                try await self.checkLaunchRoute(target,scope:scope,route:route,token:wakeup.epoch)
                let configuration=try self.launchSync.configuration()
                guard scope.container==configuration.container,scope.environment==configuration.environment else {throw SyncChoiceError.accountMismatch}
                let restart=await self.syncService?.requiresRestart ?? false
                if self.syncService==nil || restart {
                    let fingerprint=try await self.launchSync.discover(configuration)
                    try await self.checkLaunchRoute(target,scope:scope,route:route,token:wakeup.epoch)
                    guard fingerprint==scope.accountFingerprint else {throw SyncChoiceError.accountMismatch}
                    let old=self.syncService;self.syncService=nil;await old?.disconnect()
                    try await self.checkLaunchRoute(target,scope:scope,route:route,token:wakeup.epoch)
                    self.syncService=try await self.launchSync.connect(target,scope,configuration)
                }
                try await self.checkLaunchRoute(target,scope:scope,route:route,token:wakeup.epoch)
                guard let native=self.syncService else {throw NotebookError.revisionConflict}
                try await self.requestRefreshingLocal(store:target,scope:scope,token:wakeup.epoch) {try await self.launchSync.request(native)}
                try await self.checkLaunchRoute(target,scope:scope,route:route,token:wakeup.epoch)
                try await self.refreshAfterSync(store:target,scope:scope)
            } catch {
                if wakeup.epoch==self.accountEpoch.read(),self.store?.identity==target.identity {await self.syncFailed(error)}
            }
        }
    }
    func localCommit(from original:NotebookStore) async {
        guard store?.identity==original.identity else {pendingRefresh.insert(original.identity);return}
        do {try await reload();try await refreshSyncDiagnostics()} catch {syncStatus = .integrity;syncMessage=error.localizedDescription}
    }
    func prepareLocalForInspection(token:UUID) async throws {
        guard let source=store,let recoveryService else {throw NotebookError.notFound}
        try await quiesce();defer{endTransition()}
        let sourceScope=try await source.syncScope(),generation=try await source.snapshotGeneration();try check(token)
        if source.root.path==baseRoot?.path,sourceScope.accountFingerprint==nil {
            let epoch=accountEpoch
            let adopted=try await recoveryService.adoptLocalBase(source:source,expectedScope:sourceScope,expectedGeneration:generation,publication:{action in try epoch.withCurrent(token,action)})
            try await publish(adopted.store,token:token)
        }
    }
    func beginCloudInspection() async {
        guard !syncBusy else {return};syncBusy=true;defer{syncBusy=false}
        do {
            let configuration:CloudKitConfiguration
            do {configuration=try configuredCloud()} catch {syncMessage=String(localized:"iCloud is not available in this version. Your notebook stays on this device.");return}
            guard let recoveryService else {throw NotebookError.notFound}
            accountEpoch.invalidate();let token=accountEpoch.read()
            if let old=syncService {syncService=nil;try await old.disable();try check(token)}
            syncStatus = .inspecting
            let fingerprint=try await CloudKitAccountDiscovery().discover(configuration:configuration);try check(token)
            try await prepareLocalForInspection(token:token)
            let candidate=try await recoveryService.createCloudInspectionCandidate(configuration:configuration,fingerprint:fingerprint);try check(token)
            let scope=try await candidate.store.syncScope(),native=CloudKitSyncService(store:candidate.store,scope:scope)
            inspection=candidate;inspectionScope=scope;syncService=native
            try await native.connect(configuration:configuration,accountFingerprint:fingerprint);try check(token)
            try await native.requestSync();try check(token)
            inspectionToken=try await candidate.store.syncGraphToken();inspectionNotes=try await candidate.store.listNotes().count
            try check(token);syncStatus = .choice;syncMessage=nil
            try await refreshSyncDiagnostics()
        } catch {await syncFailed(error)}
    }
    /// Local selection commit, shared by production and deterministic integration tests; never sends.
    func activateCloudChoice(merge:Bool,personalContentConsent:Bool) async throws -> (store:NotebookStore,scope:SyncScope) {
        guard personalContentConsent,let candidate=inspection,let expected=inspectionScope,let graph=inspectionToken,let source=store,let recoveryService else {throw NotebookError.revisionConflict}
        let token=accountEpoch.read()
        try await quiesce();defer{endTransition()}
        let sourceScope=try await source.syncScope(),generation=try await source.snapshotGeneration()
        let sourceGuard=try await source.publicationGuard(expectedScope:sourceScope,expectedGeneration:generation)
        let capture=try await source.captureBackup()
        guard capture.generation==generation else {await source.assets.releasePin(capture.pin);throw NotebookError.revisionConflict}
        let sourceRoot=source.root
        let safety=try await NotebookPackage(root:sourceRoot.appendingPathComponent("RecoveryPackages")).create(capture:capture,assets:source.assets)
        try check(token);try await source.requireScope(sourceScope)
        guard try await source.snapshotGeneration()==generation,try await candidate.store.syncGraphToken()==graph else {throw NotebookError.revisionConflict}
        // Disconnect inspection first. No upload-capable engine exists until selection commits.
        let old=syncService;syncService=nil;await old?.disconnect();try check(token)
        guard try await candidate.store.syncGraphToken()==graph else {throw NotebookError.revisionConflict}
        let current=try await candidate.store.syncScope()
        guard current.accountFingerprint==expected.accountFingerprint,current.container==expected.container,current.environment==expected.environment,current.receiveOnly==true else {throw NotebookError.revisionConflict}
        let promoted=try await candidate.store.bindAccountAfterConsent(fingerprint:expected.accountFingerprint!,container:expected.container!,environment:expected.environment!,expected:current,engineID:UUID())
        if merge {
            let root=candidate.store.root
            let importer=RestoreService(store:candidate.store,root:root.appendingPathComponent("Transfers/Temporary/Imports"),safetyRoot:root.appendingPathComponent("RecoveryPackages"))
            let promotedToken=try await candidate.store.syncGraphToken()
            let preview=try await importer.inspectImport(url:safety,sizePolicy:.large);try check(token)
            try await importer.restore(preview,policy:.merge,cloudScope:promoted,cloudGraphToken:promotedToken);try check(token)
        }
        try await source.requireScope(sourceScope)
        guard try await source.snapshotGeneration()==generation else {throw NotebookError.revisionConflict}
        let epoch=accountEpoch
        try await recoveryService.activateOwnedLibrary(rootID:candidate.rootID,expectedScope:promoted,sourceGuard:sourceGuard,publication:{action in try epoch.withCurrent(token,action)})
        try await publish(candidate.store,token:token)
        inspection=nil;inspectionScope=nil;inspectionToken=nil
        return (candidate.store,promoted)
    }
    func commitCloudChoice(merge:Bool,personalContentConsent:Bool) async {
        guard !syncBusy else {return};syncBusy=true;defer{syncBusy=false}
        let token=accountEpoch.read()
        do {
            let selected=try await activateCloudChoice(merge:merge,personalContentConsent:personalContentConsent)
            let native=CloudKitSyncService(store:selected.store,scope:selected.scope);syncService=native
            let configuration=try configuredCloud()
            try await native.connect(configuration:configuration,accountFingerprint:selected.scope.accountFingerprint!);try check(token)
            try await requestRefreshingLocal(store:selected.store,scope:selected.scope,token:token) {try await native.requestSync()};try check(token)
            try await refreshAfterSync(store:selected.store,scope:selected.scope)
        } catch {if token != accountEpoch.read() {await accountChanged()};await syncFailed(error)}
    }
    func disableCloud() async {
        accountEpoch.invalidate();let native=syncService;syncService=nil;inspection=nil;inspectionScope=nil;inspectionToken=nil
        do {
            if let native {try await native.disable()}
            if let store {let current=try await store.syncScope();if current.enabled {_ = try await store.disableKeepingLocalData(expected:current)}}
            syncStatus = .disabled;try await refreshSyncDiagnostics()
        } catch {syncMessage=error.localizedDescription}
    }
    func accountChanged() async {
        accountEpoch.invalidate()
        if syncScope?.accountFingerprint != nil || inspection != nil || syncService != nil {syncStatus = .accountBlocked}
        await refreshWidget(neutral:true)
        guard syncScope?.accountFingerprint != nil || inspection != nil || syncService != nil else {return}
        let native=syncService;syncService=nil;inspection=nil;inspectionScope=nil;inspectionToken=nil
        syncStatus = .accountBlocked;syncMessage=String(localized:"The iCloud account changed. Previous notes and drafts remain on this device. Choose an account explicitly before transferring again.")
        do {
            try await native?.disable()
            if let store {let scope=try await store.syncScope();if scope.accountFingerprint != nil {syncScope=try await store.archiveScope(expected:scope)}}
        } catch {syncMessage=error.localizedDescription}
    }
    func resumeInspection(_ id:UUID) async {
        guard !syncBusy,let recoveryService else {return};syncBusy=true;defer{syncBusy=false}
        do {
            let configuration=try configuredCloud()
            accountEpoch.invalidate();let token=accountEpoch.read()
            let old=syncService;syncService=nil;try await old?.disable();try check(token)
            let fingerprint=try await CloudKitAccountDiscovery().discover(configuration:configuration);try check(token)
            try await prepareLocalForInspection(token:token)
            let candidate=try await recoveryService.prepareOwnedLibrary(rootID:id),scope=try await candidate.store.syncScope()
            guard scope.accountFingerprint==fingerprint,scope.container==configuration.container,scope.environment==configuration.environment,scope.receiveOnly==true else {throw NotebookError.revisionConflict}
            inspection=candidate;inspectionScope=scope;inspectionToken=nil
            try await runCloudRequest(token:token)
        } catch {await syncFailed(error)}
    }
    func retryCloud() async {
        guard !syncBusy else {return};syncBusy=true;defer{syncBusy=false}
        let token=accountEpoch.read()
        do {try await runCloudRequest(token:token)} catch {
            if token != accountEpoch.read() {await accountChanged()};await syncFailed(error)
        }
    }
    private func runCloudRequest(token:UUID) async throws {
        guard let target=inspection?.store ?? store else {throw NotebookError.notFound}
        let startingScope=try await target.syncScope();try check(token)
        guard inspection==nil || startingScope.receiveOnly==true else {throw SyncChoiceError.interrupted}
        let restart=await syncService?.requiresRestart ?? false,connected=await syncService?.isConnected ?? false
        if !connected || restart {
            let old=syncService;syncService=nil;await old?.disconnect();try check(token)
            let configuration=try configuredCloud(),fingerprint=try await CloudKitAccountDiscovery().discover(configuration:configuration);try check(token)
            let oldScope=try await target.syncScope();try check(token)
            guard oldScope.accountFingerprint==fingerprint,oldScope.container==configuration.container,oldScope.environment==configuration.environment else {throw NotebookError.revisionConflict}
            let scope:SyncScope
            if oldScope.receiveOnly==true {scope=try await target.resumeCloudInspection(expected:oldScope,engineID:UUID());inspectionScope=scope}
            else {scope=try await target.bindAccountAfterConsent(fingerprint:fingerprint,container:configuration.container,environment:configuration.environment,expected:oldScope,engineID:UUID())}
            try check(token)
            let native=CloudKitSyncService(store:target,scope:scope);syncService=native
            try await native.connect(configuration:configuration,accountFingerprint:fingerprint);try check(token)
        }
        let requestScope=try await target.syncScope();try check(token)
        try await requestRefreshingLocal(store:target,scope:requestScope,token:token) {try await syncService?.requestSync()};try check(token)
        if inspection != nil {
            inspectionToken=try await target.syncGraphToken();inspectionNotes=try await target.listNotes().count
            try check(token);syncStatus = .choice;syncMessage=nil;try await refreshSyncDiagnostics()
        } else {let scope=try await target.syncScope();try await refreshAfterSync(store:target,scope:scope)}
    }
    func refreshSyncDiagnostics() async throws {
        guard let target=inspection?.store ?? store else {return}
        let scope=try await target.syncScope()
        let pending=try await target.pendingWireTransactions(scope:scope),conflicts=try await target.unresolvedPageConflicts(),token=try await target.syncGraphToken(),transport=try await target.transportState(scope:scope)
        let outgoing=scope.enabled && scope.receiveOnly != true ? try await target.pendingOperations(scope:scope).count : 0
        let refetch=try await target.pendingWireRefetches(scope:scope).count
        guard (inspection?.store ?? store)?.identity==target.identity,try await target.syncScope()==scope else {return}
        let fontNames=await target.fontProjects().reduce(into:[UUID:String]()){$0[$1.id]=$1.name}
        var subjects:[UUID:String]=[:]
        for conflict in conflicts {subjects[conflict.id]=try await target.conflictAffectedEntity(conflict)}
        guard (inspection?.store ?? store)?.identity==target.identity,try await target.syncScope()==scope else {return}
        pendingSync=pending;pageConflicts=conflicts;conflictSubjects=subjects;syncFontNames=fontNames;conflictToken=token;transportIssues=transport.issues
        if inspection != nil {return}
        syncScope=scope
        if !scope.enabled || syncService == nil {if syncStatus != .accountBlocked && syncStatus != .integrity {syncStatus=scope.accountFingerprint == nil ? .local : .disabled}}
        else if transport.issues.values.contains(where:{$0.code == .quota}) {syncStatus = .quota}
        else if transport.issues.values.contains(where:{$0.code == .offline || $0.code == .rateLimited}) {syncStatus = .offline}
        else if syncStatus != .integrity {syncStatus = pending.isEmpty && conflicts.isEmpty && outgoing==0 && refetch==0 && transport.issues.isEmpty ? .checked : .pending}
    }
    /// Reconciliation can commit incoming data before the outgoing phase fails.
    private func requestRefreshingLocal(store original:NotebookStore,scope:SyncScope,token:UUID,request:() async throws -> Void) async throws {
        do {try await request()}
        catch {
            let failure=error
            do {try check(token);try await refreshLocalGraph(store:original,scope:scope);try check(token)} catch {}
            throw failure
        }
    }
    private func refreshAfterSync(store original:NotebookStore,scope:SyncScope) async throws {
        try await refreshLocalGraph(store:original,scope:scope)
        try await original.requireScope(scope)
        guard store?.identity==original.identity,scope.archived != true else {return}
        syncMessage=nil;syncStatus = .pending
        try await refreshSyncDiagnostics()
    }
    private func refreshLocalGraph(store original:NotebookStore,scope:SyncScope) async throws {
        try await original.requireScope(scope)
        guard store?.identity==original.identity,scope.archived != true,scope.receiveOnly != true else {return}
        try await reload(wakeSync:false);try await original.requireScope(scope)
        guard store?.identity==original.identity else {return}
        for editor in editors.compactMap(\.value) where editor.store.identity==original.identity && editor.leasedPageIDs.isEmpty && !editor.busy && !editor.canUndo && !editor.canRedo {
            try await editor.refresh();try await original.requireScope(scope)
            guard store?.identity==original.identity else {return}
        }
        bookmarkGeneration+=1
    }
    func resolveConflict(page:UUID? = nil,transaction:UUID? = nil,choice:SyncConflictChoice,token:String) async {
        guard !syncBusy,inspection==nil,let store else {return};syncBusy=true;defer{syncBusy=false}
        do {
            let scope=try await store.syncScope()
            if let page {_ = try await store.resolvePageConflict(id:page,choice:choice,expectedToken:token,scope:scope)}
            else if let transaction {_ = try await store.resolveWireConflict(transactionID:transaction,choice:choice,expectedToken:token,scope:scope)}
            try await refreshAfterSync(store:store,scope:scope)
        } catch {await syncFailed(error);try? await refreshSyncDiagnostics()}
    }
    func retireUndoAndRetry() async {
        guard let store,!syncBusy else {return}
        do {
            let matching=editors.compactMap(\.value).filter{$0.store.identity==store.identity}
            guard matching.allSatisfy({$0.leasedPageIDs.isEmpty && !$0.busy && !$0.strokeActive && $0.pendingAssetWrites.isEmpty}) else {throw TransferError.unsavedWindows}
            for editor in matching {try editor.retireUndoHistoryAfterConsent()}
            let scope=try await store.syncScope()
            _ = try await store.reconcileWire(scope:scope);try await refreshAfterSync(store:store,scope:scope)
        } catch {await syncFailed(error)}
    }
    func retryIssue(_ id:String) async {
        do {try await syncService?.retryTransportIssue(id);await retryCloud()} catch {await syncFailed(error)}
    }
    func loadRetainedRoots() async {
        guard let recoveryService else {return}
        do {
            var values:[RetainedRoot]=[]
            for id in try await recoveryService.ownedRootIDs() {
                do {
                    let candidate=try await recoveryService.prepareOwnedLibrary(rootID:id),scope=try await candidate.store.syncScope()
                    if candidate.store.identity != store?.identity {values.append(RetainedRoot(id:id,scope:scope,notes:try await candidate.store.listNotes().count))}
                } catch {syncMessage=String(localized:"One retained library could not be opened. Its files were kept for recovery.")}
            }
            retainedRoots=values
        } catch {syncMessage=error.localizedDescription}
    }
    func selectRetainedRoot(_ id:UUID) async {
        guard !syncBusy,!restoring,let recoveryService else {return}
        guard openFontStudios.isEmpty else {syncMessage=TransferError.openFontProject.localizedDescription;return}
        syncBusy=true;defer{syncBusy=false}
        await disableCloud();let token=accountEpoch.read()
        do {
            let candidate=try await recoveryService.prepareOwnedLibrary(rootID:id)
            var scope=try await candidate.store.syncScope()
            guard scope.receiveOnly != true else {throw NotebookError.revisionConflict}
            if scope.enabled {scope=try await candidate.store.disableKeepingLocalData(expected:scope)}
            let epoch=accountEpoch
            try await recoveryService.activateOwnedLibrary(rootID:id,expectedScope:scope,publication:{action in try epoch.withCurrent(token,action)})
            try await publish(candidate.store,token:token);try await refreshSyncDiagnostics();await loadRetainedRoots()
        } catch {await syncFailed(error)}
    }
    private func syncFailed(_ failure:Error) async {
        if let choice=failure as? SyncChoiceError,case .accountMismatch=choice {
            syncStatus = .accountBlocked;syncMessage=choice.localizedDescription
        } else if let unavailable=failure as? CloudKitAccountDiscovery.AccountUnavailable {
            syncStatus = .accountBlocked
            switch unavailable.status {
            case .noAccount: syncMessage=String(localized:"Sign in to iCloud in Settings to use transfer. Local work remains available.")
            case .restricted: syncMessage=String(localized:"iCloud access is restricted. Local work remains available.")
            default: syncMessage=String(localized:"iCloud account availability could not be confirmed. Try again later.")
            }
        } else {syncStatus = .integrity;syncMessage=failure.localizedDescription}
        try? await refreshSyncDiagnostics()
        if let cloud=failure as? CKError {
            switch cloud.code {
            case .networkUnavailable,.networkFailure: syncStatus = .offline
            case .quotaExceeded: syncStatus = .quota
            default: break
            }
        }
        do {
            if try await recoverInterruptedSelection() {
                syncStatus = .integrity;syncMessage=String(localized:"The selected library was reopened after an interrupted switch. Both libraries were kept; transfer remains stopped.")
            }
        } catch {syncStatus = .integrity;syncMessage=error.localizedDescription}
    }
    /// Reopen the actual existing pointer after uncertain publication; never connect an engine.
    func recoverInterruptedSelection() async throws -> Bool {
        guard let recoveryService,let current=store else {return false}
        let selected=try await recoveryService.selectedRoot()
        guard selected.path != current.root.path else {return false}
        let native=syncService;syncService=nil;await native?.disconnect()
        inspection=nil;inspectionScope=nil;inspectionToken=nil
        await retry()
        guard let reopened=store,reopened.root.path==selected.path else {throw TransferError.activationUncertain}
        let scope=try await reopened.syncScope()
        if scope.enabled {syncScope=try await reopened.disableKeepingLocalData(expected:scope)}
        return true
    }

}

#if DEBUG
extension LibraryModel {
    /// Test-only UI fixture using real store/wire contracts. No native account or engine is created.
    private func installSyncUIFixtureIfRequested() async throws {
        guard !syncFixtureInstalled,ProcessInfo.processInfo.environment["MEETINGBOOK_TEST_LIBRARY"] != nil,
              let mode=ProcessInfo.processInfo.environment["MEETINGBOOK_SYNC_FIXTURE"],["quota","conflict"].contains(mode),let store else {return}
        syncFixtureInstalled=true
        let scope=try await store.bindAccountAfterConsent(fingerprint:String(repeating:"a",count:64),container:"iCloud.de.meetingbook.app",environment:"development",expected:store.syncScope(),engineID:UUID())
        syncService=CloudKitSyncService(store:store,scope:scope)
        if mode=="quota" {try await store.setTransportIssue("transport",issue:.init(code:.quota,retryAfter:nil),scope:scope)}
        else {
            let peer=try await NotebookStore.open(root:store.root.appendingPathComponent("UITestPeer")),note=try await peer.createNote(title:"Fixture note")
            let peerScope=try await peer.bindAccountAfterConsent(fingerprint:scope.accountFingerprint!,container:scope.container!,environment:scope.environment!,expected:peer.syncScope(),engineID:UUID())
            for wire in try await peer.prepareWireOutbox(scope:peerScope) {try await store.stageWire(wire,scope:scope);try await peer.acknowledgeWire(wire,scope:peerScope,systemFields:Data())}
            _ = try await store.reconcileWire(scope:scope)
            let page=try await peer.openPage(id:note.pageIDs[0]);var first=page.content,second=page.content
            first.textBlocks=[TextBlock(text:"First preserved draft")];second.textBlocks=[TextBlock(text:"Second preserved draft")]
            _ = try await peer.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:first))
            _ = try await store.commit(.init(pageID:page.id,expectedRevisionID:page.currentRevisionID,content:second))
            for wire in try await peer.prepareWireOutbox(scope:peerScope) {try await store.stageWire(wire,scope:scope)}
            _ = try await store.reconcileWire(scope:scope)
        }
        try await reload();try await refreshSyncDiagnostics()
        syncMessage=String(localized:"Deterministic UI test fixture. No iCloud connection.")
    }
}
#endif


private enum SyncChoiceError:LocalizedError {
    case interrupted,accountMismatch
    var errorDescription:String? {
        switch self {
        case .accountMismatch: return String(localized:"This library belongs to another iCloud account or environment. Choose a library explicitly; local data is retained.")
        case .interrupted: return String(localized:"This library choice was interrupted. Disable this inspection and start a new one. The retained candidate has not been sent.")
        }
    }
}


/// Narrow native I/O seam for deterministic launch tests; the app always uses these real defaults.
struct LaunchSyncOperations:Sendable {
    var configuration:@MainActor @Sendable () throws -> CloudKitConfiguration
    var discover:@Sendable (CloudKitConfiguration) async throws -> String
    var connect:@Sendable (NotebookStore,SyncScope,CloudKitConfiguration) async throws -> CloudKitSyncService
    var request:@Sendable (CloudKitSyncService) async throws -> Void
    static let native=LaunchSyncOperations(configuration:{
        try CloudKitConfiguration(container:Bundle.main.object(forInfoDictionaryKey:"MeetingBookCloudKitContainer") as? String,environment:Bundle.main.object(forInfoDictionaryKey:"MeetingBookCloudKitEnvironment") as? String)
    },discover:{try await CloudKitAccountDiscovery().discover(configuration:$0)},connect:{store,scope,configuration in
        let native=CloudKitSyncService(store:store,scope:scope)
        do {try await native.connect(configuration:configuration,accountFingerprint:scope.accountFingerprint!);return native}
        catch {await native.disconnect();throw error}
    },request:{try await $0.requestSync()})
}


extension LibraryModel {
    func setWidgetPreview(_ enabled:Bool) async {
        widgetPreviewEnabled=enabled
        widgetDefaults.set(enabled,forKey:"widgetTextPreview")
        if !enabled {
            widgetRevocationPending=true
            widgetDefaults.set(true,forKey:"widgetRevocationPending")
        }
        await refreshWidget()
    }
    /// Widget errors never propagate into a successful local save or root choice.
    func refreshWidget(neutral:Bool=false) async {
        widgetRevision &+= 1
        let revision=widgetRevision,source=store,epoch=accountEpoch.read()
        let preview=widgetPreviewEnabled
        await Task.yield()
        guard revision==widgetRevision else {return}
        do {
            let snapshot:WidgetSnapshot,commitGuard:StorePublicationGuard?
            if !neutral,storeReady,syncStatus != .accountBlocked,let source {
                let capture=try await source.widgetCapture(previewEnabled:preview)
                snapshot=capture.snapshot;commitGuard=capture.guardValue
            } else {snapshot=WidgetSnapshot();commitGuard=nil}
            guard revision==widgetRevision,source?.identity==store?.identity,epoch==accountEpoch.read(),preview==widgetPreviewEnabled else {return}
            let published=try await widgetPublisher.publish(snapshot,revision:revision,commitGuard:commitGuard)
            guard revision==widgetRevision,published else {return}
            widgetPublicationFailed=false
            if !snapshot.previewEnabled {
                widgetRevocationPending=false
                widgetDefaults.set(false,forKey:"widgetRevocationPending")
            }
        } catch {
            guard revision==widgetRevision else {return}
            widgetPublicationFailed=true
        }
    }
}
