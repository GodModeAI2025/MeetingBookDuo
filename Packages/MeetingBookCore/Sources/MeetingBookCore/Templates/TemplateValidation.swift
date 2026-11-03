import Foundation
public enum TemplateValidation {
    public static func validate(_ catalog: TemplateCatalog) throws {
        guard !catalog.entries.isEmpty,catalog.entries.count<=500,
              Set(catalog.entries.map(\.id)).count==catalog.entries.count,
              catalog.presets.count+catalog.specialistNotebooks.count<=100 else {throw NotebookError.invalidModel}
        for entry in catalog.entries {
            guard !entry.id.isEmpty,entry.id.utf8.count<=200,!entry.variants.isEmpty,entry.variants.count<=2,
                  entry.title.values.allSatisfy({$0.utf8.count<=2000}) else {throw NotebookError.invalidModel}
            for (locale,variants) in entry.variants {
                guard ["de","en"].contains(locale),!variants.isEmpty,variants.count<=100,
                      Set(variants.map(\.id)).count==variants.count else {throw NotebookError.invalidModel}
                for variant in variants {
                    guard !variant.id.isEmpty,variant.id.utf8.count<=100,variant.title.utf8.count<=2000 else {throw NotebookError.invalidModel}
                    try validate(variant.blocks)
                }
            }
        }
        let compositions=catalog.presets+catalog.specialistNotebooks
        guard Set((catalog.entries.map(\.id)+compositions.map(\.id))).count==catalog.entries.count+compositions.count else {throw NotebookError.invalidModel}
        for preset in compositions {
            guard !preset.items.isEmpty,preset.items.count<=100,preset.items.allSatisfy({ item in catalog.entries.contains {$0.id==item.id} && (1...500).contains(item.count) }) else {throw NotebookError.invalidModel}
        }
    }
    public static func validate(_ configuration: TemplateConfiguration) throws {
        guard (1900...2199).contains(configuration.year),(!configuration.schoolYear || configuration.year<2199),(1...12).contains(configuration.month),
              (1...(try CalendarLayout.days(year:configuration.year,month:configuration.month))).contains(configuration.day),
              ["de","en"].contains(configuration.locale),(1...500).contains(configuration.count),(1...24).contains(configuration.people),
              [24.0,30,36].contains(configuration.textSize),configuration.inkAscent.isFinite,configuration.inkDescent.isFinite,
              (1...100).contains(configuration.inkAscent),(0...40).contains(configuration.inkDescent),configuration.lineStep<=120,configuration.timeFieldWidth.isFinite,(20...1000).contains(configuration.timeFieldWidth),
              CalendarLayout.jurisdictions.contains(configuration.holidayJurisdiction),configuration.importedVacations.count<=100,
              configuration.compositionCounts.count<=100,configuration.compositionCounts.allSatisfy({ $0.key.utf8.count<=200 && (0...500).contains($0.value) }),
              configuration.variant.map({ $0.utf8.count<=100 }) ?? true else { throw NotebookError.invalidModel }
        for interval in configuration.importedVacations { try interval.validate() }
    }
    public static func validate(_ instance: TemplateInstance) throws {
        guard (1...2).contains(instance.version),instance.geometry.version==1 else { throw NotebookError.unsupportedVersion }
        let g=instance.geometry
        guard g.width==720,g.height==1000,g.horizontalMargin.isFinite,g.verticalMargin.isFinite,
              g.horizontalMargin>=0,g.horizontalMargin<360,g.verticalMargin>=0,g.verticalMargin<500,
              g.ruling.isFinite,g.ruling>0,g.ruling<=200,
              !instance.definitionID.isEmpty,instance.definitionID.utf8.count<=200,instance.definitionVersion>0,
              instance.variant.utf8.count<=100,instance.primitives.count<=15000,instance.writingRegions.count<=2000,
              Set(instance.writingRegions.map(\.id)).count==instance.writingRegions.count else { throw NotebookError.invalidModel }
        if let c=instance.configuration { try validate(c) }
        for region in instance.writingRegions {
            if let step=region.storedBaselineStep {
                guard step.isFinite,step>0,step<=200,zip(region.baselines,region.baselines.dropFirst()).allSatisfy({abs(($1-$0)-step)<0.001}) else {throw NotebookError.invalidModel}
            }
            guard region.label.map({$0.utf8.count<=2000}) ?? true,region.frame.isValid,!region.baselines.isEmpty,region.baselines.count<=1000,
                  region.baselines.allSatisfy({ $0.isFinite && $0>=region.frame.y && $0<=region.frame.y+region.frame.height }),
                  zip(region.baselines,region.baselines.dropFirst()).allSatisfy({ $0<$1 }) else { throw NotebookError.invalidModel }
        }
        for (i,a) in instance.writingRegions.enumerated() {
            for b in instance.writingRegions.dropFirst(i+1) {
                guard !overlaps(a.frame,b.frame) else { throw NotebookError.invalidModel }
            }
        }
        for p in instance.primitives {
            guard p.frame.isValid,p.fontSize.isFinite,(6...72).contains(p.fontSize),p.lineWidth.isFinite,(0...8).contains(p.lineWidth),p.tone.isFinite,(0...1).contains(p.tone),p.text.utf8.count<=12000,p.points.count<=4096,
                  p.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...720).contains($0.x) && (0...1000).contains($0.y) }) else { throw NotebookError.invalidModel }
            if p.kind == .line { guard p.points.count == 2 else { throw NotebookError.invalidModel } }
            if p.kind == .polyline { guard p.points.count>=2 else { throw NotebookError.invalidModel } }
        }
    }
    public static func validate(_ blocks: [TemplateBlock]) throws {
        guard !blocks.isEmpty,blocks.count<=200 else { throw NotebookError.invalidModel }
        for b in blocks {
            guard b.label.utf8.count<=2000,b.items.count<=60,b.items.allSatisfy({ $0.utf8.count<=4000 }),
                  (0...100).contains(b.rows),b.height.isFinite,(0...750).contains(b.height),b.detail.utf8.count<=100,
                  b.rowLabels.count<=100,b.rowLabels.allSatisfy({$0.utf8.count<=200}),
                  b.weights.isEmpty || b.weights.count==b.items.count,
                  b.weights.allSatisfy({ $0.isFinite && (0.05...100).contains($0) }),
                  b.checks.allSatisfy({ b.items.indices.contains($0) }) else { throw NotebookError.invalidModel }
            if let cycle=b.labelCycle {
                guard !cycle.isEmpty,cycle.count<=100,cycle.allSatisfy({!$0.isEmpty && $0.utf8.count<=2000}),
                      (0...99).contains(b.cycleOffset ?? 0) else {throw NotebookError.invalidModel}
            } else if b.cycleOffset != nil {throw NotebookError.invalidModel}
            if b.type == .table { guard !b.items.isEmpty,b.items.count<=20,b.rows>0 else { throw NotebookError.invalidModel } }
            switch b.type {
            case .markGrid: guard !b.items.isEmpty,b.rows>0 else {throw NotebookError.invalidModel}
            case .wheel: guard b.items.count>=3 else {throw NotebookError.invalidModel}
            case .weekdays: guard !b.items.isEmpty else {throw NotebookError.invalidModel}
            case .linescale: guard b.items.count>=2 else {throw NotebookError.invalidModel}
            case .breath: guard b.items.isEmpty || b.items.count==4 else {throw NotebookError.invalidModel}
            case .cornell: guard b.items.isEmpty || b.items.count==3 else {throw NotebookError.invalidModel}
            case .quadrants: guard b.items.isEmpty || b.items.count==4 else {throw NotebookError.invalidModel}
            case .chart: guard b.rows>0,b.items.isEmpty || b.items.count==7 else {throw NotebookError.invalidModel}
            case .scale,.rating_list: guard (2...12).contains(b.rows) else {throw NotebookError.invalidModel}
            case .calendar: guard (1...12).contains(b.rows) else {throw NotebookError.invalidModel}
            default: break
            }
        }
    }
    public static func decodeBlocks(_ data: Data) throws -> [TemplateBlock] {
        guard data.count<=1_000_000 else { throw NotebookError.invalidModel }
        let blocks=try JSONDecoder().decode([TemplateBlock].self,from:data)
        try validate(blocks);return blocks
    }
    static func overlaps(_ a: PageRect,_ b: PageRect) -> Bool {
        min(a.x+a.width,b.x+b.width)-max(a.x,b.x)>0.01 && min(a.y+a.height,b.y+b.height)-max(a.y,b.y)>0.01
    }
}
