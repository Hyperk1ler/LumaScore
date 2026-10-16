import AppKit
import Foundation
import simd

struct RGB: Codable, Equatable {
  var r: Float
  var g: Float
  var b: Float
  var vector: SIMD4<Float> { SIMD4(r, g, b, 1) }
  var nsColor: NSColor {
    NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
  }
  init(_ r: Float, _ g: Float, _ b: Float) {
    self.r = r
    self.g = g
    self.b = b
  }
  init(_ color: NSColor) {
    let c = color.usingColorSpace(.sRGB) ?? .white
    r = Float(c.redComponent)
    g = Float(c.greenComponent)
    b = Float(c.blueComponent)
  }
  static let palette = [
    RGB(0.12, 0.83, 0.92), RGB(1, 0.64, 0.26), RGB(0.62, 0.49, 1), RGB(0.36, 0.86, 0.61),
    RGB(1, 0.39, 0.57), RGB(0.37, 0.61, 1), RGB(0.92, 0.82, 0.31), RGB(0.84, 0.49, 0.85),
  ]
}
struct MIDINote: Codable {
  var start: Double
  var duration: Double
  var pitch: Int
  var velocity: Float
  var end: Double { start + duration }
}
struct MIDIControl: Codable {
  var time: Double
  var value: Float
}
struct MIDITrack: Codable, Identifiable {
  var id: String
  var name: String
  var channel: Int
  var notes: [MIDINote]
  var bends: [MIDIControl]
  var modulation: [MIDIControl]
  var sourceFile: String? = nil
  var sourceTrackNumber: Int? = nil
  var endTime: Double? = nil
  var displayName: String {
    let cleaned=String(name.unicodeScalars.filter{!CharacterSet.controlCharacters.contains($0)}).trimmingCharacters(in:.whitespacesAndNewlines)
    return cleaned.isEmpty ? "轨道 \(sourceTrackNumber ?? channel+1) / Track \(sourceTrackNumber ?? channel+1) · CH\(channel+1)" : cleaned
  }
  var sourceLabel: String { sourceFile ?? "MIDI" }
  var menuLabel: String { "\(sourceLabel) · \(displayName)" }
}
struct MIDISequence {
  var tracks: [MIDITrack]
  var bpm: Double
  var duration: Double
  var minPitch: Int
  var maxPitch: Int
  var tempoMap: [MIDITempo] = []
}
struct MIDITempo: Codable, Equatable {
  var time: Double
  var bpm: Double
  var beat: Double
}
enum Marker: String, Codable, CaseIterable {
  case diamond = "菱形"
  case circle = "圆点"
  case heart = "心形"
  case emoji = "Emoji"
  case none = "隐藏"
  var shape: Float {
    switch self {
    case .diamond: return 2
    case .circle: return 1
    case .heart: return 3
    case .emoji: return 7
    case .none: return 0
    }
  }
}
enum SceneKind: String, Codable, CaseIterable {
  case midi = "MIDI Canvas", audio = "Audio Observatory", hybrid = "Hybrid"
}
enum AudioTemplate: String, Codable, CaseIterable {
  case orbit = "Orbit", spectralField = "Spectral Field", recordSleeve = "Record Sleeve"
  var label: String {
    switch self {
    case .orbit: return "01 · 仪表 / Orbit"
    case .spectralField: return "02 · 频谱场 / Spectral Field"
    case .recordSleeve: return "03 · 片封 / Record Sleeve"
    }
  }
}
enum NoteLine: String, Codable, CaseIterable { case solid = "Solid", gradient = "Gradient", outline = "Outline", brush = "Brush" }
enum RippleStyle: String, Codable, CaseIterable { case ring = "Ring", flare = "Flare", spark = "Spark", none = "None" }
enum ParticleStyle: String, Codable, CaseIterable { case dust = "Dust", sparkles = "Sparkles", comets = "Comets" }
enum ParticleDirection: String, Codable, CaseIterable { case down = "Top Down", left = "Right to Left" }
enum LensMode: String, Codable, CaseIterable { case pincushion = "Pincushion", barrel = "Barrel" }
enum ExportContainer: String, Codable, CaseIterable { case mp4 = "MP4", webm = "WebM" }
enum NoteMotion: String, Codable, CaseIterable { case sink = "Sink", pluck = "Pluck" }
enum OverlayPosition: String, Codable, CaseIterable {
  case topLeft = "Top Left", topCenter = "Top Center", topRight = "Top Right"
  case center = "Center", bottomLeft = "Bottom Left", bottomCenter = "Bottom Center", bottomRight = "Bottom Right"
  func point(width: Float, height: Float) -> SIMD2<Float> {
    let x: Float = [.topLeft, .bottomLeft].contains(self) ? 0.18 : ([.topRight, .bottomRight].contains(self) ? 0.82 : 0.5)
    let y: Float = self == .center ? 0.5 : ([.topLeft, .topCenter, .topRight].contains(self) ? 0.08 : 0.9)
    return SIMD2(width * x, height * y)
  }
}
enum TextMotion: String, Codable, CaseIterable { case none = "None", fade = "Fade", slide = "Slide", scale = "Scale", typewriter = "Typewriter" }
struct TrackStyle: Codable, Equatable {
  var color: RGB
  var muted = false
  var solo = false
  var line: NoteLine? = nil
  var ripple: RippleStyle? = nil
  var motion: NoteMotion? = nil
  var marker: Marker? = nil
  var thickness: Double? = nil
  var glow: Double? = nil
  var flowSpeed = 1.0
  var horizontalOffset = 0.0
  var verticalOffset = 0.0
  var timeOffset = 0.0
  enum CodingKeys: String, CodingKey { case color, muted, solo, line, ripple, motion, marker, thickness, glow, flowSpeed, horizontalOffset, verticalOffset, timeOffset }
  init(color: RGB) { self.color = color }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    color = try c.decode(RGB.self, forKey: .color)
    muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
    line = try c.decodeIfPresent(NoteLine.self, forKey: .line)
    ripple = try c.decodeIfPresent(RippleStyle.self, forKey: .ripple)
    motion = try c.decodeIfPresent(NoteMotion.self, forKey: .motion)
    marker = try c.decodeIfPresent(Marker.self, forKey: .marker)
    thickness = try c.decodeIfPresent(Double.self, forKey: .thickness)
    glow = try c.decodeIfPresent(Double.self, forKey: .glow)
    flowSpeed = try c.decodeIfPresent(Double.self, forKey: .flowSpeed) ?? 1
    horizontalOffset = try c.decodeIfPresent(Double.self, forKey: .horizontalOffset) ?? 0
    verticalOffset = try c.decodeIfPresent(Double.self, forKey: .verticalOffset) ?? 0
    timeOffset = try c.decodeIfPresent(Double.self, forKey: .timeOffset) ?? 0
    try validate()
  }
  func validate() throws {
    guard [flowSpeed,horizontalOffset,verticalOffset,timeOffset].allSatisfy({$0.isFinite}),
      (0.25...4).contains(flowSpeed),(-0.5...0.5).contains(horizontalOffset),
      (-1...1).contains(verticalOffset),(-3600...3600).contains(timeOffset)
    else {throw StudioError.message("轨道流速或位置超出有效范围 / Invalid track transform")}
  }
}
enum VideoCodec: String, Codable, CaseIterable {
  case h264 = "H.264"
  case hevc = "HEVC"
}
enum Aspect: String, Codable, CaseIterable {
  case wide = "16:9"
  case standard = "4:3"
  case square = "1:1"
  case portrait = "9:16"
  var ratio: Double {
    switch self {
    case .wide: return 16 / 9
    case .standard: return 4 / 3
    case .square: return 1
    case .portrait: return 9 / 16
    }
  }
}
struct StudioSettings: Codable, Equatable {
  var container: ExportContainer = .mp4
  var particleStyle: ParticleStyle = .dust
  var particleDirection: ParticleDirection = .down
  var particleAmount: Double = 120
  var particleSize: Double = 1.5
  var particleSpeed: Double = 0.6
  var particleOpacity: Double = 0.5
  var particleTwinkle: Double = 1.0
  var particleColor: RGB = RGB(1,1,1)
  var lensMode: LensMode = .pincushion
  var backgroundOpacity: Double = 1.0
  var playheadColor: RGB = RGB(0.85,0.95,1)
  var reactionPosition: Double = 0.5
  var animationDepth: Double = 1.0
  var bloomEnabled: Bool = true
  var colorFilterEnabled: Bool = true
  var screenFadeEnabled: Bool = true
  var audioFadeEnabled: Bool = true
  var cameraTrackID: String = ""
  var cameraPunch: Double = 0.0
  var scene: SceneKind = .midi
  var audioTemplate: AudioTemplate = .orbit
  var metronomeEnabled = false
  var audioTextureOpacity = 0.45
  var audioTextureGrain = 0.08
  var lineStyle: NoteLine = .solid
  var rippleStyle: RippleStyle = .ring
  var noteMotion: NoteMotion = .sink
  var rounded = true
  var noteRoundness = 1.0
  var playheadVisible = true
  var depth = 0.5
  var bendDepth = 1.0
  var modulationDepth = 1.0
  var rippleSize = 1.0
  var rippleDuration = 0.8
  var titleEnabled = true
  var titlePosition: OverlayPosition = .topCenter
  var titleFont = "System"
  var titleMotion: TextMotion = .none
  var titleMotionDuration = 1.0
  var chordEnabled = false
  var chordTrackIDs: [String] = []
  var chordPosition: OverlayPosition = .bottomCenter
  var chordSize = 36.0
  var chordColor = RGB(0.4, 0.8, 1)
  var chordFont = "System"
  var brightness = 0.0
  var contrast = 1.0
  var saturation = 1.0
  var hue = 0.0
  var sepia = 0.0
  var cameraShake = 0.0
  var audioFadeIn = 0.0
  var audioFadeOut = 0.0
  var crtEnabled = false
  var crtScanlines = 0.35
  var crtNoise = 0.12
  var crtJitter = 0.15
  var crtChromatic = 0.2
  var crtFlicker = 0.08
  var crtVignette = 0.25
  var artist = ""
  var genre = ""
  var spectrumColor = RGB(0.36, 0.55, 1)
  var spectrumDepth: Double = 0
  var spectrumTilt: Double = 0
  var spectrumInFront: Bool = false
  var spectrumGain = 1.0
  var spectrumSmoothing = 0.5
  var waveformVisible = true
  var audioMetadataVisible = true
  var coverRotation = false
  var aspect: Aspect = .wide
  var resolution = 1080
  var fps = 60
  var codec: VideoCodec = .h264
  var bitrate = 24
  var window = 8.0
  var horizontalZoom = 1.0
  var pitchZoom = 1.0
  var pitchScroll = 0.0
  var playheadPosition = 0.34
  var thickness = 6.0
  var marker: Marker = .diamond
  var markerSize = 14.0
  var emoji = "✨"
  var glow = 0.35
  var glowRadius = 12.0
  var particles = 0.0
  var fisheye = 0.0
  var grid = true
  var background = RGB(0.025, 0.035, 0.055)
  var title = ""
  var titleSize = 36.0
  var titleColor = RGB(0.92, 0.95, 1)
  var intro = 0.0
  var offset = 0.0
  var bpm = 0.0
  var exportStart = 0.0
  var exportEnd = 0.0
  var fadeIn = 0.0
  var fadeOut = 0.0
  var volume = 0.8
  var loop = false
  var dimensions: (Int, Int) {
    let ratio = aspect.ratio
    func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
    return ratio >= 1
      ? (even(Double(resolution) * ratio), resolution)
      : (resolution, even(Double(resolution) / ratio))
  }
  mutating func applyAudioTemplate(_ template:AudioTemplate) {
    audioTemplate=template
    switch template {
    case .orbit:
      background=RGB(7/255,18/255,46/255);spectrumColor=RGB(0.45,0.62,0.88);titleColor=RGB(0.68,0.78,0.95)
    case .spectralField:
      background=RGB(8/255,25/255,29/255);spectrumColor=RGB(0.44,0.85,0.76);titleColor=RGB(0.88,0.97,0.94)
    case .recordSleeve:
      background=RGB(23/255,30/255,34/255);spectrumColor=RGB(0.71,0.80,0.75);titleColor=RGB(0.94,0.93,0.90)
    }
  }
  func validate() throws {
    guard audioTextureOpacity.isFinite, audioTextureGrain.isFinite,
      (0...1).contains(audioTextureOpacity), (0...1).contains(audioTextureGrain)
    else { throw StudioError.message("音频背景纹理参数超出范围") }
    guard [brightness, contrast, saturation, hue, sepia, cameraShake, audioFadeIn, audioFadeOut,
      crtScanlines, crtNoise, crtJitter, crtChromatic, crtFlicker, crtVignette, spectrumGain,
      spectrumSmoothing, depth, bendDepth, modulationDepth, rippleSize, rippleDuration,
      titleMotionDuration, chordSize].allSatisfy({ $0.isFinite }),
      (-1...1).contains(brightness), (0...3).contains(contrast), (0...3).contains(saturation),
      (-180...180).contains(hue), (0...1).contains(sepia), (0...1).contains(cameraShake),
      (0...600).contains(audioFadeIn), (0...600).contains(audioFadeOut),
      [crtScanlines, crtNoise, crtJitter, crtChromatic, crtFlicker, crtVignette, depth, spectrumSmoothing].allSatisfy({ (0...1).contains($0) }),
      (0...5).contains(bendDepth), (0...5).contains(modulationDepth), (0.1...5).contains(rippleSize),
      (0.05...5).contains(rippleDuration), (0.05...10).contains(titleMotionDuration),
      (8...200).contains(chordSize), (0.1...5).contains(spectrumGain),
      spectrumDepth.isFinite, spectrumTilt.isFinite, (-1...1).contains(spectrumDepth), (0...70).contains(spectrumTilt),
      (0...1).contains(noteRoundness),
      [particleAmount,particleSize,particleSpeed,particleOpacity,particleTwinkle,backgroundOpacity,reactionPosition,animationDepth,cameraPunch].allSatisfy({ $0.isFinite }),
      (0...500).contains(particleAmount), (0.5...3).contains(particleSize), (0...2).contains(particleSpeed),
      [particleOpacity,particleTwinkle,backgroundOpacity,reactionPosition,cameraPunch].allSatisfy({(0...1).contains($0)}), (0...2).contains(animationDepth),
      artist.count <= 500, genre.count <= 100,
      [480, 720, 1080, 2160].contains(resolution), [30, 60].contains(fps),
      [8, 16, 24, 40].contains(bitrate), (1...240).contains(window), (1...128).contains(thickness),
      (0.25...8).contains(horizontalZoom), (0.25...8).contains(pitchZoom),
      (-128...128).contains(pitchScroll), (0.05...0.95).contains(playheadPosition),
      (2...40).contains(glowRadius),
      (1...128).contains(markerSize), (0...1).contains(glow), (0...1).contains(particles),
      (0...1).contains(fisheye), (0...60).contains(intro), (-3600...3600).contains(offset),
      (0...1000).contains(bpm), (0...86400).contains(exportStart), (0...86400).contains(exportEnd),
      (0...600).contains(fadeIn), (0...600).contains(fadeOut), (8...200).contains(titleSize),
      (0...1).contains(volume), title.count <= 500, emoji.count <= 20
    else { throw StudioError.message("设置超出有效范围，请检查时间、BPM 或画面参数") }
  }
}

