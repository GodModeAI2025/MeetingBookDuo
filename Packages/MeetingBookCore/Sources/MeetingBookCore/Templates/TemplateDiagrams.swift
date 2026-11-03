import Foundation
extension TemplateLayout {
    mutating func diagram(_ b: TemplateBlock) throws {
        switch b.type {
        case .checks:
            for label in b.items.isEmpty ? [b.label] : b.items {
                ensure(56);shape(.rectangle,left,y+5,18,18);text(label,left+30,y,width-30,48);y += 56
            }
        case .weekdays, .linescale:
            ensure(98);text(b.label,left,y,width,28);y += 30
            let labels=b.items
            let cell=width/Double(max(1,labels.count))
            if b.type == .linescale {line(left+cell/2,y+10,left+width-cell/2,y+10)}
            for (k,label) in labels.enumerated() {
                let x=left+Double(k)*cell
                shape(.ellipse,x+cell/2-8,y+2,16,16);text(label,x+2,y+26,cell-4,42,13)
            };y += 72
        case .scale, .rating_list:
            let labels=b.items.isEmpty ? [b.label] : b.items
            for label in labels {
                ensure(76); text(label,left,y,width,28);y += 30
                let n=max(2,b.rows)
                for k in 0..<n {
                    let x=left+Double(k)*min(50,width/Double(n))
                    shape(.ellipse,x,y,20,20)
                    text(String(k+(b.detail == "zero" ? 0:1)),x+24,y,24,24,12)
                };y += 42
            }
        case .faces:
            ensure(84)
            for i in 0..<5 {
                let x=left+30+Double(i)*110
                shape(.ellipse,x,y,50,50)
                shape(.ellipse,x+13,y+13,3,3,filled:true);shape(.ellipse,x+33,y+13,3,3,filled:true)
                let curve=Double(i-2)*4
                path((0...10).map { t in let u=Double(t)/10;return .init(x+12+26*u,y+34+curve*4*u*(1-u)) })
            };y += 80
        case .battery:
            ensure(70);text(b.label,left,y,220,28)
            shape(.rectangle,left+240,y,240,42);shape(.rectangle,left+480,y+12,10,18)
            for i in 1..<5 { line(left+240+Double(i)*48,y,left+240+Double(i)*48,y+42) };y += 68
        case .wheel:
            ensure(450);let cx=360.0,cy=y+200,r=150.0
            for k in 1...10 { let rr=r*Double(k)/10;shape(.ellipse,cx-rr,cy-rr,rr*2,rr*2) }
            let n=max(3,b.items.count)
            for k in 0..<n {
                let a=Double(k)*2*Double.pi/Double(n)-Double.pi/2
                line(cx,cy,cx+cos(a)*r,cy+sin(a)*r)
                let mid=a+Double.pi/Double(n)
                if k < b.items.count { text(b.items[k],cx+cos(mid)*215-60,cy+sin(mid)*180-20,120,52,13) }
            };y += 440
        case .breath:
            ensure(360);let x=228.0,t=y+56,s=264.0
            shape(.rectangle,x,t,s,s)
            let labels=b.items.count == 4 ? b.items : (config.locale == "de" ? ["Einatmen · 4","Halten · 4","Ausatmen · 4","Halten · 4"]:["Inhale · 4","Hold · 4","Exhale · 4","Hold · 4"])
            text(labels[0],x,t-36,s,28);text(labels[1],x+s+8,t+100,108,56,14);text(labels[2],x,t+s+8,s,28);text(labels[3],left,t+100,156,56,14)
            text("4 → 4 → 4 → 4",x+26,t+112,s-52,40,23);y += 370
        case .body:
            ensure(570);let cx=360.0,top=y,u=4.5
            shape(.ellipse,cx-30,top,60,60)
            // Own geometric outline: head, shoulders, torso, arms and articulated legs.
            let torso:[(Double,Double)]=[(-6,14),(-16,19),(-20,35),(-14,55),(-16,65),(16,65),(14,55),(20,35),(16,19),(6,14)]
            path(torso.map { .init(cx+$0.0*u,top+$0.1*u) })
            for sign in [-1.0,1.0] {
                path([(16.0,19.0),(25,25),(31,62),(26,66),(21,39)].map { .init(cx+sign*$0.0*u,top+$0.1*u) })
                path([(16.0,65.0),(14,91),(13,108),(4,108),(3,89),(2,66)].map { .init(cx+sign*$0.0*u,top+$0.1*u) })
                line(cx+sign*4*u,top+88*u,cx+sign*14*u,top+88*u)
            }
            if b.detail == "back" { line(cx,top+18*u,cx,top+65*u) }
            text(b.label,left,top+510,width,30,18);y += 558
        case .mindmap:
            ensure(630);let cx=360.0,cy=y+270
            shape(.ellipse,cx-100,cy-44,200,88)
            for k in 0..<6 { let a=Double(k)*Double.pi/3;line(cx+cos(a)*100,cy+sin(a)*44,cx+cos(a)*265,cy+sin(a)*230) }
            region(x:cx-80,top:cy-25,w:160,lines:1,ruled:false);y += 620
        case .markGrid:
            guard !b.items.isEmpty,b.rows>0 else {throw NotebookError.invalidModel}
            let cols=b.items.count,rows=b.rows
            let h=min(700,max(200,Double(rows)*22+60));ensure(h+20)
            text(b.label,left,y,width,32,18);y += 36
            let nameW=b.rowLabels.isEmpty ? 40.0 : 140.0
            let headerH=Double(b.items.map(\.count).max() ?? 0)>8 ? 48.0:24.0
            let cw=(width-nameW)/Double(cols),rh=(h-36-headerH)/Double(rows)
            for c in 0..<cols { text(b.items[c],left+nameW+Double(c)*cw,y,cw,headerH,10) }
            y += headerH
            for r in 0..<rows {
                text(r < b.rowLabels.count ? b.rowLabels[r] : String(r+1),left,y+Double(r)*rh,nameW-4,rh,12)
                for c in 0..<cols {
                    let xx=left+nameW+Double(c)*cw,yy=y+Double(r)*rh
                    shape(.rectangle,xx,yy,cw,rh)
                    if b.detail == "numbered" {text(String(r*cols+c+1),xx+4,yy+4,cw-8,22,12)}
                }
            };y += Double(rows)*rh+20
        case .chart:
            ensure(450);text(b.label,left,y,width,40,18);y += 44
            let chartY=y,cw=(width-60)/Double(max(1,b.rows)),h=300.0
            for k in 0...12 {
                let yy=chartY+Double(k)*h/12;line(left+52,yy,left+width,yy)
                if k%2==0 {text(k/2 < b.items.count ? b.items[k/2] : String(6-k/2),left,yy-8,48,22,12)}
            }
            for k in 0...b.rows {
                let x=left+52+Double(k)*cw;line(x,chartY,x,chartY+h)
                if k < b.rows {text(k < b.rowLabels.count ? b.rowLabels[k]:String(k+1),x,chartY+h+6,cw,40,10)}
            };y += h+60
        case .cornell:
            ensure(600)
            let labels=b.items.count==3 ? b.items:["Cues","Notes","Summary"]
            text(labels[0],left,y,170,28);text(labels[1],left+200,y,width-200,28)
            let n=max(1,Int((360-config.inkAscent-config.inkDescent-4)/config.lineStep)+1)
            region(x:left,top:y+32,w:174,lines:n,label:labels[0]);region(x:left+200,top:y+32,w:width-200,lines:n,label:labels[1])
            line(left+187,y,left+187,y+400);line(left,y+414,left+width,y+414)
            text(labels[2],left,y+428,width,28);region(x:left,top:y+460,w:width,lines:3,label:labels[2])
            y += 600
        case .quadrants:
            ensure(730)
            let labels=b.items.count==4 ? b.items:["1","2","3","4"]
            let w=(width-20)/2,h=350.0
            for k in 0..<4 {
                let x=left+Double(k%2)*(w+20),top=y+Double(k/2)*(h+20)
                shape(.rectangle,x,top,w,h);text(labels[k],x+10,top+10,w-20,52,16)
                let n=max(1,Int((h-80-config.inkAscent-config.inkDescent-4)/config.lineStep)+1)
                region(x:x+32,top:top+66,w:w-44,lines:n,label:labels[k])
                for row in 0..<n {shape(.rectangle,x+10,top+66+config.inkAscent+Double(row)*config.lineStep-12,14,14)}
            };y += 730
        case .calendar: calendarDiagram(b)
        default: break
        }
    }
    mutating func calendarDiagram(_ b: TemplateBlock) {
        let month=b.rows
        guard let cells=try? CalendarLayout.monthCells(year:config.year,month:month,mondayFirst:config.mondayFirst) else { return }
        ensure(350);text(CalendarLayout.monthName(month,locale:config.locale)+" \(config.year)",left,y,width,36,20);y += 40
        let labels=config.locale == "de" ? ["Mo","Di","Mi","Do","Fr","Sa","So"]:["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
        let ordered=config.mondayFirst ? labels:[labels[6]]+Array(labels.prefix(6));let cw=width/7
        for k in 0..<7 { text(ordered[k],left+Double(k)*cw,y,cw,26,14) };y += 28
        for row in 0..<6 { for col in 0..<7 {
            let index=row*7+col,x=left+Double(col)*cw,yy=y+Double(row)*42
            shape(.rectangle,x,yy,cw,42)
            if index < cells.count,let d=cells[index] { text(String(d),x+8,yy+10,cw-16,24,16) }
        } };y += 270
    }
}
