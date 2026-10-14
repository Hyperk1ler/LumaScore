import AppKit

/// Only locally installed fonts. No downloads, network or external font registration.
enum FontCatalog {
  static let families:[String] = NSFontManager.shared.availableFontFamilies.sorted()
  private static let familySet=Set(families)
  private static let cache=NSCache<NSString,NSFont>()
  static func font(family:String,size:CGFloat,weight:NSFont.Weight = .medium)->NSFont {
    let key="\(family)|\(size)|\(weight.rawValue)" as NSString
    if let font=cache.object(forKey:key){return font}
    let fallback=NSFont.systemFont(ofSize:size,weight:weight)
    let font = family != "System" && familySet.contains(family) ? (NSFont(name:family,size:size) ?? NSFontManager.shared.convert(fallback,toFamily:family)):fallback
    cache.setObject(font,forKey:key);return font
  }
}
