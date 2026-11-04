import SwiftUI
import PhotosUI

struct CoverSettingsView: View {
    let store: BookCoverStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paperAppearance) private var paper
    @Environment(\.personalSymbols) private var personalSymbols
    @State private var draft: BookCoverConfiguration
    @State private var revision: UUID?
    @State private var selection: PhotosPickerItem?
    @State private var imageTask: Task<Void,Never>?
    @State private var loading=false
    @State private var saving=false
    @State private var error: String?
    @State private var conflict=false
    @GestureState private var cropOrigin: CGPoint?
    init(store:BookCoverStore) {
        self.store=store
        _draft=State(initialValue:store.snapshot.configuration)
        _revision=State(initialValue:store.snapshot.revision)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    GeometryReader {geometry in
                        BookCoverArtwork(configuration:draft)
                            .gesture(DragGesture().updating($cropOrigin) {_,origin,_ in
                                if origin == nil {origin=CGPoint(x:draft.cropX,y:draft.cropY)}
                            }.onChanged {value in
                                guard let bytes=draft.imageData,let image=UIImage(data:bytes) else {return}
                                let origin=cropOrigin ?? CGPoint(x:draft.cropX,y:draft.cropY)
                                let crop=CoverPhotoGeometry(image:image.size,viewport:geometry.size).crop(origin:origin,translation:value.translation)
                                draft.cropX=crop.x;draft.cropY=crop.y
                            })
                            .accessibilityLabel("Cover preview")
                    }.frame(height:300).padding(.horizontal,25).padding(.vertical,12)
                        .accessibilityElement(children:.ignore).accessibilityLabel("Cover preview").accessibilityIdentifier("cover.preview")
                    TextField("Cover title",text:$draft.title).accessibilityIdentifier("cover.settings.title")
                    Picker("Cover color",selection:$draft.coverColor) {ForEach(BookCoverColor.allCases,id:\.self) {Text($0.name).tag($0)}}
                    Picker("Band color",selection:$draft.bandColor) {ForEach(BookCoverColor.allCases,id:\.self) {Text($0.name).tag($0)}}
                    PhotosPicker(selection:$selection,matching:.images) {Label {Text("Choose cover photo")} icon: {AppSymbol.importImage.image(in:personalSymbols)}}
                    if draft.imageData != nil {
                        Button("Remove cover photo",role:.destructive) {imageTask?.cancel();selection=nil;draft.imageData=nil;draft.cropX=0;draft.cropY=0}
                        Text("Drag the preview to position your photo.").font(.caption)
                        Slider(value:$draft.cropX,in:-1...1) {Text("Horizontal photo position")}
                        Slider(value:$draft.cropY,in:-1...1) {Text("Vertical photo position")}
                    }
                    if loading {ProgressView("Preparing photo")}
                }.listRowBackground(paper.color)
                Section {
                    Text("This cover is saved on this device. It is not included in note exports or iCloud note transfer.").font(.caption)
                    if let loadError=store.loadError {
                        Text(loadError).foregroundStyle(.red)
                        Button("Retry loading cover") {Task {await store.load();if store.loadError == nil,store.snapshot.revision != revision {conflict=true;error=BookCoverError.conflict.localizedDescription}}}
                    }
                    if let error {Text(error).foregroundStyle(.red).accessibilityIdentifier("cover.settings.error")}
                    if conflict {
                        Button("Keep my draft") {revision=store.snapshot.revision;conflict=false;error=nil}
                        Button("Load saved cover") {loadSaved()}
                    }
                }.listRowBackground(paper.color)
            }.paperSurface().navigationTitle("Design cover").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {Button("Cancel") {imageTask?.cancel();dismiss()}.disabled(saving).accessibilityIdentifier("cover.settings.cancel")}
                    ToolbarItem(placement:.confirmationAction) {Button("Save") {save()}.disabled(loading || saving || conflict || store.loadError != nil).accessibilityIdentifier("cover.settings.save")}
                }
                .disabled(saving)
                .onChange(of:selection) {_,item in
                    imageTask?.cancel()
                    guard let item else {loading=false;return}
                    loading=true
                    imageTask=Task {
                        defer {if !Task.isCancelled {loading=false}}
                        do {
                            guard let data=try await item.loadTransferable(type:Data.self) else {throw BookCoverError.invalidImage}
                            let image=try await Task.detached(priority:.userInitiated) {try BookCoverStore.prepareImage(data)}.value
                            try Task.checkCancellation()
                            draft.imageData=image;draft.cropX=0;draft.cropY=0;error=nil
                        } catch is CancellationError {} catch {if !Task.isCancelled {self.error=error.localizedDescription}}
                    }
                }
                .onDisappear {imageTask?.cancel()}
        }.interactiveDismissDisabled()
    }
    private func loadSaved() {draft=store.snapshot.configuration;revision=store.snapshot.revision;conflict=false;error=nil}
    private func save() {
        saving=true
        Task {
            defer {saving=false}
            do {try await store.save(draft,expectedRevision:revision);dismiss()}
            catch BookCoverError.conflict {conflict=true;error=BookCoverError.conflict.localizedDescription}
            catch {self.error=error.localizedDescription}
        }
    }
}
