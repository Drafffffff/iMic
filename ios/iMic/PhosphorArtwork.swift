import SwiftUI

/// Value-only artwork. It contains no UIKit views, input handlers, or display clock.
/// It is rasterized only when UI state/layout changes, never on waveform ticks.
struct PhosphorArtworkState: Equatable {
    var size: CGSize
    var content: CGRect
    var torus: CGRect
    var connection: String
    var connectionColor: Color
    var channel: String
    var status: String
    var statusLine: String
    var statusCell: CGFloat
    var statusColor: Color
    var barLabel: String
    var barCell: CGFloat
    var barFill: Color
    var barText: Color
    var canRecord: Bool
    var listening: Bool
    var elapsed: String
    var hasResult: Bool
    var notice: String?
    var noticeColor: Color

    var statusBounds: CGRect {
        CGRect(x:24,y:content.minY+content.height*0.145+43,width:max(1,size.width-48),height:34)
    }
    var actionBounds: CGRect {
        CGRect(x:24,y:content.maxY-100,width:max(1,size.width-48),height:68)
    }
    /// Regions whose pixels depend on fields that changed, in points; nil redraws everything.
    /// A full-screen raster costs tens of ms on the main thread (213ms cold in the simulator);
    /// most state changes only touch the status block or the hold bar.
    func dirtyRegions(from old:Self)->[CGRect]?{
        guard size==old.size,content==old.content,torus==old.torus,channel==old.channel else{return nil}
        var regions:[CGRect]=[]
        if connection != old.connection || connectionColor != old.connectionColor{
            regions.append(CGRect(x:0,y:content.minY,width:size.width,height:100))
        }
        if status != old.status || statusLine != old.statusLine || statusCell != old.statusCell
            || statusColor != old.statusColor{
            let top=content.minY+content.height*0.145+20
            regions.append(CGRect(x:0,y:top-8,width:size.width,height:132))
        }
        if barLabel != old.barLabel || barCell != old.barCell || barFill != old.barFill || barText != old.barText
            || canRecord != old.canRecord || listening != old.listening || hasResult != old.hasResult
            || notice != old.notice || noticeColor != old.noticeColor{
            regions.append(CGRect(x:0,y:content.maxY-126,width:size.width,height:124))
        }
        return regions
    }

    func sameRaster(as other:Self)->Bool{
        var a=self,b=other;a.elapsed="";b.elapsed="";return a==b
    }
}

struct PhosphorClearArtwork:View{
    var width:CGFloat
    var body:some View{
        HStack(spacing:8){
            Image(systemName:"trash").font(.system(size:15,weight:.semibold))
            PixelText(text:"CLEAR",cell:1.5,color:Theme.orange,tracking:1)
            Spacer()
            Text("拉入清空输入框").font(.system(size:11,weight:.medium))
        }.foregroundStyle(Theme.orange).padding(.horizontal,24)
            .padding(.top,46).padding(.bottom,12).frame(width:width,height:84)
    }
}

struct PhosphorArtwork: View {
    let state: PhosphorArtworkState
    @Environment(\.displayScale) private var displayScale
    private var width:CGFloat{max(1,state.size.width-48)}

    var body: some View {
        ZStack(alignment:.topLeading){
            Theme.ink
            grid
            header.frame(width:width,height:62,alignment:.top)
                .position(x:state.size.width/2,y:state.content.minY+45)
            divider.frame(width:width,height:10)
                .position(x:state.size.width/2,y:state.content.minY+87)
            status.frame(width:width,height:108,alignment:.top)
                .position(x:state.size.width/2,y:state.content.minY+state.content.height*0.145+74)
            hud
            VStack(spacing:0){
                HoldBarRail(notice:state.notice,noticeColor:state.noticeColor)
                bar.padding(.top,10)
                HStack{
                    Spacer()
                    if state.hasResult{
                        Text("查看结果  ›").modifier(InstrumentHint()).frame(width:98,height:14,alignment:.trailing)
                    }else{HUDLabel(text:"PCM / 16K").frame(width:98,height:14,alignment:.trailing)}
                }.frame(height:14).padding(.top,12)
            }.frame(width:width,height:116,alignment:.top)
                .position(x:state.size.width/2,y:state.content.maxY-64)
        }.frame(width:state.size.width,height:state.size.height)
            .environment(\.colorScheme,.dark)
    }

