import Foundation
import Combine

struct PresetDefinition: Identifiable {
  var key: String
  var label: String
  var labelZH: String
  var palette: [RGB]
  fileprivate var settings: StudioSettings
  var id: String { key }
}
struct ColorSetDefinition: Identifiable {
  var key: String
  var label: String
  var labelZH: String
  var colors: [RGB]
  var id: String { key }
}
struct SavedPreset: Codable, Identifiable {
  var id: String
  var name: String
  var settings: StudioSettings
  var palette: [RGB]
  var key: String { "custom:\(id)" }
  var label: String { name }
}
struct SavedColorSet: Codable, Identifiable {
  var id: String
  var name: String
  var colors: [RGB]
  var key: String { "custom-color:\(id)" }
  var label: String { name }
}

/// Built-in visual styles authored with the native settings model.
final class PresetLibrary: ObservableObject {
  static let shared = PresetLibrary()
  @Published private(set) var customPresets: [SavedPreset] = []
  @Published private(set) var customColorSets: [SavedColorSet] = []
  let builtins: [PresetDefinition]
  var builtinColorSets: [ColorSetDefinition] {
    builtins.map { ColorSetDefinition(key: $0.key, label: $0.label, labelZH: $0.labelZH,
      colors: Array($0.palette.prefix(8))) }
  }
  private let defaults: UserDefaults
  private static let presetsKey = "lumascore.custom-presets.v1"
  private static let colorsKey = "lumascore.color-sets.v1"
  private static let definitions: [PresetDefinition] = {
    func make(_ key: String, _ label: String, _ zh: String, _ colors: [Int],
      configure: (inout StudioSettings) -> Void) -> PresetDefinition {
      var settings = StudioSettings()
      configure(&settings)
      return PresetDefinition(key: key, label: label, labelZH: zh,
        palette: colors.map(rgb), settings: settings)
    }
    return [
      make("signal", "Signal", "信号", [0x59D5EE,0xF6B85D,0xAC8CFA,0x66DDB5,0xED839A,0x679FF3,0xDADE83,0xEBAB72]) { _ in },
      make("ember", "Ember", "余烬", [0xFFAD66,0xEC705C,0xD6A74E,0xF5CE95,0xB66C9F,0xF3847C,0xC98B5B,0xF0E0C6]) {
        $0.background = rgb(0x20151B); $0.glow = 0.48; $0.glowRadius = 21
        $0.lineStyle = .gradient; $0.spectrumColor = rgb(0xFFAD66)
      },
      make("polar", "Polar", "极地", [0x76DEC6,0x91C9ED,0xCADDED,0x59BCAE,0x849DCF,0xD1F4E7,0x6DAFCB,0xA6B2DC]) {
        $0.background = rgb(0x0C2028); $0.depth = 0.28; $0.glow = 0.24
        $0.spectrumColor = rgb(0x76DEC6); $0.audioTextureGrain = 0.03
      },
      make("graphite", "Graphite", "石墨", [0xE4E8ED,0xBDC6D1,0x939FAE,0xF5F6F8,0xCBD1DA,0xA8B4C3,0xDCE1E7,0x7D8B9D]) {
        $0.background = rgb(0x171B21); $0.bloomEnabled = false; $0.glow = 0
        $0.rippleStyle = .none; $0.marker = .circle; $0.depth = 0
        $0.spectrumColor = rgb(0xDCE1E7); $0.saturation = 0
      },
      make("afterglow", "Afterglow", "余辉", [0xC6A4ED,0xA3BCF1,0xE4A9C8,0xC0D7EF,0x9788C6,0xE2C99D,0x8EB9C6,0xD6A5A0]) {
        $0.background = rgb(0x211B31); $0.glow = 0.62; $0.glowRadius = 30
        $0.lineStyle = .gradient; $0.marker = .heart; $0.spectrumColor = rgb(0xC6A4ED)
      },
      make("raster", "Raster", "扫描", [0xB3D781,0x82CBB0,0xE1C687,0x77B5CE,0xD8A3A0,0xACC8D1,0xDADCB9,0x92A4BF]) {
        $0.background = rgb(0x17211D); $0.crtEnabled = true
        $0.crtScanlines = 0.42; $0.crtNoise = 0.08; $0.crtJitter = 0.06
        $0.crtChromatic = 0.1; $0.glow = 0.25; $0.spectrumColor = rgb(0xB3D781)
      }
    ]
  }()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    builtins = Self.definitions
    customPresets = Self.decodeItems(SavedPreset.self, data: Self.data(defaults, key: Self.presetsKey))
      .filter { Self.validPreset($0) }
    customColorSets = Self.decodeItems(SavedColorSet.self, data: Self.data(defaults, key: Self.colorsKey))
      .filter { Self.validColorSet($0) }
    customPresets = Self.unique(customPresets, id: { $0.id })
    customColorSets = Self.unique(customColorSets, id: { $0.id })
  }

  func settings(for key: String, current: StudioSettings) -> StudioSettings {
    if let saved = customPresets.first(where: { $0.key == key || $0.id == key }) {
      return Self.preserveSession(saved.settings, current: current)
    }
    guard let preset = builtins.first(where: { $0.key == key }) else { return current }
    var value = Self.preserveSession(preset.settings, current: current)
    value.scene = current.scene; value.audioTemplate = current.audioTemplate
    value.title = current.title; value.artist = current.artist; value.genre = current.genre
    value.metronomeEnabled = current.metronomeEnabled
    value.chordEnabled = current.chordEnabled; value.chordTrackIDs = current.chordTrackIDs
    return value
  }

  func palette(for key: String) -> [RGB] {
    if let saved = customPresets.first(where: { $0.key == key || $0.id == key }) { return saved.palette }
    if let saved = customColorSets.first(where: { $0.key == key || $0.id == key }) { return saved.colors }
    return builtins.first(where: { $0.key == key })?.palette ?? builtins.first?.palette ?? RGB.palette
  }

  @discardableResult
  func save(name: String, settings: StudioSettings, palette: [RGB]) throws -> SavedPreset {
    let saved = SavedPreset(id: UUID().uuidString, name: try Self.validName(name), settings: settings, palette: palette)
    guard Self.validPreset(saved) else { throw StudioError.message("预设包含无效设置或颜色") }
    let next = customPresets + [saved]
    try persist(next, key: Self.presetsKey); customPresets = next
    return saved
  }
  func update(id: String, name: String, settings: StudioSettings, palette: [RGB]) throws {
    guard let index = customPresets.firstIndex(where: { $0.id == id || $0.key == id }) else {
      throw StudioError.message("找不到要更新的自定义预设")
    }
    var next = customPresets
    next[index] = SavedPreset(id: next[index].id, name: try Self.validName(name), settings: settings, palette: palette)
    guard Self.validPreset(next[index]) else { throw StudioError.message("预设包含无效设置或颜色") }
    try persist(next, key: Self.presetsKey); customPresets = next
  }
  func delete(id: String) {
    let next = customPresets.filter { $0.id != id && $0.key != id }
    if (try? persist(next, key: Self.presetsKey)) != nil { customPresets = next }
  }
  @discardableResult
  func saveColorSet(name: String, colors: [RGB]) throws -> SavedColorSet {
    let saved = SavedColorSet(id: UUID().uuidString, name: try Self.validName(name), colors: colors)
    guard Self.validColorSet(saved) else { throw StudioError.message("配色需要 8 个有效颜色") }
    let next = customColorSets + [saved]
    try persist(next, key: Self.colorsKey); customColorSets = next
    return saved
  }
  func updateColorSet(id: String, name: String, colors: [RGB]) throws {
    guard let index = customColorSets.firstIndex(where: { $0.id == id || $0.key == id }) else {
      throw StudioError.message("找不到要更新的自定义配色")
    }
    var next = customColorSets
    next[index] = SavedColorSet(id: next[index].id, name: try Self.validName(name), colors: colors)
    guard Self.validColorSet(next[index]) else { throw StudioError.message("配色需要 8 个有效颜色") }
    try persist(next, key: Self.colorsKey); customColorSets = next
  }
  func deleteColorSet(id: String) {
    let next = customColorSets.filter { $0.id != id && $0.key != id }
    if (try? persist(next, key: Self.colorsKey)) != nil { customColorSets = next }
  }
  private func persist<T: Encodable>(_ value: [T], key: String) throws {
    let data = try JSONEncoder().encode(value)
    defaults.set(data, forKey: key)
  }
  private static func preserveSession(_ incoming: StudioSettings, current: StudioSettings) -> StudioSettings {
    var value = incoming
    value.container = current.container; value.aspect = current.aspect; value.resolution = current.resolution
    value.fps = current.fps; value.codec = current.codec; value.bitrate = current.bitrate
    value.exportStart = current.exportStart; value.exportEnd = current.exportEnd
    value.intro = current.intro; value.offset = current.offset; value.bpm = current.bpm
    value.volume = current.volume; value.loop = current.loop
    return value
  }
  private static func validName(_ name: String) throws -> String {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 100 else { throw StudioError.message("名称需要 1 至 100 个字符") }
    return value
  }
  private static func validRGB(_ color: RGB) -> Bool {
    [color.r, color.g, color.b].allSatisfy { $0.isFinite && (0...1).contains($0) }
  }
  private static func validSettings(_ settings: StudioSettings) -> Bool {
    (try? settings.validate()) != nil
      && [settings.background, settings.titleColor, settings.chordColor, settings.playheadColor,
        settings.particleColor, settings.spectrumColor].allSatisfy(validRGB)
  }
  private static func validPreset(_ saved: SavedPreset) -> Bool {
    !saved.id.isEmpty && saved.id.count <= 200 && (try? validName(saved.name)) != nil
      && validSettings(saved.settings) && (1...64).contains(saved.palette.count)
      && saved.palette.allSatisfy(validRGB)
  }
  private static func validColorSet(_ saved: SavedColorSet) -> Bool {
    !saved.id.isEmpty && saved.id.count <= 200 && (try? validName(saved.name)) != nil
      && saved.colors.count == 8 && saved.colors.allSatisfy(validRGB)
  }
  private static func unique<T>(_ values: [T], id: (T) -> String) -> [T] {
    var seen = Set<String>()
    return values.filter { seen.insert(id($0)).inserted }
  }
  private static func data(_ defaults: UserDefaults, key: String) -> Data? {
    defaults.data(forKey: key) ?? defaults.string(forKey: key)?.data(using: .utf8)
  }
  private static func decodeItems<T: Decodable>(_ type: T.Type, data: Data?) -> [T] {
    guard let data = data, let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
    return items.compactMap { item in
      guard JSONSerialization.isValidJSONObject(item), let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
      return try? JSONDecoder().decode(type, from: data)
    }
  }
  private static func rgb(_ hex: Int) -> RGB {
    RGB(Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255, Float(hex & 255) / 255)
  }
}

extension StudioModel {
  func applyPreset(_ key: String) {
    settings = PresetLibrary.shared.settings(for: key, current: settings)
    applyPalette(key)
  }
  func applyPalette(_ colors:[RGB]) {
    guard !colors.isEmpty else{return}
    for (i,t) in tracks.enumerated(){styles[t.id,default:TrackStyle(color:colors[i%colors.count])].color=colors[i%colors.count]}
    revision+=1
  }
  func applyPalette(_ key: String) {
    let colors = PresetLibrary.shared.palette(for: key)
    guard !colors.isEmpty else { return }
    for (index, track) in tracks.enumerated() {
      var style = styles[track.id] ?? TrackStyle(color: colors[index % colors.count])
      style.color = colors[index % colors.count]
      styles[track.id] = style
    }
    revision += 1
  }
  func resetSavedSettings() {
    UserDefaults.standard.removeObject(forKey: "lumascore.settings.v1")
    resetAppearance()
  }
}
