import SwiftUI

struct CoverBandGeometry {
    let anchorX: CGFloat
    let contactX: CGFloat
    let contactY: CGFloat
    let pull: CGFloat
    let bandWidth: CGFloat
    let opens: Bool
    init(size:CGSize,translation:CGFloat,contactY:CGFloat) {
        let width=size.width.isFinite ? min(2000,max(0,size.width)) : 0
        let height=size.height.isFinite ? min(4000,max(0,size.height)) : 0
        anchorX=width*0.86
        let raw=translation.isFinite ? max(0,translation) : 0
        let limit=max(1,width*0.38)
        pull=limit*(1-exp(-raw/limit))
        contactX=anchorX+pull
        self.contactY=contactY.isFinite ? min(height*0.85,max(height*0.15,contactY)) : height/2
        bandWidth=max(9,18-pull/max(1,width)*20)
        opens=width>44 && height>44 && contactX>=width+4
    }
}

struct CoverPhotoGeometry {
    let renderedSize: CGSize
    let overflow: CGSize
    init(image:CGSize,viewport:CGSize) {
        guard image.width>0,image.height>0,viewport.width>0,viewport.height>0,
              [image.width,image.height,viewport.width,viewport.height].allSatisfy({$0.isFinite}) else {
            renderedSize = .zero;overflow = .zero;return
        }
        let scale=max(viewport.width/image.width,viewport.height/image.height)
        renderedSize=CGSize(width:image.width*scale,height:image.height*scale)
        overflow=CGSize(width:max(0,renderedSize.width-viewport.width),height:max(0,renderedSize.height-viewport.height))
    }
    func crop(origin:CGPoint,translation:CGSize) -> CGPoint {
        func value(_ origin:CGFloat,_ movement:CGFloat,_ overflow:CGFloat) -> CGFloat {
            guard overflow>0,movement.isFinite,origin.isFinite else {return 0}
            return min(1,max(-1,origin+2*movement/overflow))
        }
        return CGPoint(x:value(origin.x,translation.width,overflow.width),y:value(origin.y,translation.height,overflow.height))
    }
}

@Animatable private struct ElasticBand: Shape {
    var translation: CGFloat
    var contactY: CGFloat
    func path(in rect:CGRect) -> Path {
        let g=CoverBandGeometry(size:rect.size,translation:translation,contactY:contactY)
        var path=Path()
        path.move(to:CGPoint(x:g.anchorX,y:-12))
        path.addCurve(to:CGPoint(x:g.contactX,y:g.contactY),control1:CGPoint(x:g.anchorX,y:g.contactY*0.55),control2:CGPoint(x:g.contactX,y:g.contactY-35))
        path.addCurve(to:CGPoint(x:g.anchorX,y:rect.height+12),control1:CGPoint(x:g.contactX,y:g.contactY+35),control2:CGPoint(x:g.anchorX,y:g.contactY+(rect.height-g.contactY)*0.45))
        return path
    }
}

extension BookCoverColor {
    var materialColor: Color {
        switch self {
        case .graphite:Color(red:0.16,green:0.18,blue:0.19)
        case .forest:Color(red:0.16,green:0.29,blue:0.24)
        case .bordeaux:Color(red:0.37,green:0.16,blue:0.21)
        case .linen:Color(red:0.75,green:0.69,blue:0.56)
        }
    }
}

struct BookCoverArtwork: View {
    let configuration: BookCoverConfiguration
    var showsBand=true
    @Environment(\.coverTitleFont) private var titleFont
    @Environment(\.paperAppearance) private var paper
    var body: some View {
        GeometryReader { geometry in
            let size=geometry.size
            ZStack(alignment:.leading) {
                RoundedRectangle(cornerRadius:16).fill(paper.color).padding(.leading,9).offset(x:7,y:4)
                ForEach(0..<3) {i in RoundedRectangle(cornerRadius:14).stroke(.black.opacity(0.09),lineWidth:0.5).padding(.leading,12).offset(x:CGFloat(i+3),y:CGFloat(i+2))}
                RoundedRectangle(cornerRadius:16).fill(configuration.coverColor.materialColor)
                if let bytes=configuration.imageData,let image=UIImage(data:bytes) {
                    let photo=CoverPhotoGeometry(image:image.size,viewport:size)
                    Image(uiImage:image).resizable().frame(width:photo.renderedSize.width,height:photo.renderedSize.height)
                        .offset(x:CGFloat(configuration.cropX)*photo.overflow.width/2,y:CGFloat(configuration.cropY)*photo.overflow.height/2)
                        .frame(width:size.width,height:size.height).clipped().clipShape(RoundedRectangle(cornerRadius:16))
                }
                RoundedRectangle(cornerRadius:16).fill(LinearGradient(colors:[.white.opacity(0.1),.clear,.black.opacity(0.18)],startPoint:.topLeading,endPoint:.bottomTrailing))
                Rectangle().fill(LinearGradient(colors:[.black.opacity(0.35),.white.opacity(0.08),.clear],startPoint:.leading,endPoint:.trailing)).frame(width:24).padding(.leading,10)
                VStack(alignment:.leading,spacing:10) {
                    Text(configuration.displayTitle).font(titleFont).lineLimit(4).minimumScaleFactor(0.65)
                        .accessibilityIdentifier("cover.title")
                    Rectangle().fill(.white.opacity(0.5)).frame(width:36,height:1)
                }.foregroundStyle(.white).padding(20)
                    .background(.black.opacity(configuration.imageData == nil ? 0.16 : 0.62),in:RoundedRectangle(cornerRadius:6))
                    .frame(maxHeight:size.height*0.62,alignment:.top)
                    .padding(.leading,32).padding(.trailing,size.width*0.24).frame(maxHeight:.infinity,alignment:.top).padding(.top,size.height*0.17)
                RoundedRectangle(cornerRadius:16).stroke(.white.opacity(0.15),lineWidth:1)
                if showsBand {ElasticBand(translation:0,contactY:size.height/2).stroke(configuration.bandColor.materialColor,lineWidth:18).shadow(color:.black.opacity(0.4),radius:2,x:3,y:2)}
            }.shadow(color:.black.opacity(0.2),radius:14,x:3,y:8)
        }
    }
}

