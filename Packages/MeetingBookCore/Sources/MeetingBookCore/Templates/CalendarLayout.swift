import Foundation
public struct CalendarInterval: Codable, Sendable, Equatable {
    public let start: Date; public let end: Date; public let title: String; public let source: String
    public init(start: Date,end: Date,title: String,source: String) { self.start=start;self.end=end;self.title=title;self.source=source }
    public func validate() throws {
        guard start.timeIntervalSince1970.isFinite,end.timeIntervalSince1970.isFinite,
              start.timeIntervalSince1970 >= -2_208_988_800,end.timeIntervalSince1970 < 7_258_118_400,start<=end,end.timeIntervalSince(start)<=370*86400,
              !source.isEmpty,source.utf8.count<=2000,title.utf8.count<=500 else { throw NotebookError.invalidModel }
    }
}
public struct CalendarHoliday: Codable, Sendable, Equatable {
    public let date: Date; public let name: String
}
public enum CalendarLayout {
    public static let jurisdictions=["none","DE","BW","BY","BE","BB","HB","HH","HE","MV","NI","NW","RP","SL","SN","ST","SH","TH"]
    public static let holidayRuleSource = "Bundesbank 2026; BB Feiertagsgesetz §2; Berlin Feiertagsgesetz (17.06.2028). Checked 2026-10-28. Current-rule projections only; municipality-specific additions require user data."
    public static var calendar: Calendar {
        var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(secondsFromGMT:0)!;return c
    }
    public static func date(year: Int,month: Int,day: Int) throws -> Date {
        guard (1900...2199).contains(year),(1...12).contains(month),(1...31).contains(day),let d=calendar.date(from:.init(year:year,month:month,day:day)),calendar.component(.month,from:d)==month,calendar.component(.day,from:d)==day else { throw NotebookError.invalidModel };return d
    }
    public static func days(year: Int,month: Int) throws -> Int { calendar.range(of:.day,in:.month,for:try date(year:year,month:month,day:1))!.count }
    public static func monthCells(year: Int,month: Int,mondayFirst: Bool) throws -> [Int?] {
        let d=try date(year:year,month:month,day:1),weekday=calendar.component(.weekday,from:d)
        let offset=(weekday+(mondayFirst ? 5:6))%7
        return Array(repeating:nil,count:offset)+(1...(try days(year:year,month:month))).map { Optional($0) }
    }
    public static func isoWeek(year: Int,month: Int,day: Int) throws -> (year:Int,week:Int) {
        var c=calendar;c.firstWeekday=2;c.minimumDaysInFirstWeek=4;let d=try date(year:year,month:month,day:day)
        return (c.component(.yearForWeekOfYear,from:d),c.component(.weekOfYear,from:d))
    }
    public static func weekDates(year:Int,month:Int,day:Int,mondayFirst:Bool) throws -> [Date] {
        let selected=try date(year:year,month:month,day:day)
        let offset=(calendar.component(.weekday,from:selected)+(mondayFirst ? 5:6))%7
        let start=calendar.date(byAdding:.day,value:-offset,to:selected)!
        return (0..<7).map {calendar.date(byAdding:.day,value:$0,to:start)!}
    }
    public static func monthName(_ month:Int,locale:String)->String {
        let names=locale == "de" ? ["Januar","Februar","März","April","Mai","Juni","Juli","August","September","Oktober","November","Dezember"] : ["January","February","March","April","May","June","July","August","September","October","November","December"]
        return names[month-1]
    }
    public static func months(year:Int,schoolYear:Bool) -> [(year:Int,month:Int)] {
        (0..<12).map { i in let m=i+(schoolYear ? 7:0);return (year+m/12,m%12+1) }
    }
    public static func holidays(year: Int,jurisdiction:String) throws -> [CalendarHoliday] {
        guard jurisdictions.contains(jurisdiction),(1900...2199).contains(year) else { throw NotebookError.invalidModel }
        if jurisdiction == "none" { return [] }
        // Gregorian computus; dates are projections of the explicitly documented current law set.
        let a=year%19,b=year/100,c=year%100,d=b/4,e=b%4,f=(b+8)/25,g=(b-f+1)/3
        let h=(19*a+b-d-g+15)%30,i=c/4,k=c%4,l=(32+2*e+2*i-h-k)%7,m=(a+11*h+22*l)/451
        let easter=try date(year:year,month:(h+l-7*m+114)/31,day:(h+l-7*m+114)%31+1)
        var result:[CalendarHoliday]=[]
        func fixed(_ month:Int,_ day:Int,_ name:String) throws { result.append(.init(date:try date(year:year,month:month,day:day),name:name)) }
        func relative(_ offset:Int,_ name:String) { result.append(.init(date:calendar.date(byAdding:.day,value:offset,to:easter)!,name:name)) }
        try fixed(1,1,"Neujahr");relative(-2,"Karfreitag");relative(1,"Ostermontag");try fixed(5,1,"Tag der Arbeit");relative(39,"Christi Himmelfahrt");relative(50,"Pfingstmontag");try fixed(10,3,"Tag der Deutschen Einheit");try fixed(12,25,"1. Weihnachtstag");try fixed(12,26,"2. Weihnachtstag")
        if ["BW","BY","ST"].contains(jurisdiction) { try fixed(1,6,"Heilige Drei Könige") }
        if ["BE","MV"].contains(jurisdiction) { try fixed(3,8,"Internationaler Frauentag") }
        if ["BW","BY","HE","NW","RP","SL"].contains(jurisdiction) { relative(60,"Fronleichnam") }
        if jurisdiction == "SL" { try fixed(8,15,"Mariä Himmelfahrt") }
        if jurisdiction == "TH" { try fixed(9,20,"Weltkindertag") }
        if ["BB","HB","HH","MV","NI","SN","ST","SH","TH"].contains(jurisdiction) { try fixed(10,31,"Reformationstag") }
        if ["BW","BY","NW","RP","SL"].contains(jurisdiction) { try fixed(11,1,"Allerheiligen") }
        if jurisdiction == "BB" { relative(0,"Ostersonntag");relative(49,"Pfingstsonntag") }
        if jurisdiction == "SN" { let nov23=try date(year:year,month:11,day:23);let delta=(calendar.component(.weekday,from:nov23)-4+7)%7;result.append(.init(date:calendar.date(byAdding:.day,value:-(delta == 0 ? 7:delta),to:nov23)!,name:"Buß- und Bettag")) }
        if jurisdiction == "BE",year == 2025 { try fixed(5,8,"Tag der Befreiung (einmalig)") }
        if jurisdiction == "BE",year == 2028 { try fixed(6,17,"Gedenken an den Volksaufstand (einmalig)") }
        return result.sorted { $0.date<$1.date }
    }
}
