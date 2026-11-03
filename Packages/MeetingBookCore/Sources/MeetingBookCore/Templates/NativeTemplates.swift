import Foundation
/// Hand-adapted planner/tool structures, resolved using the requested calendar, never a preview year.
enum NativeTemplates {
    static let plannerNames:[(String,String,String,String)] = [
        ("cover","Deckblatt","Cover","cover"),("home","Übersicht","Overview","navigation"),("guide","Anleitung","Guide","navigation"),("toc","Inhaltsverzeichnis","Table of contents","contents"),("index","Index","Index","contents"),
        ("year","Jahresübersicht","Year overview","writing"),("month","Monatsplan","Month plan","writing"),
        ("week_1","Woche · Übersicht","Week · overview","writing"),("week_2","Woche · Zeitplan","Week · schedule","writing"),("week_3","Woche · Gewohnheiten & Rückblick","Week · habits & review","writing"),("week_4","Woche · Finanzen","Week · finances","writing"),
        ("day_1","Tag · Fokus & Zeitplan","Day · focus & schedule","writing"),("day_2","Tag · Gespräch & Reflexion","Day · meeting & reflection","writing"),
        ("projects_home","Projekte","Projects","navigation"),("project_plan","Projektplan","Project plan","writing"),("project_kanban","Kanban","Kanban","writing"),("project_budget","Projektbudget","Project budget","writing"),
        ("goals_year","Jahresziele","Annual goals","writing"),("goals_quarter","Quartalsziele","Quarterly goals","writing"),
        ("wellness_home","Gesundheit","Wellness","navigation"),("habits","Gewohnheiten","Habits","writing"),("meal","Essensplan","Meal plan","writing"),("sleep","Schlafprotokoll","Sleep log","writing"),("fitness","Training","Fitness","writing"),
        ("finance_home","Finanzen","Finances","navigation"),("budget","Monatsbudget","Monthly budget","writing"),("savings","Sparziele","Savings","writing"),
        ("notes_home","Notizen","Notes","navigation"),("note","Notizseite","Note page","writing"),("review","Jahresrückblick","Annual review","writing")]
    static var entries:[TemplateEntry] {
        var result=plannerNames.map { name,de,en,kind in TemplateEntry(id:"planner."+name,title:["de":de,"en":en],category:"planning",classification:kind,variants:["de":variants(name,"de"),"en":variants(name,"en")],sourceID:"page_"+name) }
        for (id,de,en) in [("jahreskalender","Jahreskalender","Annual calendar"),("urlaubsplaner","Urlaubsplaner","Vacation planner"),("zeiterfassung","Zeiterfassung","Time tracking"),("reisekosten","Reisekosten","Travel expenses")] {
            let names = id == "jahreskalender" ? ["full-year","half-years"] : id == "urlaubsplaner" ? ["months","paired-months","summary"] : id == "zeiterfassung" ? ["year-summary","month"] : ["summary","trip","reference"]
            result.append(.init(id:"tool."+id,title:["de":de,"en":en],category:"tools",classification:"writing",variants:Dictionary(uniqueKeysWithValues:["de","en"].map { l in (l,names.map { .init(id:$0,title:variantTitle($0,l),blocks:[.init(.heading,de)]) }) }),sourceID:id))
        }
        for (id,de,en) in [("lined","Liniert","Lined paper"),("blank","Blanko","Blank paper")] { result.append(.init(id:"meetingbook."+id,title:["de":de,"en":en],category:"paper",classification:"writing",variants:["de":[.init(id:"default",title:de,blocks:[.init(.lines)])],"en":[.init(id:"default",title:en,blocks:[.init(.lines)])]],sourceID:id)) }
        return result
    }
    static func variantTitle(_ id:String,_ locale:String) -> String {
        let names:[String:(String,String)]=["default":("Standard","Default"),"lines":("Liniert","Lined"),"dots":("Punkte","Dotted"),"grid":("Kariert","Grid"),"cornell":("Cornell","Cornell"),"full-year":("Ganzes Jahr","Full year"),"half-years":("Halbjahre","Half years"),"months":("Monatsblätter","Monthly sheets"),"paired-months":("Zwei Monate je Blatt","Two months per sheet"),"summary":("Übersicht","Summary"),"year-summary":("Jahresübersicht","Annual summary"),"month":("Monatsblatt","Monthly sheet"),"trip":("Reiseformular","Trip form"),"reference":("Eigene Pauschalenreferenz","Your allowance reference")]
        guard let value=names[id] else {return id};return locale=="de" ? value.0:value.1
    }
    static func variants(_ name:String,_ locale:String)->[TemplateVariant] {
        let names=name=="note" ? ["lines","dots","grid","cornell"]:["default"]
        return names.map { .init(id:$0,title:variantTitle($0,locale),blocks:[.init(.heading,name)]) }
    }
    static func instantiate(_ entry:TemplateEntry,_ config:TemplateConfiguration) throws -> [TemplateInstance] {
        let allowed=entry.variants[config.locale]!.map(\.id)
        if let v=config.variant,!allowed.contains(v) { throw NotebookError.invalidModel }
        var output:[TemplateInstance]=[]
        let id=entry.id
        if id.hasPrefix("tool.") { return try tool(entry,config) }
        for _ in 0..<config.count {
            try Task.checkCancellation()
            var layout=TemplateLayout(id:id,title:entry.title(locale:config.locale),variant:config.variant ?? "default",config:config)
            if id=="planner.year" {
                for month in 1...12 {let i=month-1;layout.smallCalendar(month:month,x:56+Double(i%3)*202.6,y:112+Double(i/3)*195,width:190,height:183)}
                output.append(layout.page)
                let holidays=try holidayBlocks(config)
                if !holidays.isEmpty {var details=TemplateLayout(id:id,title:entry.title(locale:config.locale),variant:"holiday-reference",config:config);output += try details.resolve(holidays)}
            } else {output += try layout.resolve((try planner(id,config))+(entry.isDated ? try holidayBlocks(config,month:config.month):[]))}
            guard output.count<=5000 else {throw NotebookError.invalidModel}
        };return output
    }
    static func planner(_ id:String,_ c:TemplateConfiguration) throws -> [TemplateBlock] {
        let de=c.locale=="de"
        func l(_ a:String,_ b:String)->String { de ? a:b }
        func p(_ a:String,_ b:String,_ n:Int=3)->TemplateBlock { .init(.prompt,l(a,b),rows:n) }
        func t(_ a:[String],_ b:[String],_ n:Int=7,labels:[String]=[])->TemplateBlock { .init(.table,items:de ? a:b,rows:n,rowLabels:labels) }
        let date=String(format:"%04d-%02d-%02d",c.year,c.month,c.day)
        let wd=de ? ["Montag","Dienstag","Mittwoch","Donnerstag","Freitag","Samstag","Sonntag"]:["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
        let ordered=c.mondayFirst ? wd:[wd[6]]+Array(wd.prefix(6))
        let dates=try CalendarLayout.weekDates(year:c.year,month:c.month,day:c.day,mondayFirst:c.mondayFirst)
        let week=zip(ordered,dates).map { label,d in let dc=CalendarLayout.calendar.dateComponents([.day,.month],from:d);return label+String(format:" %02d.%02d.",dc.day!,dc.month!) }
        let iso=try CalendarLayout.isoWeek(year:c.year,month:c.month,day:c.day)
        let weekTitle=l("KW","ISO week")+" \(iso.week) / \(iso.year) · "+date
        let hours=(6...22).map { String(format:"%02d:00",$0) }
        switch id {
        case "planner.cover":return [.init(.heading,l("Mein Planer","My planner")),.init(.fields,items:[l("Name","Name"),l("Zeitraum","Period")])]
        case "planner.home","planner.projects_home","planner.wellness_home","planner.finance_home","planner.notes_home":
            let entry=entries.first {$0.id==id}!
            let labels=entry.navigationDestinationIDs.compactMap { target in plannerNames.first {"planner."+$0.0==target} }.map {de ? $0.1:$0.2}
            return labels.map { .init(.band,$0) }
        case "planner.guide":return [.init(.paragraphs,items:[l("Wähle eine Vorlage und ihren Zeitraum. Beschriftete Bereiche sind zum Schreiben gedacht; kleine Raster sind Markierungsfelder.","Choose a template and its period. Labelled regions support writing; small grids are for marks."),l("Jede Seite speichert ihr Layout. Spätere Katalogänderungen verschieben vorhandene Notizen nicht.","Each page stores its layout. Later catalog updates do not move existing notes.")])]
        case "planner.toc","planner.index":return [t(["Seite","Thema","Notiz"],["Page","Topic","Note"],10)]
        case "planner.year":return (1...12).map { .init(.calendar,rows:$0) }
        case "planner.month":return [.init(.calendar,rows:c.month),p("Monatsziele","Monthly goals"),t(["Datum","Termin","Notizen"],["Date","Appointment","Notes"],try CalendarLayout.days(year:c.year,month:c.month),labels:(1...(try CalendarLayout.days(year:c.year,month:c.month))).map(String.init)),p("Rückblick","Review")]
        case "planner.week_1":return [.init(.heading,weekTitle),p("Fokus & Prioritäten","Focus & priorities"),t(["Tag","Termine","Aufgaben"],["Day","Appointments","Tasks"],labels:week),p("Notizen","Notes")]
        case "planner.week_2":return [.init(.heading,weekTitle)]+week.map { .init(.table,$0,items:[l("Zeit","Time"),l("Zeitblock","Time block")],rows:17,rowLabels:hours) }
        case "planner.week_3":return [.init(.heading,weekTitle),.init(.markGrid,l("Gewohnheiten","Habits"),items:week,rows:8),p("Gewohnheiten / Ziele","Habits / goals",4),p("Erfolge","Wins"),p("Herausforderungen","Challenges"),p("Nächste Woche","Next week")]
        case "planner.week_4":return [.init(.heading,weekTitle),t(["Einnahme","Betrag"],["Income","Amount"],10),t(["Ausgabe","Betrag"],["Expense","Amount"],10),.init(.fields,items:[l("Summe Einnahmen","Total income"),l("Summe Ausgaben","Total expenses"),l("Saldo","Balance")])]
        case "planner.day_1":return [.init(.heading,date),p("Ein wichtiges Ziel","One important goal",1),.init(.checklist,l("Drei Prioritäten","Three priorities"),rows:3),t(["Zeit","Zeitblock"],["Time","Time block"],17,labels:hours),.init(.checklist,l("Aufgaben","Tasks"),rows:6),p("Erfolge / morgen","Wins / tomorrow"),.init(.scale,l("Wasser","Water"),rows:8)]
        case "planner.day_2":return [.init(.heading,date),.init(.fields,items:[l("Gesprächsthema / Teilnehmende","Meeting topic / participants")]),p("Gespräch / Notizen","Meeting / notes",5),t(["Maßnahme","Verantwortlich","Fällig"],["Action","Owner","Due"],3),p("Dankbarkeit","Gratitude"),.init(.fields,items:de ? ["Schlaf","Wasser","Bewegung","Mahlzeiten"]:["Sleep","Water","Movement","Meals"]),t(["Wichtig & dringend","Wichtig & später"],["Important & urgent","Important & later"],3),t(["Delegieren","Streichen"],["Delegate","Remove"],3)]
        case "planner.project_plan":return [.init(.fields,items:[l("Projekt / Verantwortlich / Termin","Project / owner / due date")]),p("Ziel & Erfolgskriterien","Goal & success criteria"),p("Umfang / Risiken","Scope / risks"),t(["Meilenstein","Termin","Status"],["Milestone","Date","Status"],6),p("Team & Ressourcen","Team & resources"),p("Risiken & Entscheidungen","Risks & decisions"),p("Nächste Schritte","Next steps")]
        case "planner.project_kanban":return [t(["Offen","In Arbeit","Erledigt"],["To do","In progress","Done"],10)]
        case "planner.project_budget","planner.budget":return [t(["Posten","Geplant","Tatsächlich","Differenz"],["Item","Planned","Actual","Difference"],12),p("Einnahmen / Ausgaben / Differenz","Income / expense / difference",3)]
        case "planner.goals_year","planner.goals_quarter":return (1...(id=="planner.goals_year" ? 5:3)).flatMap { i in [p(l("Ziel","Goal")+" \(i)","Goal \(i)",2),p("Warum / Messgröße / Termin","Why / measure / due date",3),.init(.checklist,l("Meilensteine","Milestones"),rows:4)] }
        case "planner.habits":return [.init(.markGrid,l("Monatsgewohnheiten","Monthly habits"),items:(1...(try CalendarLayout.days(year:c.year,month:c.month))).map(String.init),rows:12),p("Gewohnheiten / Zielwerte","Habits / targets",6)]
        case "planner.meal":return [t(["Tag","Frühstück","Mittag","Abend"],["Day","Breakfast","Lunch","Dinner"],labels:ordered),.init(.checklist,l("Einkaufsliste","Shopping list"),rows:10)]
        case "planner.sleep":return [t(["Datum","Zu Bett","Aufgestanden","Dauer","Qualität","Notizen"],["Date","Bedtime","Wake time","Duration","Quality","Notes"]),p("Beobachtungen","Observations")]
        case "planner.fitness":return [t(["Datum","Übung","Sätze / Wiederholungen","Gewicht","Dauer"],["Date","Exercise","Sets / reps","Weight","Duration"],10),p("Fortschritt","Progress")]
        case "planner.savings":return [t(["Sparziel","Zielbetrag","Aktuell"],["Goal","Target amount","Current"],8),.init(.markGrid,l("Fortschritt","Progress"),items:(1...10).map{String($0*10)+"%"},rows:8)]
        case "planner.note":
            if c.variant=="cornell" { return [.init(.cornell,items:de ? ["Stichworte","Notizen","Zusammenfassung"]:["Cues","Notes","Summary"])] }
            return [.init(c.variant=="dots" ? .dots:c.variant=="grid" ? .grid:.lines,rows:18,height:720)]
        case "planner.review":return [p("Höhepunkte","Highlights",4),p("Gelernt","Lessons learned",4),p("Dankbar für","Grateful for",4),p("Beste Bücher / Medien","Best books / media",4),p("Beste Orte / Reisen","Best places / trips",4),p("Vorsätze für nächstes Jahr","Intentions for next year",4)]
        default:throw NotebookError.notFound
        }
    }
    static func tool(_ entry:TemplateEntry,_ c:TemplateConfiguration) throws -> [TemplateInstance] {
        let de=c.locale=="de"
        func l(_ a:String,_ b:String)->String {de ? a:b}
        var output:[TemplateInstance]=[]
        func append(_ blocks:[TemplateBlock],_ variant:String,_ configuration:TemplateConfiguration) throws {
            var layout=TemplateLayout(id:entry.id,title:entry.title(locale:c.locale)+" · \(configuration.year)",variant:variant,config:configuration)
            output += try layout.resolve(blocks)
        }
        switch entry.id {
        case "tool.jahreskalender":
            let half=c.variant=="half-years"
            for start in stride(from:1,through:12,by:half ? 6:12) {
                var layout=TemplateLayout(id:entry.id,title:entry.title(locale:c.locale)+" \(c.year)",variant:half ? "half-years":"full-year",config:c)
                let cols=half ? 2:3,rows=half ? 3:4
                for i in 0..<(half ? 6:12) {
                    let w=608/Double(cols),h=780/Double(rows)
                    layout.smallCalendar(month:start+i,x:56+Double(i%cols)*w,y:112+Double(i/cols)*h,width:w-12,height:h-12)
                }
                try TemplateValidation.validate(layout.page);output.append(layout.page)
            }
            let holidays=try holidayBlocks(c)
            if !holidays.isEmpty {try append(holidays,"holiday-reference",c)}
        case "tool.urlaubsplaner":
            if c.variant != "summary" {
                let months=CalendarLayout.months(year:c.year,schoolYear:c.schoolYear),pair=c.variant=="paired-months"
                for start in stride(from:0,to:12,by:pair ? 2:1) {
                    var blocks:[TemplateBlock]=[]
                    var initial=c
                    for i in start..<min(12,start+(pair ? 2:1)) {
                        let m=months[i];var cc=c;cc.year=m.year;cc.month=m.month;cc.day=1
                        if i==start {initial=cc}
                        let days=try CalendarLayout.days(year:m.year,month:m.month)
                        blocks.append(.init(.markGrid,CalendarLayout.monthName(m.month,locale:c.locale)+" \(m.year)",items:(1...days).map(String.init),rows:c.people,rowLabels:(1...c.people).map{l("Person","Person")+" \($0)"}))
                        blocks += try holidayBlocks(cc,month:m.month)
                    }
                    try append(blocks,pair ? "paired-months":"month",initial)
                }
            }
            try append([.init(.table,l("Jahressumme","Annual totals"),items:[l("Person","Person"),l("Anspruch","Entitlement"),l("Übertrag","Carryover"),l("Genommen","Taken"),l("Rest","Remaining")],rows:c.people),.init(.fields,items:[l("Eigene Daten / Quelle / Stand","Your data / source / date")])],"summary",c)
        case "tool.zeiterfassung":
            if c.variant != "month" {try append([.init(.fields,items:de ? ["Name / Personal-Nr. / Abteilung","Urlaubsanspruch / Übertrag Urlaub","Übertrag Überstunden"]:["Name / employee ID / department","Vacation entitlement / carryover","Overtime carryover"]),.init(.table,l("Jahresübersicht","Annual summary"),items:de ? ["Monat","Soll","Ist","Differenz","Saldo","Urlaub","Krank","Sonstige Abwesenheit"]:["Month","Target","Actual","Difference","Balance","Vacation","Sick","Other absence"],rows:12,rowLabels:(1...12).map{CalendarLayout.monthName($0,locale:c.locale)},detail:"hours"),.init(.table,l("Umgewandelte Überstunden","Converted overtime"),items:de ? ["Datum","Stunden","Urlaub / Auszahlung"]:["Date","Hours","Leave / payout"],rows:3)],"year-summary",c)}
            if c.variant != "year-summary" || c.variant == nil {
                for month in c.variant == "month" ? [c.month]:Array(1...12) {
                    var cc=c;cc.month=month;cc.day=1;let n=try CalendarLayout.days(year:c.year,month:month)
                    try append([.init(.heading,CalendarLayout.monthName(month,locale:c.locale)),.init(.table,items:de ? ["Datum","Beginn","Ende","Pause","Ist"]:["Date","Start","End","Break","Actual"],rows:n,rowLabels:(1...n).map{String(format:"%02d.%02d.",$0,month)},detail:"clock"),.init(.table,items:de ? ["Datum","U/K/S","Notiz"]:["Date","U/K/S","Note"],rows:n,weights:[0.7,0.5,3.5],rowLabels:(1...n).map{String(format:"%02d.%02d.",$0,month)}),.init(.fields,items:de ? ["Summe Soll","Summe Ist","Saldo / Übertrag","Urlaub / Krank / Sonstige","Bestätigt am / Unterschrift"]:["Target total","Actual total","Balance / carryover","Vacation / sick / other","Confirmed on / signature"])]+(try holidayBlocks(cc,month:month)),"month",cc)
                }
            }
        case "tool.reisekosten":
            if c.variant == nil || c.variant == "summary" {
                let rows=max(12,c.count),columns=de ? ["Reise / Datum","Ziel / Anlass","Von / bis","Gesamt","Erstattet"]:["Trip / date","Destination / purpose","From / to","Total","Reimbursed"]
                let blocks=stride(from:0,to:rows,by:100).map { start in
                    let end=min(rows,start+100)
                    return TemplateBlock(.table,l("Reiseübersicht","Trip overview"),items:columns,rows:end-start,rowLabels:rows>100 ? ((start+1)...end).map{"#\($0)"}:[],detail:rows>100 ? "row-keys":"")
                }
                try append(blocks,"summary",c)
            }
            if c.variant == nil || c.variant == "trip" {
                for _ in 0..<c.count {
                    try Task.checkCancellation()
                    try append([.init(.fields,items:de ? ["Name / Projekt","Reiseziel / Zweck","Abreise Datum / Uhrzeit","Rückkehr Datum / Uhrzeit"]:["Name / project","Destination / purpose","Departure date / time","Return date / time"]),.init(.table,l("Fahrtkosten","Travel costs"),items:de ? ["Datum / Strecke","Verkehrsmittel / Kilometer","Betrag / Beleg"]:["Date / route","Transport / distance","Amount / receipt"],rows:6),.init(.table,l("Unterkunft & Verpflegung","Accommodation & meals"),items:de ? ["Datum","Unterkunft / Mahlzeit","Betrag / Beleg"]:["Date","Accommodation / meal","Amount / receipt"],rows:6),.init(.fields,items:de ? ["Land / Ort","Pauschbetrag 24 h (eigene Angabe)","An-/Abreisetag (eigene Angabe)","Reisetage × Betrag","Volle Tage × Betrag","Kürzung Frühstück / Mittag / Abend","Kfz km × eigener Satz","Übernachtung Nächte × eigener Satz","Nebenkosten / MwSt","Gesamt / Vorschuss / Erstattung","Unterschrift Reisende:r / Datum","Genehmigt / Datum"]:["Country / place","24 h allowance (your value)","Arrival / departure day (your value)","Travel days × rate","Full days × rate","Breakfast / lunch / dinner deductions","Car km × your rate","Nights × your rate","Incidentals / VAT","Total / advance / reimbursement","Traveller signature / date","Approved / date"])],"trip",c)
                }
            }
            if c.variant == nil || c.variant == "reference" {try append([.init(.text,l("Pauschalen: eigene geprüfte Angaben. Keine vorbelegten steuerlichen Beträge.","Allowances: your verified values. No prefilled tax amounts.")),.init(.table,items:de ? ["Land / Geltung","Betrag / Bedingung","Quelle / Stand"]:["Country / scope","Amount / condition","Source / date"],rows:8)],"reference",c)}
        default:throw NotebookError.notFound
        };return output
    }
    static func holidayBlocks(_ c:TemplateConfiguration,month:Int?=nil) throws -> [TemplateBlock] {
        var items=try CalendarLayout.holidays(year:c.year,jurisdiction:c.holidayJurisdiction).filter { month==nil || CalendarLayout.calendar.component(.month,from:$0.date)==month }.map { h in
            let d=CalendarLayout.calendar.dateComponents([.day,.month],from:h.date);return String(format:"%02d.%02d. ",d.day!,d.month!)+h.name
        }
        for v in c.importedVacations {
            let begin=try CalendarLayout.date(year:c.year,month:month ?? 1,day:1)
            let rangeEnd=CalendarLayout.calendar.date(byAdding:month == nil ? .year:.month,value:1,to:begin)!
            if v.end<begin || v.start>=rangeEnd {continue}
            let start=CalendarLayout.calendar.dateComponents([.year,.month,.day],from:v.start),end=CalendarLayout.calendar.dateComponents([.year,.month,.day],from:v.end)
            items.append("\(v.title): \(start.year!)-\(start.month!)-\(start.day!) – \(end.year!)-\(end.month!)-\(end.day!) · \(v.source)")
        }
        guard !items.isEmpty else {return []}
        return [.init(.heading,c.locale=="de" ? "Feiertage / importierte Ferien":"Holidays / imported vacations"),.init(.paragraphs,items:items),.init(.text,c.locale=="de" ? "Aktueller Regelstand als Projektion; örtliche Ausnahmen separat ergänzen. Ferien stammen ausschließlich aus eigenen Importen.":"Current rules projected to the selected year; add local exceptions separately. Vacations come only from your imports.")]
    }
}
extension TemplateLayout {
    mutating func smallCalendar(month:Int,x:Double,y:Double,width:Double,height:Double) {
        guard let cells=try? CalendarLayout.monthCells(year:config.year,month:month,mondayFirst:config.mondayFirst) else { return }
        text(CalendarLayout.monthName(month,locale:config.locale),x,y,width,28,16)
        let cw=width/7,rh=(height-52)/6
        let weekdays=config.locale=="de" ? ["M","D","M","D","F","S","S"]:["M","T","W","T","F","S","S"]
        for k in 0..<7 {text(weekdays[(k+(config.mondayFirst ? 0:6))%7],x+Double(k)*cw,y+28,cw,18,10)}
        for row in 0..<6 {for col in 0..<7 {
            let i=row*7+col,xx=x+Double(col)*cw,yy=y+48+Double(row)*rh
            shape(.rectangle,xx,yy,cw,rh)
            if i<cells.count,let d=cells[i] {text(String(d),xx+3,yy+2,cw-5,rh-2,10)}
        }}
    }
}
