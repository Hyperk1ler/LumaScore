import Foundation
@main struct PresetSmoke {
 static func main() throws {
  let name="lumascore-preset-test-\(UUID().uuidString)";let defaults=UserDefaults(suiteName:name)!
  defer{defaults.removePersistentDomain(forName:name)}
  let lib=PresetLibrary(defaults:defaults)
  precondition(lib.builtins.count==6)
  for p in lib.builtins {let s=lib.settings(for:p.key,current:StudioSettings());try s.validate();print("PASS \(p.key) \(s.lineStyle) \(s.glow)")}
  var session=StudioSettings();session.scene = .audio;session.audioTemplate = .recordSleeve;session.title="Track title";session.artist="Artist";session.genre="Ambient";session.intro=3;session.bpm=144;session.metronomeEnabled=true;session.chordEnabled=true;session.chordTrackIDs=["a"]
  for p in lib.builtins {
    let applied=lib.settings(for:p.key,current:session)
    precondition(applied.scene==session.scene && applied.audioTemplate==session.audioTemplate && applied.title==session.title && applied.artist==session.artist && applied.genre==session.genre && applied.intro==3 && applied.bpm==144 && applied.metronomeEnabled && applied.chordEnabled && applied.chordTrackIDs==["a"])
  }
  let saved=try lib.save(name:"Test",settings:StudioSettings(),palette:RGB.palette)
  let restored=PresetLibrary(defaults:defaults);precondition(restored.customPresets.count==1)
  try lib.update(id:saved.id,name:"Updated",settings:StudioSettings(),palette:RGB.palette);lib.delete(id:saved.id);precondition(lib.customPresets.isEmpty)
  let colors=try lib.saveColorSet(name:"Color",colors:RGB.palette);try lib.updateColorSet(id:colors.id,name:"Updated",colors:RGB.palette);lib.deleteColorSet(id:colors.id);precondition(lib.customColorSets.isEmpty)
  print("ALL PRESET PERSISTENCE CHECKS PASSED")
 }
}