extension StudioSettings {
  // Optional visual fields use neutral defaults when omitted from a settings document.
  enum CodingKeys: String, CodingKey {
    case audioTemplate, metronomeEnabled, audioTextureOpacity, audioTextureGrain
    case spectrumDepth, spectrumTilt, spectrumInFront
    case container, particleStyle, particleDirection, particleAmount, particleSize, particleSpeed, particleOpacity, particleTwinkle, particleColor, lensMode, backgroundOpacity, playheadColor, reactionPosition, animationDepth, bloomEnabled, colorFilterEnabled, screenFadeEnabled, audioFadeEnabled, cameraTrackID, cameraPunch
    case scene, lineStyle, rippleStyle, noteMotion, rounded, noteRoundness, playheadVisible, depth, bendDepth, modulationDepth, rippleSize, rippleDuration, titleEnabled, titlePosition, titleFont, titleMotion, titleMotionDuration, chordEnabled, chordTrackIDs, chordPosition, chordSize, chordColor, chordFont, brightness, contrast, saturation, hue, sepia, cameraShake, audioFadeIn, audioFadeOut, crtEnabled, crtScanlines, crtNoise, crtJitter, crtChromatic, crtFlicker, crtVignette, artist, genre, spectrumColor, spectrumGain, spectrumSmoothing, waveformVisible, audioMetadataVisible, coverRotation
    case aspect, resolution, fps, codec, bitrate, window, horizontalZoom, pitchZoom, pitchScroll
    case playheadPosition, thickness, marker, markerSize, emoji, glow, glowRadius, particles
    case fisheye, grid, background, title, titleSize, titleColor, intro, offset, bpm
    case exportStart, exportEnd, fadeIn, fadeOut, volume, loop
  }
  init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    audioTemplate = try c.decodeIfPresent(AudioTemplate.self, forKey: .audioTemplate) ?? audioTemplate
    metronomeEnabled = try c.decodeIfPresent(Bool.self, forKey: .metronomeEnabled) ?? metronomeEnabled
    audioTextureOpacity = try c.decodeIfPresent(Double.self, forKey: .audioTextureOpacity) ?? audioTextureOpacity
    audioTextureGrain = try c.decodeIfPresent(Double.self, forKey: .audioTextureGrain) ?? audioTextureGrain
    spectrumDepth = try c.decodeIfPresent(Double.self, forKey: .spectrumDepth) ?? spectrumDepth
    spectrumTilt = try c.decodeIfPresent(Double.self, forKey: .spectrumTilt) ?? spectrumTilt
    spectrumInFront = try c.decodeIfPresent(Bool.self, forKey: .spectrumInFront) ?? spectrumInFront
    container = try c.decodeIfPresent(ExportContainer.self, forKey: .container) ?? container
    particleStyle = try c.decodeIfPresent(ParticleStyle.self, forKey: .particleStyle) ?? particleStyle
    particleDirection = try c.decodeIfPresent(ParticleDirection.self, forKey: .particleDirection) ?? particleDirection
    particleAmount = try c.decodeIfPresent(Double.self, forKey: .particleAmount) ?? particleAmount
    particleSize = try c.decodeIfPresent(Double.self, forKey: .particleSize) ?? particleSize
    particleSpeed = try c.decodeIfPresent(Double.self, forKey: .particleSpeed) ?? particleSpeed
    particleOpacity = try c.decodeIfPresent(Double.self, forKey: .particleOpacity) ?? particleOpacity
    particleTwinkle = try c.decodeIfPresent(Double.self, forKey: .particleTwinkle) ?? particleTwinkle
    particleColor = try c.decodeIfPresent(RGB.self, forKey: .particleColor) ?? particleColor
    lensMode = try c.decodeIfPresent(LensMode.self, forKey: .lensMode) ?? lensMode
    backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? backgroundOpacity
    playheadColor = try c.decodeIfPresent(RGB.self, forKey: .playheadColor) ?? playheadColor
    reactionPosition = try c.decodeIfPresent(Double.self, forKey: .reactionPosition) ?? reactionPosition
    animationDepth = try c.decodeIfPresent(Double.self, forKey: .animationDepth) ?? animationDepth
    bloomEnabled = try c.decodeIfPresent(Bool.self, forKey: .bloomEnabled) ?? bloomEnabled
    colorFilterEnabled = try c.decodeIfPresent(Bool.self, forKey: .colorFilterEnabled) ?? colorFilterEnabled
    screenFadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .screenFadeEnabled) ?? screenFadeEnabled
    audioFadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioFadeEnabled) ?? audioFadeEnabled
    cameraTrackID = try c.decodeIfPresent(String.self, forKey: .cameraTrackID) ?? cameraTrackID
    cameraPunch = try c.decodeIfPresent(Double.self, forKey: .cameraPunch) ?? cameraPunch
    scene = try c.decodeIfPresent(SceneKind.self, forKey: .scene) ?? scene
    lineStyle = try c.decodeIfPresent(NoteLine.self, forKey: .lineStyle) ?? lineStyle
    rippleStyle = try c.decodeIfPresent(RippleStyle.self, forKey: .rippleStyle) ?? rippleStyle
    noteMotion = try c.decodeIfPresent(NoteMotion.self, forKey: .noteMotion) ?? noteMotion
    rounded = try c.decodeIfPresent(Bool.self, forKey: .rounded) ?? rounded
    noteRoundness = try c.decodeIfPresent(Double.self, forKey: .noteRoundness) ?? (rounded ? 1:0)
    playheadVisible = try c.decodeIfPresent(Bool.self, forKey: .playheadVisible) ?? playheadVisible
    depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? depth
    bendDepth = try c.decodeIfPresent(Double.self, forKey: .bendDepth) ?? bendDepth
    modulationDepth = try c.decodeIfPresent(Double.self, forKey: .modulationDepth) ?? modulationDepth
    rippleSize = try c.decodeIfPresent(Double.self, forKey: .rippleSize) ?? rippleSize
    rippleDuration = try c.decodeIfPresent(Double.self, forKey: .rippleDuration) ?? rippleDuration
    titleEnabled = try c.decodeIfPresent(Bool.self, forKey: .titleEnabled) ?? titleEnabled
    titlePosition = try c.decodeIfPresent(OverlayPosition.self, forKey: .titlePosition) ?? titlePosition
    titleFont = try c.decodeIfPresent(String.self, forKey: .titleFont) ?? titleFont
    titleMotion = try c.decodeIfPresent(TextMotion.self, forKey: .titleMotion) ?? titleMotion
    titleMotionDuration = try c.decodeIfPresent(Double.self, forKey: .titleMotionDuration) ?? titleMotionDuration
    chordEnabled = try c.decodeIfPresent(Bool.self, forKey: .chordEnabled) ?? chordEnabled
    chordTrackIDs = try c.decodeIfPresent([String].self, forKey: .chordTrackIDs) ?? chordTrackIDs
    chordPosition = try c.decodeIfPresent(OverlayPosition.self, forKey: .chordPosition) ?? chordPosition
    chordSize = try c.decodeIfPresent(Double.self, forKey: .chordSize) ?? chordSize
    chordColor = try c.decodeIfPresent(RGB.self, forKey: .chordColor) ?? chordColor
    chordFont = try c.decodeIfPresent(String.self, forKey: .chordFont) ?? chordFont
    brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? brightness
    contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
    saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
    hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? hue
    sepia = try c.decodeIfPresent(Double.self, forKey: .sepia) ?? sepia
    cameraShake = try c.decodeIfPresent(Double.self, forKey: .cameraShake) ?? cameraShake
    audioFadeIn = try c.decodeIfPresent(Double.self, forKey: .audioFadeIn) ?? audioFadeIn
    audioFadeOut = try c.decodeIfPresent(Double.self, forKey: .audioFadeOut) ?? audioFadeOut
    crtEnabled = try c.decodeIfPresent(Bool.self, forKey: .crtEnabled) ?? crtEnabled
    crtScanlines = try c.decodeIfPresent(Double.self, forKey: .crtScanlines) ?? crtScanlines
    crtNoise = try c.decodeIfPresent(Double.self, forKey: .crtNoise) ?? crtNoise
    crtJitter = try c.decodeIfPresent(Double.self, forKey: .crtJitter) ?? crtJitter
    crtChromatic = try c.decodeIfPresent(Double.self, forKey: .crtChromatic) ?? crtChromatic
    crtFlicker = try c.decodeIfPresent(Double.self, forKey: .crtFlicker) ?? crtFlicker
    crtVignette = try c.decodeIfPresent(Double.self, forKey: .crtVignette) ?? crtVignette
    artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? artist
    genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? genre
    spectrumColor = try c.decodeIfPresent(RGB.self, forKey: .spectrumColor) ?? spectrumColor
    spectrumGain = try c.decodeIfPresent(Double.self, forKey: .spectrumGain) ?? spectrumGain
    spectrumSmoothing = try c.decodeIfPresent(Double.self, forKey: .spectrumSmoothing) ?? spectrumSmoothing
    waveformVisible = try c.decodeIfPresent(Bool.self, forKey: .waveformVisible) ?? waveformVisible
    audioMetadataVisible = try c.decodeIfPresent(Bool.self, forKey: .audioMetadataVisible) ?? audioMetadataVisible
    coverRotation = try c.decodeIfPresent(Bool.self, forKey: .coverRotation) ?? coverRotation
    aspect = try c.decodeIfPresent(Aspect.self, forKey: .aspect) ?? aspect
    resolution = try c.decodeIfPresent(Int.self, forKey: .resolution) ?? resolution
    fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? fps
    codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? codec
    bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? bitrate
    window = try c.decodeIfPresent(Double.self, forKey: .window) ?? window
    horizontalZoom = try c.decodeIfPresent(Double.self, forKey: .horizontalZoom) ?? horizontalZoom
    pitchZoom = try c.decodeIfPresent(Double.self, forKey: .pitchZoom) ?? pitchZoom
    pitchScroll = try c.decodeIfPresent(Double.self, forKey: .pitchScroll) ?? pitchScroll
    playheadPosition =
      try c.decodeIfPresent(Double.self, forKey: .playheadPosition) ?? playheadPosition
    thickness = try c.decodeIfPresent(Double.self, forKey: .thickness) ?? thickness
    marker = try c.decodeIfPresent(Marker.self, forKey: .marker) ?? marker
    markerSize = try c.decodeIfPresent(Double.self, forKey: .markerSize) ?? markerSize
    emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? emoji
    glow = try c.decodeIfPresent(Double.self, forKey: .glow) ?? glow
    glowRadius = try c.decodeIfPresent(Double.self, forKey: .glowRadius) ?? glowRadius
    particles = try c.decodeIfPresent(Double.self, forKey: .particles) ?? particles
    fisheye = try c.decodeIfPresent(Double.self, forKey: .fisheye) ?? fisheye
    grid = try c.decodeIfPresent(Bool.self, forKey: .grid) ?? grid
    background = try c.decodeIfPresent(RGB.self, forKey: .background) ?? background
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? title
    titleSize = try c.decodeIfPresent(Double.self, forKey: .titleSize) ?? titleSize
    titleColor = try c.decodeIfPresent(RGB.self, forKey: .titleColor) ?? titleColor
    intro = try c.decodeIfPresent(Double.self, forKey: .intro) ?? intro
    offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? offset
    bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) ?? bpm
    exportStart = try c.decodeIfPresent(Double.self, forKey: .exportStart) ?? exportStart
    exportEnd = try c.decodeIfPresent(Double.self, forKey: .exportEnd) ?? exportEnd
    fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? fadeIn
    fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? fadeOut
    volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? volume
    loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? loop
  }
}

