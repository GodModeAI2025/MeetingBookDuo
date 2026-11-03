import SwiftUI
import MeetingBookCore

struct TemplateChoice: Identifiable {
    let id: String
    let title: String
    let category: String
}

struct TemplateChooser: View {
    let store: NotebookStore
    let insert: @MainActor ([PageContent], TextDefaults) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var catalog: TemplateCatalog?
    @State private var query=""
    @State private var selectedID: String?
    @State private var category="all"
    @AppStorage("templateFavorites") private var favorites=""
    @AppStorage("templateRecents") private var recents=""
    var choices: [TemplateChoice] {
        guard let catalog else { return [] }
        let language=locale.language.languageCode?.identifier == "de" ? "de" : "en"
        let all=catalog.entries.map { TemplateChoice(id:$0.id,title:$0.title(locale:language),category:$0.category) } + (catalog.presets+catalog.specialistNotebooks).map { TemplateChoice(id:$0.id,title:$0.title[language] ?? $0.id,category:"collections") }
        return all.filter { choice in
            (category == "all" || category == choice.category || category == "favorites" && favorites.split(separator:"|").contains(Substring(choice.id)) || category == "recent" && recents.split(separator:"|").contains(Substring(choice.id))) && (query.isEmpty || (choice.title+" "+choice.category+" "+Bundle.main.localizedString(forKey:choice.category,value:choice.category,table:nil)+" "+choice.id).range(of:query,options:[.caseInsensitive,.diacriticInsensitive]) != nil)
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:typeSize.isAccessibilitySize ? 300 : 155),spacing:20)],spacing:24) {
                    ForEach(choices) { choice in
                        NavigationLink { if let catalog { TemplateDetail(store:store,catalog:catalog,choice:choice) { plan,defaults in
                            try await insert(plan,defaults)
                            recents=([choice.id]+recents.split(separator:"|").map(String.init).filter{$0 != choice.id}).prefix(20).joined(separator:"|")
                            dismiss()
                        } } } label: {
                            TemplateCard(catalog:catalog,choice:choice,selected:selectedID==choice.id,language:locale.language.languageCode?.identifier == "de" ? "de" : "en")
                        }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { selectedID=choice.id }).accessibilityIdentifier("template."+choice.id)
                    }
                }.padding()
                if choices.isEmpty { ContentUnavailableView.search(text:query);Button("Reset search") { query="";category="all" } }
            }
            .navigationTitle("Choose template").navigationBarTitleDisplayMode(.inline)
            .searchable(text:$query,prompt:"Name, category or topic")
            .safeAreaInset(edge:.top) {
                Picker("Category",selection:$category) {
                    Text("All templates").tag("all");Text("Favorites").tag("favorites");Text("Recent").tag("recent")
                    ForEach(Array(Set((catalog?.entries.map(\.category) ?? [])+["collections"])).sorted(),id:\.self) { Text(LocalizedStringKey($0)).tag($0) }
                }.pickerStyle(.menu).padding(8).frame(maxWidth:.infinity).background(.bar)
            }
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { do { catalog=try TemplateCatalog.builtIn() } catch { query=error.localizedDescription } }
        }
    }
}

