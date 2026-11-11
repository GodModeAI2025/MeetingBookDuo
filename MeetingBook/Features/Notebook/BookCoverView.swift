import SwiftUI

struct CoverBandGeometry {
    let anchorX: CGFloat
    let contactX: CGFloat
    let contactY: CGFloat
    let pull: CGFloat
    let bandWidth: CGFloat
    let opens: Bool
    init(size:CGSize,translation:CGFloat,contact:CGPoint) {
        let width=size.width.isFinite ? min(2000,max(0,size.width)) : 0
        let height=size.height.isFinite ? min(4000,max(0,size.height)) : 0
        anchorX=width*0.86
        let raw=translation.isFinite ? max(0,translation) : 0
        let limit=max(1,width*0.38)
        pull=limit*(1-exp(-raw/limit))
        contactX=anchorX+pull
        self.contactY=contact.y.isFinite ? min(height*0.85,max(height*0.15,contact.y)) : height/2
        bandWidth=max(9,18-pull/max(1,width)*20)
        // Release follows the finger, not the resisted band, at an edge reachable on a full-screen cover.
        opens=size.width>44 && size.width<=2000 && size.height>44 && size.height<=4000
            && translation.isFinite && contact.x.isFinite && contact.y.isFinite
            && raw>min(24,width*0.06) && contact.x>=width-min(24,width*0.04)
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
        let g=CoverBandGeometry(size:rect.size,translation:translation,contact:CGPoint(x:0,y:contactY))
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
    var fillsViewport=false
    var showsTitle=true
    @Environment(\.paperAppearance) private var paper
    var body: some View {
        GeometryReader { geometry in
            let size=geometry.size
            ZStack(alignment:.leading) {
                if !fillsViewport {
                    RoundedRectangle(cornerRadius:16).fill(paper.color).padding(.leading,9).offset(x:7,y:4)
                    ForEach(0..<3) {i in RoundedRectangle(cornerRadius:14).stroke(.black.opacity(0.09),lineWidth:0.5).padding(.leading,12).offset(x:CGFloat(i+3),y:CGFloat(i+2))}
                }
                RoundedRectangle(cornerRadius:fillsViewport ? 0 : 16).fill(configuration.coverColor.materialColor)
                if let bytes=configuration.imageData,let image=UIImage(data:bytes) {
                    let photo=CoverPhotoGeometry(image:image.size,viewport:size)
                    Image(uiImage:image).resizable().frame(width:photo.renderedSize.width,height:photo.renderedSize.height)
                        .offset(x:CGFloat(configuration.cropX)*photo.overflow.width/2,y:CGFloat(configuration.cropY)*photo.overflow.height/2)
                        .frame(width:size.width,height:size.height).clipped().clipShape(RoundedRectangle(cornerRadius:fillsViewport ? 0 : 16))
                }
                RoundedRectangle(cornerRadius:fillsViewport ? 0 : 16).fill(LinearGradient(colors:[.white.opacity(0.1),.clear,.black.opacity(0.18)],startPoint:.topLeading,endPoint:.bottomTrailing))
                Rectangle().fill(LinearGradient(colors:[.black.opacity(0.35),.white.opacity(0.08),.clear],startPoint:.leading,endPoint:.trailing)).frame(width:24).padding(.leading,10)
                if showsTitle {
                    BookCoverTitle(configuration:configuration)
                        .frame(maxHeight:size.height*0.62,alignment:.top)
                        .padding(.leading,32).padding(.trailing,size.width*0.24)
                        .frame(maxHeight:.infinity,alignment:.top).padding(.top,size.height*0.17)
                }
                if !fillsViewport {RoundedRectangle(cornerRadius:16).stroke(.white.opacity(0.15),lineWidth:1)}
                if showsBand {ElasticBand(translation:0,contactY:size.height/2).stroke(configuration.bandColor.materialColor,lineWidth:18).shadow(color:.black.opacity(0.4),radius:2,x:3,y:2)}
            }.shadow(color:.black.opacity(fillsViewport ? 0 : 0.2),radius:14,x:3,y:8)
        }
    }
}

private struct BookCoverTitle: View {
    let configuration: BookCoverConfiguration
    var lineLimit: Int? = 4
    @Environment(\.coverTitleFont) private var titleFont
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(configuration.displayTitle).font(titleFont).lineLimit(lineLimit).minimumScaleFactor(0.65)
                .accessibilityIdentifier("cover.title")
            Rectangle().fill(.white.opacity(0.5)).frame(width:36,height:1)
        }.foregroundStyle(.white).padding(20)
            .background(.black.opacity(configuration.imageData == nil ? 0.16 : 0.62),in:RoundedRectangle(cornerRadius:6))
    }
}