/// One camera transform for preview, export, sliders and pointer gestures.
struct SceneViewport {
  let width: Double, height: Double, playheadX: Double, pixelsPerSecond: Double
  let pitchCenter: Double, pixelsPerPitch: Double
  init(snapshot: RenderSnapshot, width: Double, height: Double) {
    self.width = width
    self.height = height
    let s = snapshot.settings
    playheadX = width * s.playheadPosition
    pixelsPerSecond = width * 0.66 / (max(1, s.window) / snapshot.tempoScale) * s.horizontalZoom
    let low = min(snapshot.minPitch - 3, 48)
    let high = max(snapshot.maxPitch + 3, 84)
    pitchCenter = Double(low + high) / 2 + s.pitchScroll
    pixelsPerPitch = height * 0.72 / Double(max(1, high - low)) * s.pitchZoom
  }
  func x(noteTime: Double, timelineTime: Double) -> Double {
    playheadX + (noteTime - timelineTime) * pixelsPerSecond
  }
  func y(pitch: Double) -> Double { height * 0.5 - (pitch - pitchCenter) * pixelsPerPitch }
}

enum NumberInput {
  static func parse(_ text: String, range: ClosedRange<Double>) -> Double? {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "，", with: ".").replacingOccurrences(of: ",", with: ".")
    guard let value = Double(normalized), value.isFinite, range.contains(value) else { return nil }
    return value
  }
  static func format(_ value: Double) -> String {
    String(format: "%.3f", value).replacingOccurrences(
      of: #"\.?0+$"#, with: "", options: .regularExpression)
  }
}
struct ProjectFile: Codable {
  var format = "lumascore"
  var version = 1
  var audio: String?
  var midi: [String]
  var background: String?
  var cover: String? = nil
  var settings: StudioSettings
  var styles: [String: TrackStyle]
  var midiSourceIDs: [Int]? = nil
  var trackOrder: [String]? = nil
}
struct RenderSnapshot {
  var tracks: [MIDITrack]
  var styles: [String: TrackStyle]
  var settings: StudioSettings
  var bpm: Double
  var duration: Double
  var minPitch: Int
  var maxPitch: Int
  var backgroundURL: URL?
  var audioVisualization: AudioVisualizationData? = nil
  var audioName: String = ""
  var coverURL: URL? = nil
  var tempoMap: [MIDITempo] = []
  func musicalBeat(at time: Double) -> Double? {
    guard time >= settings.intro, !tracks.isEmpty || settings.bpm > 0 else { return nil }
    let sourceTime = (time - settings.intro + (tracks.isEmpty ? 0:settings.offset)) / tempoScale
    guard sourceTime >= 0 else { return nil }
    let i = tracks.isEmpty ? 0:lowerBound(tempoMap, sourceTime.nextUp, key: { $0.time })
    guard i > 0 else { return sourceTime * bpm / 60 }
    let tempo = tempoMap[i - 1]
    return tempo.beat + (sourceTime - tempo.time) * tempo.bpm / 60
  }
  func musicalBPM(at time: Double) -> Double? {
    guard !tracks.isEmpty || settings.bpm > 0 else { return nil }
    let t = max(0, (time - settings.intro + (tracks.isEmpty ? 0:settings.offset)) / tempoScale)
    let i = tracks.isEmpty ? 0:lowerBound(tempoMap, t.nextUp, key: { $0.time })
    return (i > 0 ? tempoMap[i - 1].bpm : bpm) / tempoScale
  }
  func metronomePosition(at time: Double) -> Double {
    guard let beat = musicalBeat(at: time) else { return 0.5 }
    return 0.5 - 0.43 * cos(beat * .pi)
  }
  var tempoScale: Double { settings.bpm > 0 ? max(0.000001, bpm / settings.bpm) : 1 }
  func trackTime(_ id:String,at time:Double)->Double {
    (time-settings.intro+settings.offset-(styles[id]?.timeOffset ?? 0))/tempoScale
  }
  var chordTracks:[MIDITrack] {
    tracks.map { track in
      let offset=(styles[track.id]?.timeOffset ?? 0)/tempoScale
      guard offset != 0,settings.chordTrackIDs.contains(track.id) else{return track}
      var shifted=track
      shifted.notes=track.notes.map {note in var value=note;value.start+=offset;return value}
      return shifted
    }
  }
  var visualDuration: Double {
    let latest=tracks.reduce(0.0){last,track in
      max(last,(track.endTime ?? duration)*tempoScale+(styles[track.id]?.timeOffset ?? 0)-settings.offset)
    }
    return max(0,duration*tempoScale-settings.offset,latest)
  }
  func timelineDuration(audioDuration: Double) -> Double {
    max(audioDuration.isFinite ? max(0, audioDuration) : 0, visualDuration) + settings.intro
  }
}

