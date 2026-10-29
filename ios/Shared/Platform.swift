import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
extension Image { init(platformImage: NSImage) { self.init(nsImage:platformImage) } }
private func dynamic(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(nsColor:NSColor(name:nil) { $0.bestMatch(from:[.darkAqua, .aqua]) == .darkAqua ? NSColor(red:dark.0, green:dark.1, blue:dark.2, alpha:1) : NSColor(red:light.0, green:light.1, blue:light.2, alpha:1) })
}
#else
import UIKit
typealias PlatformImage = UIImage
extension Image { init(platformImage: UIImage) { self.init(uiImage:platformImage) } }
private func dynamic(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(uiColor:UIColor { $0.userInterfaceStyle == .dark ? UIColor(red:dark.0, green:dark.1, blue:dark.2, alpha:1) : UIColor(red:light.0, green:light.1, blue:light.2, alpha:1) })
}
#endif

extension Color {
    static let notebookPaper = dynamic((0.961, 0.961, 0.953), (0.075, 0.075, 0.071))
    static let notebookBlue = dynamic((0.184, 0.420, 1), (0.365, 0.545, 1))
}