struct TemplateCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let catalog: TemplateCatalog?
    let choice: TemplateChoice
    let selected: Bool
    let language: String
    @State private var thumbnail: UIImage?
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            ZStack {
                Color(uiColor:.secondarySystemBackground)
                if let thumbnail { Image(uiImage:thumbnail).resizable().scaledToFit() }
                else if error != nil { Image(systemName:"exclamationmark.triangle") }
                else { ProgressView() }
            }.aspectRatio(0.72,contentMode:.fit).frame(maxWidth:typeSize.isAccessibilitySize ? 86 : .infinity,maxHeight:typeSize.isAccessibilitySize ? 120 : .infinity).accessibilityHidden(true).clipShape(RoundedRectangle(cornerRadius:6)).overlay(RoundedRectangle(cornerRadius:6).stroke(.quaternary))
            HStack { Text(choice.title).font(.headline);if selected { Image(systemName:"checkmark.circle.fill").foregroundStyle(.tint) } }.fixedSize(horizontal:false,vertical:true)
            Text(LocalizedStringKey(choice.category)).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children:.combine).accessibilityAddTraits(selected ? .isSelected : [])
        .task(id:choice.id+language) {
            guard thumbnail == nil,let catalog else { return }
            do {
                var c=TemplateConfiguration();c.locale=language
                c=try TemplateRenderer.measuredConfiguration(c,font:HandwritingFontCatalog.font(catalogID:"bundled.caveat",size:30))
                // A collection thumbnail represents its first module, not a generation of the whole collection.
                let id=(catalog.presets+catalog.specialistNotebooks).first(where:{$0.id==choice.id})?.items.first?.id ?? choice.id
                let config=c
                let plan=try await Task.detached { try catalog.instantiate(id:id,configuration:config) }.value
                try Task.checkCancellation()
                if let first=plan.first { var content=PageContent();content.template=first;thumbnail=try PageRenderer.image(content,resources:.init(),scale:0.3) }
            } catch is CancellationError {} catch { self.error=error.localizedDescription }
        }
    }
}