struct BookCoverView: View {
    let configuration: BookCoverConfiguration
    let open: ()->Void
    let customize: ()->Void
    @Environment(\.paperAppearance) private var paper
    @Environment(\.personalSymbols) private var symbols
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("haptics") private var haptics=false
    @GestureState private var drag: CGSize = .zero
    @GestureState private var contact: CGFloat? = nil
    @State private var opened=false
    @State private var releasing=false
    @State private var releaseTask: Task<Void,Never>?
    @Environment(\.coverPresentation) private var presentation
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing:20) {
            GeometryReader { geometry in
                let width=min(600,max(120,geometry.size.width-64))
                let height=max(80,min(760,geometry.size.height-24))
                ZStack {
                    BookCoverArtwork(configuration:configuration,showsBand:false)
                    let g=CoverBandGeometry(size:CGSize(width:width,height:height),translation:drag.width,contactY:contact ?? height/2)
                    ElasticBand(translation:releasing ? width*0.7 : drag.width,contactY:contact ?? height/2)
                        .stroke(configuration.bandColor.materialColor,style:StrokeStyle(lineWidth:g.bandWidth,lineCap:.round))
                        .shadow(color:.black.opacity(0.45),radius:2+g.pull/20,x:3+g.pull/15,y:3)
                        .overlay {ElasticBand(translation:releasing ? width*0.7 : drag.width,contactY:contact ?? height/2).stroke(.white.opacity(0.16),lineWidth:1).offset(x:-5)}
                        .offset(x:releasing ? width*0.16 : 0).opacity(releasing ? 0 : 1)
                        .animation(.easeOut(duration:0.16),value:releasing)
                        .allowsHitTesting(false)
                    Color.clear.frame(width:64,height:height).contentShape(Rectangle()).position(x:g.anchorX,y:height/2)
                        .gesture(DragGesture(minimumDistance:3,coordinateSpace:.named("cover"))
                            .updating($drag) {value,state,_ in state=value.translation}
                            .updating($contact) {value,state,_ in state=value.location.y}
                            .onEnded {value in
                                if CoverBandGeometry(size:CGSize(width:width,height:height),translation:value.translation.width,contactY:value.location.y).opens {performOpen()}
                            })
                        .accessibilityLabel("Elastic band")
                        .accessibilityHint("Pull the band beyond the right edge to open the book.")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {performOpen()}
                        .accessibilityAction(named:Text("Open book"),performOpen)
                        .accessibilityIdentifier("cover.band")
                }.frame(width:width,height:height).coordinateSpace(name:"cover")
                    .animation(drag == .zero ? (reduceMotion ? .easeOut(duration:0.12) : .spring(response:0.42,dampingFraction:0.7)) : nil,value:drag)
                    .position(x:geometry.size.width/2,y:geometry.size.height/2)
                    .onChange(of:geometry.size) {_,_ in cancelRelease()}
            }
            ViewThatFits(in:.horizontal) {
                HStack(spacing:20) {commands}.fixedSize(horizontal:true,vertical:false)
                VStack(spacing:4) {commands}
            }.fixedSize(horizontal:false,vertical:true).padding(.horizontal,24)
        }.padding(.vertical,24).frame(maxWidth:.infinity,maxHeight:.infinity)
        .onChange(of:scenePhase) {_,phase in if phase != .active {cancelRelease()}}
        .onChange(of:presentation?.lastHinge) {_,hinge in if hinge == .closed {cancelRelease()}}
        .onDisappear {cancelRelease()}
        .background(paper.color.ignoresSafeArea()).ignoresSafeArea(.keyboard)
        .sensoryFeedback(.selection,trigger:opened) {_,_ in haptics}
    }
    @ViewBuilder private var commands: some View {
        Button(action:performOpen) {Label {Text("Open book")} icon: {AppSymbol.openBook.image(in:symbols)}.frame(minWidth:44,minHeight:44).contentShape(Rectangle())}
            .keyboardShortcut(.return,modifiers:[]).accessibilityIdentifier("cover.open")
        Button(action:customize) {Label {Text("Design cover")} icon: {AppSymbol.designCover.image(in:symbols)}.frame(minWidth:44,minHeight:44).contentShape(Rectangle())}
            .accessibilityIdentifier("cover.customize")
    }
    private func performOpen() {
        guard !releasing else {return}
        if reduceMotion {opened=true;open();return}
        releasing=true
        releaseTask=Task { @MainActor in
            do {try await Task.sleep(for:.milliseconds(160))} catch {return}
            guard !Task.isCancelled else {return}
            opened=true;open()
        }
    }
    private func cancelRelease() {releaseTask?.cancel();releaseTask=nil;releasing=false}
}
