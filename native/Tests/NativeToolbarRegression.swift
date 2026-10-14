import AppKit
import SwiftUI

@main struct NativeToolbarRegression:App {
  @StateObject private var model:StudioModel
  private let defaults=UserDefaults(suiteName:"lumascore-toolbar-test-\(UUID().uuidString)")!
  init(){
    let studio=StudioModel();studio.resetProject()
    _model=StateObject(wrappedValue:studio)
    let nativeRoot=URL(fileURLWithPath:ProcessInfo.processInfo.environment["LUMASCORE_TEST_NATIVE_ROOT"] ?? FileManager.default.currentDirectoryPath)
    studio.loadMIDI([nativeRoot.appendingPathComponent("Fixtures/representative-5s.mid")]) {
      if let id=studio.tracks.first?.id {studio.styles[id]?.flowSpeed=1.3;studio.styles[id]?.verticalOffset=0.15}
    }
    DispatchQueue.main.asyncAfter(deadline:.now()+8){Self.verify()}
  }
  var body:some Scene {
    WindowGroup("LumaScore toolbar test") {
      StudioView().environmentObject(model).defaultAppStorage(defaults).onAppear {
        DispatchQueue.main.asyncAfter(deadline:.now()+1){Self.verify()}
      }
    }.defaultSize(width:1280,height:800).windowToolbarStyle(.unified)
  }
  private static func verify() {
    for window in NSApp.windows {
      print("WINDOW title=\(window.title) toolbar=\(window.toolbar?.items.count ?? -1) style=\(window.toolbarStyle.rawValue) titleVisibility=\(window.titleVisibility.rawValue) lights=\([NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton].map{window.standardWindowButton($0) != nil})")
      print("ITEMS \(window.toolbar?.items.map{$0.itemIdentifier.rawValue} ?? [])")
    }
    fflush(stdout)
    guard let window=NSApp.windows.first(where:{$0.toolbar != nil}),
      let toolbar=window.toolbar,window.toolbarStyle == .unified,window.titleVisibility == .hidden,
      toolbar.items.count>=5,
      Set(toolbar.items.map{$0.itemIdentifier.rawValue}).isSuperset(of:["library","brand","presets","open","save","reset","export","inspector"]),
      [.closeButton,.miniaturizeButton,.zoomButton].allSatisfy({window.standardWindowButton($0) != nil})
    else {fputs("FAIL unified toolbar or native traffic lights missing\n",stderr);exit(1)}
    print("PASS SwiftUI WindowGroup owns unified toolbar (\(toolbar.items.count) items) and all three native traffic lights")
    if let path=ProcessInfo.processInfo.environment["LUMASCORE_TEST_CAPTURE"],let frame=window.contentView?.superview,
      let bitmap=frame.bitmapImageRepForCachingDisplay(in:frame.bounds) {
      frame.cacheDisplay(in:frame.bounds,to:bitmap)
      try? bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
    }
    window.orderOut(nil)
    fflush(stdout)
    exit(0)
  }
}
