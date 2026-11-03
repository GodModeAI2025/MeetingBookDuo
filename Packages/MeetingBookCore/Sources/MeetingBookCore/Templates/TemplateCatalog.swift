import Foundation
public struct TemplateVariant: Codable, Sendable, Equatable, Identifiable {
    public let id: String;public let title: String;public let blocks: [TemplateBlock]
}
public struct TemplateEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: [String:String]
    public let category: String
    public let classification: String
    public let variants: [String:[TemplateVariant]]
    public let sourceID: String
    public func title(locale:String) -> String { title[locale] ?? title["de"] ?? id }
    public var navigationDestinationIDs: [String] {
        switch id {
        case "planner.home":return ["planner.year","planner.index","planner.projects_home","planner.goals_year","planner.wellness_home","planner.finance_home","planner.notes_home","planner.review","planner.guide"]
        case "planner.projects_home":return ["planner.project_plan","planner.project_kanban","planner.project_budget"]
        case "planner.wellness_home":return ["planner.habits","planner.meal","planner.sleep","planner.fitness"]
        case "planner.finance_home":return ["planner.budget","planner.savings"]
        case "planner.notes_home":return ["planner.note"]
        default:return []
        }
    }
    public var configurationFields: [String] {
        var fields=["locale","textSize","font","variant"]
        if !id.hasPrefix("tool.") || id=="tool.reisekosten" {fields.append("count")}
        if ["planner.year","planner.month","planner.habits","planner.budget"].contains(id) || ["tool.jahreskalender","tool.urlaubsplaner","tool.zeiterfassung"].contains(id) {fields += ["year","month","mondayFirst","holidayJurisdiction","importedVacations"]}
        if id.hasPrefix("planner.week_") || id.hasPrefix("planner.day_") {fields += ["year","month","day","mondayFirst","holidayJurisdiction"]}
        if id=="planner.meal" {fields.append("mondayFirst")}
        if id=="tool.reisekosten" {fields.append("year")}
        if id=="tool.urlaubsplaner" {fields += ["schoolYear","people"]}
        return fields
    }
    public var isDated: Bool { configurationFields.contains("year") }
}
public struct TemplateComposition: Codable, Sendable, Equatable {
    public let id: String;public let count: Int
}
public struct TemplatePreset: Codable, Sendable, Equatable, Identifiable {
    public let id: String;public let title: [String:String];public let items: [TemplateComposition]
}
public struct TemplateCatalog: Codable, Sendable {
    public let entries: [TemplateEntry]
    public let presets: [TemplatePreset]
    public let specialistNotebooks: [TemplatePreset]
    public static func builtIn() throws -> TemplateCatalog {
        guard let url=Bundle.module.url(forResource:"catalog",withExtension:"json") else { throw NotebookError.notFound }
        let base=try JSONDecoder().decode(TemplateCatalog.self,from:Data(contentsOf:url))
        let result=TemplateCatalog(entries:base.entries+NativeTemplates.entries,presets:base.presets,specialistNotebooks:base.specialistNotebooks)
        try TemplateValidation.validate(result)
        return result
    }
    public func instantiate(id: String,configuration: TemplateConfiguration) throws -> [TemplateInstance] {
        try Task.checkCancellation()
        try TemplateValidation.validate(self)
        try TemplateValidation.validate(configuration)
        return try instantiateValidated(id:id,configuration:configuration)
    }
    private func instantiateValidated(id: String,configuration: TemplateConfiguration) throws -> [TemplateInstance] {
        if let preset=(presets+specialistNotebooks).first(where:{$0.id==id}) {
            guard Set(configuration.compositionCounts.keys).isSubset(of:Set(preset.items.map(\.id))) else {throw NotebookError.invalidModel}
            var output:[TemplateInstance]=[]
            for item in preset.items {
                try Task.checkCancellation()
                var c=configuration;c.count=configuration.compositionCounts[item.id] ?? item.count;c.variant=nil
                if c.count==0 {continue}
                output += try instantiateValidated(id:item.id,configuration:c)
                guard output.count<=5000 else { throw NotebookError.invalidModel }
            };guard !output.isEmpty else {throw NotebookError.invalidModel};return output
        }
        guard let entry=entries.first(where:{$0.id==id}) else { throw NotebookError.notFound }
        guard let variants=entry.variants[configuration.locale],!variants.isEmpty else { throw NotebookError.invalidModel }
        if let requested=configuration.variant,!variants.contains(where:{$0.id==requested}) { throw NotebookError.invalidModel }
        if id.hasPrefix("meetingbook.") { return try paper(entry,configuration) }
        if id.hasPrefix("planner.") || id.hasPrefix("tool.") { return try NativeTemplates.instantiate(entry,configuration) }
        var output:[TemplateInstance]=[]
        var index=0
        while index<configuration.count {
            try Task.checkCancellation()
            let selected: [TemplateVariant]
            if let requested=configuration.variant { selected=variants.filter { $0.id==requested } }
            else if id=="journal.travel_day" { selected=variants }
            else if id=="journal.gratitude_day" { selected=[variants[0]] }
            else { selected=[variants[index%variants.count]] }
            for v in selected {
                let name=entry.title(locale:configuration.locale)
                var variantTitle=v.title.replacingOccurrences(of:"Tag 1",with:"Tag \(index+1)").replacingOccurrences(of:"Day 1",with:"Day \(index+1)")
                if id=="journal.gratitude_day",v.id=="compact",configuration.count-index>1 {
                    variantTitle=(configuration.locale=="de" ? "Tage " : "Days ")+"\(index+1)–\(min(index+2,configuration.count))"
                }
                let title=variantTitle.hasPrefix(name) ? variantTitle:name+" · "+variantTitle
                var layout=TemplateLayout(id:id,title:configuration.count>1 ? title+" · #\(index+1)":title,variant:v.id,config:configuration)
                var blocks=v.blocks
                if id=="journal.gratitude_day",v.id=="compact",configuration.count-index==1 {
                    let headings=blocks.indices.filter {blocks[$0].type == .heading}
                    if headings.count>1 {blocks=Array(blocks.prefix(headings[1]))}
                }
                if id=="journal.gratitude_day" {
                    var offset=0
                    for k in blocks.indices where blocks[k].type == .heading {blocks[k].label=(configuration.locale=="de" ? "Tag ":"Day ")+String(index+offset+1);offset += 1}
                }
                for k in blocks.indices {
                    if let cycle=blocks[k].labelCycle {
                        blocks[k].label=cycle[(index+(blocks[k].cycleOffset ?? 0))%cycle.count]
                    }
                }
                output += try layout.resolve(blocks)
            }
            let increment=(id=="journal.gratitude_day" && configuration.variant=="compact") ? 2 : 1
            let previous=index;index=min(configuration.count,index+increment)
            if id=="journal.gratitude_day",configuration.variant != "review",index/7>previous/7,let review=variants.first(where:{$0.id=="review"}) {
                var layout=TemplateLayout(id:id,title:entry.title(locale:configuration.locale)+" · "+review.title,variant:review.id,config:configuration)
                output += try layout.resolve(review.blocks)
            }
            guard output.count<=5000 else { throw NotebookError.invalidModel }
        };return output
    }
    private func paper(_ entry: TemplateEntry,_ c: TemplateConfiguration) throws -> [TemplateInstance] {
        var p=TemplateInstance();p.definitionID=entry.id;p.configuration=c
        let step=c.lineStep,first=max(104,64+c.inkAscent+2)
        p.geometry.ruling=step;p.writingRegions=[.init(id:UUID(uuidString:"00000000-0000-4000-8000-000000000001")!,frame:.init(x:56,y:64,width:608,height:872),baselines:stride(from:first,through:936-c.inkDescent-2,by:step).map{$0},baselineStep:step)]
        if entry.id=="meetingbook.lined" { for baseline in p.writingRegions[0].baselines {
            var line=TemplatePrimitive(kind:.line,frame:.init(x:56,y:baseline,width:608,height:0.01));line.points=[.init(56,baseline),.init(664,baseline)];p.primitives.append(line)
        } }
        try TemplateValidation.validate(p);return Array(repeating:p,count:c.count)
    }
}