    private var grid:some View{
        Canvas{context,size in
            var path=Path()
            for x in stride(from:0.0,through:size.width,by:26){path.move(to:CGPoint(x:x,y:0));path.addLine(to:CGPoint(x:x,y:size.height))}
            for y in stride(from:0.0,through:size.height,by:26){path.move(to:CGPoint(x:0,y:y));path.addLine(to:CGPoint(x:size.width,y:y))}
            context.stroke(path,with:.color(.white.opacity(0.065)),lineWidth:1/max(1,displayScale))
        }.frame(width:state.size.width,height:state.size.height)
    }
    private var header:some View{
        HStack(alignment:.top,spacing:0){
            VStack(alignment:.leading,spacing:8){
                Image("Wordmark").renderingMode(.original).resizable().scaledToFit()
                    .frame(width:HoldBarLayout.wordmark.width,height:HoldBarLayout.wordmark.height,alignment:.leading)
                    .blendMode(.screen)
                HUDLabel(text:"SYS 01")
            }
            Spacer(minLength:12)
            HStack(spacing:5){
                HStack(spacing:6){
                    Rectangle().fill(state.connectionColor).frame(width:3.5,height:3.5)
                    Text(state.connection).font(.system(size:9.5,weight:.regular,design:.monospaced))
                        .tracking(0.3).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    Image(systemName:"chevron.down").font(.system(size:8,weight:.regular)).foregroundStyle(Theme.muted)
                }.frame(maxWidth:150,minHeight:44,alignment:.trailing)
                PixelSymbol(kind:.settings,color:Theme.ivory.opacity(0.72)).frame(width:19.5,height:19.5).frame(width:44,height:44)
            }.padding(.trailing,-12).offset(y:-9)
        }
    }
    private var divider:some View{
        Canvas{context,size in
            var p=Path();p.move(to:CGPoint(x:0,y:9));p.addLine(to:CGPoint(x:size.width*0.27,y:9));p.addLine(to:CGPoint(x:size.width*0.29,y:3));p.addLine(to:CGPoint(x:size.width,y:3))
            context.stroke(p,with:.color(Theme.line),lineWidth:0.65)
            context.fill(Path(CGRect(x:size.width-4,y:1,width:4,height:4)),with:.color(state.connectionColor.opacity(0.7)))
        }
    }
    private var status:some View{
        VStack(spacing:0){
            HUDLabel(text:"VOICE / INPUT").padding(.bottom,13)
            PixelText(text:state.status,cell:state.statusCell,color:state.statusColor,tracking:2.8)
                .frame(height:30,alignment:.center)
            Text(state.statusLine).modifier(InstrumentHint()).lineLimit(2).multilineTextAlignment(.center)
                .lineSpacing(3).frame(minHeight:34,alignment:.top).fixedSize(horizontal:false,vertical:true).padding(.top,13)
        }
    }
    private var bar:some View{
        ZStack{
            RecordingBarShape().fill(state.barFill)
                .overlay(RecordingBarShape().stroke(state.canRecord ? Color.clear:Theme.orange.opacity(0.8),lineWidth:1))
                .overlay(alignment:.leading){Rectangle().fill(state.barText.opacity(0.32))
                    .frame(width:2,height:HoldBarLayout.tickHeight).padding(.leading,11)}
                .overlay(alignment:.trailing){Rectangle().fill(state.barText.opacity(0.18))
                    .frame(width:0.7,height:HoldBarLayout.separatorHeight).padding(.trailing,HoldBarLayout.accessoryWidth)}
            HStack(spacing:0){
                PixelText(text:state.barLabel,cell:state.barCell,color:state.barText,tracking:HoldBarLayout.labelTracking)
                Spacer(minLength:HoldBarLayout.labelGap)
                // Elapsed time is drawn by the glyph renderer, centered in this same zone.
                ZStack{
                    if state.listening{
                        Color.clear
                    }else if state.canRecord{
                        PixelSymbol(kind:.microphone,color:state.barText).frame(width:14,height:24)
                    }else{
                        Image(systemName:"link").font(.system(size:13,weight:.semibold)).foregroundStyle(state.barText.opacity(0.9))
                    }
                }.frame(width:HoldBarLayout.accessoryWidth)
            }.padding(.leading,HoldBarLayout.leading)
        }.frame(width:width,height:HoldBarLayout.height)
    }
    private var hud:some View{
        let t=state.torus,bar=min(t.width*0.88,t.width-32),radius=min(t.height*0.23,t.height/2-16)
        func snap(_ p:CGFloat)->CGFloat{(p*displayScale).rounded()/displayScale}
        let left=snap(t.midX-bar/2-12),right=snap(t.midX+bar/2+12)
        let top=snap(t.midY-radius*1.42),bottom=snap(t.midY+radius*1.42)
        return Canvas{context,_ in
            for (label,x,y,anchor) in [
                ("RX / 01",left,top-14,UnitPoint.leading),
                (state.channel,right,top-14,UnitPoint.trailing),
                ("44 BANDS",left,bottom+14,UnitPoint.leading),
                ("16 kHz",right,bottom+14,UnitPoint.trailing)]{
                context.draw(Text(label).font(.system(size:8,weight:.regular,design:.monospaced))
                    .foregroundStyle(label == "CH 01" ? Theme.orange.opacity(0.7):Theme.muted),at:CGPoint(x:x,y:y),anchor:anchor)
            }
        }.frame(width:state.size.width,height:state.size.height)
    }
}
