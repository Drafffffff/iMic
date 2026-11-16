import SwiftUI

struct DisplayPreferencesSection: View {
    @AppStorage(PhosphorEffect.preferenceKey) private var material=PhosphorEffect.crt.rawValue
    @AppStorage(PhosphorAttachStyle.preferenceKey) private var attach=PhosphorAttachStyle.flow.rawValue

    var body:some View{
        let selected=material
        let attached=attach
        return VStack(alignment:.leading,spacing:16){
            VStack(alignment:.leading,spacing:8){
                PixelText(text:"DISPLAY",cell:2.1,color:Theme.ivory,tracking:1.5)
                Text(L10n.text("Display effects")).font(.system(size:13,weight:.medium)).foregroundStyle(Theme.ivory)
            }
            HStack(spacing:8){
                ForEach(PhosphorEffect.allCases,id:\.self){effect in
                    Button{
                        Haptics.shared.play(.tap)
                        material=effect.rawValue
                        IMicLog.write("iphone.visual","display material \(effect.rawValue)")
                    }label:{
                        VStack(spacing:9){
                            PixelText(text:effect.label,cell:1.3,color:selected==effect.rawValue ? Theme.orange:Theme.muted,tracking:0.7)
                            Text(effect.title).font(.system(size:11)).foregroundStyle(selected==effect.rawValue ? Theme.ivory:Theme.muted)
                        }.frame(maxWidth:.infinity,minHeight:58).contentShape(Rectangle())
                            .overlay(Rectangle().stroke(selected==effect.rawValue ? Theme.orange.opacity(0.8):Theme.line,lineWidth:1))
                    }.buttonStyle(.plain).accessibilityLabel(effect.title)
                        .accessibilityValue(selected==effect.rawValue ? L10n.text("Selected"):L10n.text("Not selected"))
                        .accessibilityAddTraits(selected==effect.rawValue ? .isSelected:[])
                }
            }
            Text(L10n.text("Clear keeps the original lines. Phosphor adds glow. CRT adds a retro screen texture."))
                .font(.system(size:11)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
            Text(L10n.text("Text attachment")).font(.system(size:13,weight:.medium)).foregroundStyle(Theme.ivory).padding(.top,6)
            HStack(spacing:8){
                ForEach(PhosphorAttachStyle.allCases,id:\.self){style in
                    Button{
                        Haptics.shared.play(.tap)
                        attach=style.rawValue
                        IMicLog.write("iphone.visual","attach style \(style.rawValue)")
                    }label:{
                        VStack(spacing:9){
                            PixelText(text:style.label,cell:1.3,color:attached==style.rawValue ? Theme.orange:Theme.muted,tracking:0.7)
                            Text(style.title).font(.system(size:11)).foregroundStyle(attached==style.rawValue ? Theme.ivory:Theme.muted)
                        }.frame(maxWidth:.infinity,minHeight:58).contentShape(Rectangle())
                            .overlay(Rectangle().stroke(attached==style.rawValue ? Theme.orange.opacity(0.8):Theme.line,lineWidth:1))
                    }.buttonStyle(.plain).accessibilityLabel(L10n.text("Text attachment: %@", L10n.argument(style.title)))
                        .accessibilityValue(attached==style.rawValue ? L10n.text("Selected"):L10n.text("Not selected"))
                        .accessibilityAddTraits(attached==style.rawValue ? .isSelected:[])
                }
            }
            Text(L10n.text("Full ring warms the whole ring where text lands. Flowing arc moves text slowly around the ring. Fixed arc stays at the landing point."))
                .font(.system(size:11)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

/// Native forms/selection remain real system controls, with an input-transparent
/// display-fixed glass layer. No snapshots of UIKit, keyboard, or status bar.
struct PhosphorNativeGlass: ViewModifier {
    @AppStorage(PhosphorEffect.preferenceKey) private var material=PhosphorEffect.crt.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduced

    func body(content:Content)->some View{
        content.overlay{
            if material==PhosphorEffect.crt.rawValue && !reduced{
                GeometryReader{proxy in
                    Rectangle().fill(ShaderLibrary.imicPhosphorGlass(
                        .float(Float(proxy.frame(in:.global).minY)),.float(0.65)))
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