/// Video layout in pixels; workspace sidebars never enter this coordinate system.
struct AudioSceneLayout {
  var cover: CGRect
  var panelX: Float, panelWidth: Float
  var seriesY: Float, titleY: Float, artistY: Float, infoY: Float
  var spectrum: CGRect
  var waveformY: Float, metricsY: Float, noteY: Float
  var chordPoint: SIMD2<Float>
  var titleFont: Float
  var portrait: Bool
  init(settings s: StudioSettings, width w: Float, height h: Float) {
    let scale = h / 720
    portrait = w / h < 1
    titleFont = min(64, (s.audioTemplate == .recordSleeve ? 40 : (s.audioTemplate == .orbit ? 46 : 40)) * Float(s.titleSize / 36)) * scale
    if portrait {
      let size = w * (s.audioTemplate == .spectralField ? 0.32 : 0.52)
      cover = CGRect(x: Double((w-size)/2), y: Double(h*0.20-size/2), width: Double(size), height: Double(size))
      panelX=w*0.10;panelWidth=w*0.80
      titleFont=min(titleFont, 26*scale)
      titleY=h*0.51;seriesY=titleY-30*scale;artistY=titleY+32*scale;infoY=titleY+78*scale
      spectrum=CGRect(x:Double(panelX+28*scale),y:Double(h*0.67),width:Double(panelWidth-28*scale),height:Double(h*0.14))
      waveformY=h*0.855;metricsY=h*0.93;noteY=h*0.985
      chordPoint=SIMD2(w*0.5,h*0.20+size/2+42*scale)
    } else if s.audioTemplate == .recordSleeve {
      let size=min(w*0.297,h*0.528)
      let leftHeight=size+93*scale
      cover=CGRect(x:Double(w*0.205-size/2),y:Double((h-leftHeight)/2),width:Double(size),height:Double(size))
      let titleHeight=max(48*scale,titleFont*1.2)
      let groupHeight=440*scale+titleHeight
      var y=(h-groupHeight)/2
      seriesY=y+6.5*scale;y+=27*scale
      titleY=y+titleHeight/2;y+=titleHeight+14*scale
      artistY=y+10.5*scale;y+=35*scale
      infoY=y+20*scale;y+=54*scale
      panelX=w*0.40;panelWidth=w*0.544
      spectrum=CGRect(x:Double(panelX+40*scale),y:Double(y),width:Double(panelWidth-40*scale),height:Double(154*scale))
      y+=194*scale;waveformY=y+14*scale;y+=42*scale
      metricsY=y+8*scale;noteY=y+68*scale
      chordPoint=SIMD2(w*0.205,Float(cover.maxY)+61*scale)
    } else if s.audioTemplate == .spectralField {
      cover=CGRect(x:Double(w*0.05),y:Double(48*scale),width:Double(108*scale),height:Double(108*scale))
      panelX=w*0.05+132*scale;panelWidth=w*0.62
      seriesY=65*scale;titleY=105*scale;artistY=143*scale;infoY=100*scale
      spectrum=CGRect(x:Double(w*0.05+40*scale),y:Double(180*scale),width:Double(w*0.90-40*scale),height:Double(298*scale))
      waveformY=549*scale;metricsY=605*scale;noteY=684*scale
      chordPoint=SIMD2(w*0.16,631*scale)
    } else {
      let size=min(w*0.20,256*scale)
      cover=CGRect(x:Double(w*0.162-size/2),y:Double(272*scale-size/2),width:Double(size),height:Double(size))
      panelX=w*0.30625;panelWidth=w*0.64375
      seriesY=65*scale;titleY=113*scale;artistY=153*scale;infoY=211*scale
      spectrum=CGRect(x:Double(panelX+36*scale),y:Double(256*scale),width:Double(panelWidth-36*scale),height:Double(217*scale))
      waveformY=530*scale;metricsY=575*scale;noteY=639*scale
      chordPoint=SIMD2(Float(cover.midX),Float(cover.maxY)+53*scale)
    }
  }
}
struct ExportStatistics: Codable {
  var width: Int
  var height: Int
  var fps: Int
  var frames: Int
  var duration: Double
  var elapsed: Double
  var framesPerSecond: Double
  var realtimeMultiple: Double
  var codec: String
  var hardwareRequired: Bool
  var gpuName: String
  var peakResidentMB: Double
  var outputBytes: Int64
  var maxFramesInFlight: Int
  var cpuBuildMeanMS: Double
  var gpuMeanMS: Double
  var audioIncluded: Bool
  var rendererBackend: String? = nil
}
enum StudioError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    switch self {
    case .message(let value): return value
    }
  }
}
func lowerBound<T>(_ list: [T], _ value: Double, key: (T) -> Double) -> Int {
  var a = 0
  var b = list.count
  while a < b {
    let m = (a + b) / 2
    if key(list[m]) < value { a = m + 1 } else { b = m }
  }
  return a
}