struct BookCoverView: View {
    let configuration: BookCoverConfiguration
    let open: ()->Void
    let customize: ()->Void
    @Environment(\.personalSymbols) private var symbols
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("haptics") private var haptics=false
    @GestureState private var drag: CGSize = .zero
    @GestureState private var contact: CGPoint? = nil
    @State private var opened=false
    @State private var releasing=false
    @State private var releaseTask: Task<Void,Never>?
    @Environment(\.coverPresentation) private var presentation
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        GeometryReader { safeArea in
            ZStack {
                GeometryReader { geometry in
                    let size=geometry.size
                    let point=contact ?? CGPoint(x:size.width*0.86,y:size.height/2)
                    let g=CoverBandGeometry(size:size,translation:drag.width,contact:point)
                    ZStack {
                        BookCoverArtwork(configuration:configuration,showsBand:false,fillsViewport:true,showsTitle:false)
                            .overlay(alignment:.top) {
                                LinearGradient(stops:[.init(color:.black.opacity(0.68),location:0),.init(color:.black.opacity(0.68),location:0.7),.init(color:.clear,location:1)],startPoint:.top,endPoint:.bottom)
                                    .frame(height:100).allowsHitTesting(false)
                            }
                        ElasticBand(translation:releasing ? size.width*0.7 : drag.width,contactY:point.y)
                            .stroke(configuration.bandColor.materialColor,style:StrokeStyle(lineWidth:g.bandWidth,lineCap:.round))
                            .shadow(color:.black.opacity(0.45),radius:2+g.pull/20,x:3+g.pull/15,y:3)
                            .overlay {ElasticBand(translation:releasing ? size.width*0.7 : drag.width,contactY:point.y).stroke(.white.opacity(0.16),lineWidth:1).offset(x:-5)}
                            .offset(x:releasing ? size.width*0.16 : 0).opacity(releasing ? 0 : 1)
                            .animation(reduceMotion ? nil : .easeOut(duration:0.16),value:releasing)
                            .allowsHitTesting(false)
                        Color.clear.frame(width:64,height:size.height).contentShape(Rectangle()).position(x:g.anchorX,y:size.height/2)
                            .gesture(DragGesture(minimumDistance:3,coordinateSpace:.named("cover"))
                                .updating($drag) {value,state,_ in state=value.translation}
                                .updating($contact) {value,state,_ in state=value.location}
                                .onEnded {value in
                                    if CoverBandGeometry(size:size,translation:value.translation.width,contact:value.location).opens {performOpen()}
                                })
                            .accessibilityLabel("Elastic band")
                            .accessibilityHint("Pull the band to the right edge to open the book.")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {performOpen()}
                            .accessibilityAction(named:Text("Open book"),performOpen)
                            .accessibilityIdentifier("cover.band")
                    }.frame(width:size.width,height:size.height).clipped().coordinateSpace(name:"cover")
                        .animation(drag == .zero ? (reduceMotion ? nil : .spring(response:0.42,dampingFraction:0.7)) : nil,value:drag)
                        .onChange(of:size) {_,_ in cancelRelease()}
                }.ignoresSafeArea(.container)
                VStack(alignment:.leading,spacing:16) {
                    ScrollView {
                        BookCoverTitle(configuration:configuration,lineLimit:nil)
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .padding(.top,safeArea.size.height*0.12)
                    }.frame(width:max(0,safeArea.size.width-48-safeArea.size.width*0.18),alignment:.leading)
                        .scrollBounceBehavior(.basedOnSize)
                    ViewThatFits(in:.horizontal) {
                        HStack(spacing:12) {commands}.fixedSize(horizontal:true,vertical:false)
                        VStack(alignment:.leading,spacing:8) {commands}
                    }.fixedSize(horizontal:false,vertical:true)
                }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            }
        }
        .onChange(of:scenePhase) {_,phase in if phase != .active {cancelRelease()}}
        .onChange(of:presentation?.lastHinge) {_,hinge in if hinge == .closed {cancelRelease()}}
        .onDisappear {cancelRelease()}
        .ignoresSafeArea(.keyboard)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection,trigger:opened) {_,_ in haptics}
    }
    @ViewBuilder private var commands: some View {
        Button(action:performOpen) {Label {Text("Open book")} icon: {AppSymbol.openBook.image(in:symbols)}.padding(.horizontal,12).frame(minWidth:44,minHeight:44).contentShape(Rectangle())}
            .buttonStyle(.plain).foregroundStyle(.white).background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:10))
            .keyboardShortcut(.return,modifiers:[]).accessibilityIdentifier("cover.open")
        Button(action:customize) {Label {Text("Design cover")} icon: {AppSymbol.designCover.image(in:symbols)}.padding(.horizontal,12).frame(minWidth:44,minHeight:44).contentShape(Rectangle())}
            .buttonStyle(.plain).foregroundStyle(.white).background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:10))
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