struct TemplateDetail: View {
    let store: NotebookStore
    let catalog: TemplateCatalog
    let choice: TemplateChoice
    let insert: @MainActor ([PageContent], TextDefaults) async throws -> Void
    @Environment(\.locale) private var locale
    @State private var configuration=TemplateConfiguration()
    @State private var generatedConfiguration: TemplateConfiguration?
    @State private var generatedDefaults: TextDefaults?
    @State private var vacationStart=Date()
    @State private var vacationEnd=Date()
    @State private var vacationTitle=""
    @State private var vacationSource=""
    @State private var plan:[TemplateInstance]=[]
    @State private var preview: UIImage?
    @State private var previewIndex=0
    @State private var generation: Task<[TemplateInstance],Error>?
    @State private var epoch=UUID()
    @State private var busy=false
    @State private var inserting=false
    @State private var error: String?
    @State private var defaults=TextDefaults()
    @AppStorage("paper") private var paper="classic"
    @AppStorage("ruling") private var ruling="lined"
    @State private var versions:[FontVersion]=[]
    @State private var fontProjects:[FontProject]=[]
    @State private var fontsReady=false
    @AppStorage("templateFavorites") private var favorites=""
    var entry: TemplateEntry? { catalog.entries.first{$0.id==choice.id} }
    var composition: TemplatePreset? { (catalog.presets+catalog.specialistNotebooks).first{$0.id==choice.id} }
    var fields: Set<String> { Set(entry?.configurationFields ?? composition?.items.flatMap { item in catalog.entries.first{$0.id==item.id}?.configurationFields ?? [] } ?? []) }
    var body: some View {
        Form {
            Section {
                Text(choice.title).font(.title2).fixedSize(horizontal:false,vertical:true)
                if let preview { Image(uiImage:preview).resizable().scaledToFit().frame(maxHeight:420).frame(maxWidth:.infinity).accessibilityLabel("Template preview") }
                if !plan.isEmpty {
                    Text(String(localized:"\(plan.count) pages"))
                    Stepper("Preview page \(previewIndex+1)",value:$previewIndex,in:0...max(0,plan.count-1)).onChange(of:previewIndex) { _,_ in render() }
                }
                if busy { ProgressView("Generating pages");Button("Cancel generation") { generation?.cancel();epoch=UUID();busy=false } }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Configuration") {
                Picker("Font",selection:Binding(get:{defaults.fontVersionID?.uuidString ?? defaults.fontCatalogID ?? "system"},set:{ value in
                    if let id=UUID(uuidString:value) { defaults.fontVersionID=id } else {defaults.fontVersionID=nil;defaults.fontCatalogID=value}
                })) {
                    Text("Caveat").tag("bundled.caveat");Text("Gochi Hand").tag("bundled.gochi-hand");Text("System · readable").tag("system")
                    ForEach(versions) { Text(PersonalFontLabels.version($0.id,projects:fontProjects)).tag($0.id.uuidString) }
                }.disabled(!fontsReady)
                Picker("Ink",selection:$defaults.ink) { Text("Marine").tag("marine");Text("Plum").tag("plum");Text("Ochre").tag("ochre");Text("Teal").tag("teal");Text("Graphite").tag("graphite") }
                Picker("Paper",selection:$paper) { Text("Classic").tag("classic");Text("Cream").tag("cream");Text("Rose").tag("rose") }
                ContrastChoice(paper:paper,ink:$defaults.ink)
                if entry?.id == "meetingbook.lined" { Picker("Ruling",selection:$ruling) { Text("Lined").tag("lined");Text("Grid").tag("grid");Text("Dots").tag("dots") } }
                Picker("Language",selection:$configuration.locale) { Text("Deutsch").tag("de");Text("English").tag("en") }
                if let entry {
                    Picker("Layout",selection:$configuration.variant) {
                        Text("Automatic sequence").tag(String?.none)
                        ForEach(entry.variants[configuration.locale] ?? []) { Text($0.title).tag(Optional($0.id)) }
                    }
                }
                if fields.contains("count"),composition == nil { Stepper("Count: \(configuration.count)",value:$configuration.count,in:1...500) }
                if fields.contains("year") { Stepper("Year: \(configuration.year)",value:$configuration.year,in:1900...2199) }
                if fields.contains("month") { Stepper("Month: \(configuration.month)",value:$configuration.month,in:1...12) }
                if fields.contains("day") { Stepper("Day: \(configuration.day)",value:$configuration.day,in:1...31) }
                if fields.contains("mondayFirst") { Toggle("Week starts on Monday",isOn:$configuration.mondayFirst) }
                if fields.contains("schoolYear") { Toggle("School year",isOn:$configuration.schoolYear) }
                if fields.contains("people") { Stepper("People: \(configuration.people)",value:$configuration.people,in:1...24) }
                if fields.contains("holidayJurisdiction") {
                    Picker("Holidays",selection:$configuration.holidayJurisdiction) { Text("None").tag("none");Text("Germany").tag("DE");ForEach(CalendarLayout.jurisdictions.filter{$0 != "none" && $0 != "DE"},id:\.self) { Text(holidayName($0)).tag($0) } }
                    Text("Holiday rules are current-rule projections; local exceptions may apply.").font(.caption)
                }
                Picker("Document size",selection:$configuration.textSize) { Text("Small · 24").tag(24.0);Text("Medium · 30").tag(30.0);Text("Large · 36").tag(36.0) }
            }
            if fields.contains("importedVacations") {
                Section("Vacation periods") {
                    DatePicker("From",selection:$vacationStart,displayedComponents:.date)
                    DatePicker("Through",selection:$vacationEnd,displayedComponents:.date)
                    TextField("Period name",text:$vacationTitle)
                    TextField("Source",text:$vacationSource)
                    Button("Add period") {
                        let interval=CalendarInterval(start:CalendarLayout.calendar.startOfDay(for:vacationStart),end:CalendarLayout.calendar.startOfDay(for:vacationEnd),title:vacationTitle,source:vacationSource)
                        do { try interval.validate();configuration.importedVacations.append(interval) } catch { self.error=error.localizedDescription }
                    }.disabled(vacationSource.isEmpty || configuration.importedVacations.count>=100)
                    ForEach(Array(configuration.importedVacations.enumerated()),id:\.offset) { index,period in
                        HStack { Text(period.title);Spacer();Button("Remove",role:.destructive) { configuration.importedVacations.remove(at:index) } }
                    }
                }
            }
            if let composition {
                Section("Pages per module") {
                    ForEach(composition.items,id:\.id) { item in
                        Stepper(value:Binding(get:{configuration.compositionCounts[item.id] ?? item.count},set:{configuration.compositionCounts[item.id]=$0}),in:0...500) {
                            Text("\(catalog.entries.first{$0.id==item.id}?.title(locale:configuration.locale) ?? item.id): \(configuration.compositionCounts[item.id] ?? item.count)")
                        }
                    }
                }
            }
            Section { Button("Generate preview") { generate() }.disabled(busy || inserting || !fontsReady);Text("Up to 5,000 pages. Nothing is added until you use this template.").font(.caption) }
        }
        .navigationTitle("Template").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.primaryAction) {
                Button("Use template") { Task { inserting=true;defer { inserting=false };do { var selectedDefaults=defaults;selectedDefaults.fontSize=configuration.textSize;try await insert(plan.map(styled),selectedDefaults) } catch { self.error=error.localizedDescription } } }.disabled(plan.isEmpty || busy || inserting)
            }
            ToolbarItem(placement:.secondaryAction) {
                Button("Favorite",systemImage:favorites.split(separator:"|").contains(Substring(choice.id)) ? "star.fill" : "star") {
                    var ids=favorites.split(separator:"|").map(String.init);if ids.contains(choice.id) { ids.removeAll{$0==choice.id} } else { ids.append(choice.id) };favorites=ids.joined(separator:"|")
                }
            }
        }
        .task {
            configuration.locale=locale.language.languageCode?.identifier == "de" ? "de" : "en"
            defaults=await store.preferences().textDefaults ?? TextDefaults();fontProjects=await store.fontProjects();versions=fontProjects.flatMap(\.versions)
            for version in versions { do { try await PersonalFontService(assets:store.assets).register(version:version) } catch { self.error=error.localizedDescription;return } }
            fontsReady=true;configuration.textSize=defaults.fontSize;generate()
        }
        .onChange(of:configuration) { _,value in if generatedConfiguration != value { generation?.cancel();epoch=UUID();plan=[];preview=nil;busy=false } }
        .onChange(of:defaults) { _,value in if generatedDefaults != value { generation?.cancel();epoch=UUID();plan=[];preview=nil;busy=false } }
        .onChange(of:paper) { _,_ in render() }
        .onChange(of:ruling) { _,_ in render() }
        .onDisappear { generation?.cancel() }
    }
    private func generate() {
        generatedConfiguration=configuration;generatedDefaults=defaults
        generation?.cancel();let token=UUID();epoch=token;busy=true;error=nil;plan=[];preview=nil
        let font=HandwritingFontCatalog.font(catalogID:defaults.fontCatalogID,personalVersion:versions.first{$0.id==defaults.fontVersionID},size:configuration.textSize)
        let config: TemplateConfiguration
        do { config=try TemplateRenderer.measuredConfiguration(configuration,font:font) } catch { self.error=error.localizedDescription;busy=false;return }
        let id=choice.id
        let work=Task.detached { try catalog.instantiate(id:id,configuration:config) };generation=work
        Task { do { let output=try await work.value;guard epoch==token else { return };plan=output;previewIndex=0;busy=false;render() } catch { guard epoch==token else { return };busy=false;if !(error is CancellationError) { self.error=error.localizedDescription } } }
    }
    private func styled(_ template: TemplateInstance) -> PageContent {
        var content=PageContent();content.version=2;content.template=template;content.style.paper=paper;content.style.ink=defaults.ink;content.style.fontSize=configuration.textSize
        if template.supportsPaperRuling && template.definitionID != "meetingbook.blank" { content.style.ruling=ruling };return content
    }
    private func render() {
        guard plan.indices.contains(previewIndex) else { return }
        do { let content=styled(plan[previewIndex]);preview=try PageRenderer.image(content,resources:.init(),scale:0.7) } catch { self.error=error.localizedDescription }
    }
}


private func holidayName(_ code:String) -> LocalizedStringKey {
    switch code {
    case "BW": "Baden-Württemberg"
    case "BY": "Bavaria"
    case "BE": "Berlin"
    case "BB": "Brandenburg"
    case "HB": "Bremen"
    case "HH": "Hamburg"
    case "HE": "Hesse"
    case "MV": "Mecklenburg-Western Pomerania"
    case "NI": "Lower Saxony"
    case "NW": "North Rhine-Westphalia"
    case "RP": "Rhineland-Palatinate"
    case "SL": "Saarland"
    case "SN": "Saxony"
    case "ST": "Saxony-Anhalt"
    case "SH": "Schleswig-Holstein"
    case "TH": "Thuringia"
    default: LocalizedStringKey(code)
    }
}