/// A max-end interval tree prunes expired sustained notes and never scans the whole song per frame.
final class NoteIndex {
  let notes: [MIDINote]
  let base: Int
  let maxEnd: [Double]
  init(_ source: [MIDINote]) {
    notes = source.sorted { $0.start < $1.start }
    var b = 1
    while b < notes.count { b *= 2 }
    base = b
    var tree = Array(repeating: -Double.infinity, count: b * 2)
    for i in notes.indices { tree[b + i] = notes[i].end }
    if b > 1 {
      for i in stride(from: b - 1, through: 1, by: -1) {
        tree[i] = max(tree[i * 2], tree[i * 2 + 1])
      }
    }
    maxEnd = tree
  }
  func forEach(from: Double, to: Double, _ body: (Int, MIDINote) -> Void) {
    let limit = lowerBound(notes, to, key: { $0.start })
    guard limit > 0 else { return }
    func visit(_ node: Int, _ left: Int, _ right: Int) {
      if left >= limit || maxEnd[node] < from { return }
      if right - left == 1 {
        if left < notes.count { body(left, notes[left]) }
        return
      }
      let middle = (left + right) / 2
      visit(node * 2, left, middle)
      visit(node * 2 + 1, middle, right)
    }
    visit(1, 0, base)
  }
}

struct TitleEntrance {
  var alpha:Float,scale:Float,shift:Float
  var text:String
  static func state(settings:StudioSettings,time:Double,text:String)->TitleEntrance {
    let phase=Float(min(1,max(0,time/settings.titleMotionDuration)))
    return TitleEntrance(alpha:settings.titleMotion == .none ? 1:phase,
      scale:settings.titleMotion == .scale ? 0.7+phase*0.3:1,
      shift:settings.titleMotion == .slide ? (1-phase)*30:0,
      text:settings.titleMotion == .typewriter ? String(text.prefix(Int(Float(text.count)*phase))):text)
  }
}
