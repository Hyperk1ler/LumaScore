import AppKit
import SwiftUI

enum CanvasShortcut:Equatable {case play,beginning,back,forward,louder,quieter,loop,maximize,escape,mute,solo}
enum CanvasShortcutRouter {
  static func action(keyCode:UInt16,characters:String,editing:Bool,modified:Bool)->CanvasShortcut? {
    guard !editing,!modified else{return nil}
    switch keyCode {
    case 49:return .play
    case 36,76:return .beginning
    case 123:return .back
    case 124:return .forward
    case 126:return .louder
    case 125:return .quieter
    case 53:return .escape
    default:break
    }
    switch characters.lowercased(){case "r":return .loop;case "f":return .maximize;case "m":return .mute;case "s":return .solo;default:return nil}
  }
}
struct CanvasShortcuts:NSViewRepresentable {
  var perform:(CanvasShortcut)->Void
  final class Coordinator {
    var token:Any?
    weak var view:NSView?
    var perform:(CanvasShortcut)->Void
    init(_ perform:@escaping(CanvasShortcut)->Void){self.perform=perform}
    deinit{if let token=token{NSEvent.removeMonitor(token)}}
    func start(){
      token=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
        guard let self=self,let window=self.view?.window,window.isKeyWindow,event.window===window else{return event}
        let responder=window.firstResponder
        let editing=responder is NSTextView || responder is NSTextField || responder is NSComboBox
        let modified = !event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty
        guard let action=CanvasShortcutRouter.action(keyCode:event.keyCode,characters:event.charactersIgnoringModifiers ?? "",editing:editing,modified:modified) else{return event}
        self.perform(action);return nil
      }
    }
  }
  func makeCoordinator()->Coordinator{Coordinator(perform)}
  func makeNSView(context:Context)->NSView{let view=NSView();context.coordinator.view=view;context.coordinator.start();return view}
  func updateNSView(_ view:NSView,context:Context){context.coordinator.perform=perform}
  static func dismantleNSView(_ view:NSView,coordinator:Coordinator){if let token=coordinator.token{NSEvent.removeMonitor(token);coordinator.token=nil}}
}
