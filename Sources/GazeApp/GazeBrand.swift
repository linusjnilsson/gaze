import SwiftUI

// Brand colors. The named colors live in Assets.xcassets.
// AccentColor switches automatically: deep mint in light mode, mint in dark mode.
extension Color {
    static let gazeMint = Color("BrandMint")          // #5EEAB5
    static let gazeMintDeep = Color("BrandMintDeep")  // #0E9F6E
    static let gazeInk = Color("BrandInk")            // #101314
}

/// The Gaze mark drawn in code: a faded back window and a solid front window.
/// Scales to any size and takes its color from `foregroundStyle`.
struct GazeMark: View {
    var backOpacity: Double = 0.35

    var body: some View {
        GeometryReader { geo in
            let u = min(geo.size.width, geo.size.height) / 64
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 9 * u, style: .continuous)
                    .frame(width: 35 * u, height: 35 * u)
                    .offset(x: 7 * u, y: 7 * u)
                    .opacity(backOpacity)
                RoundedRectangle(cornerRadius: 9 * u, style: .continuous)
                    .frame(width: 35 * u, height: 35 * u)
                    .offset(x: 22 * u, y: 22 * u)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Menu bar icon. Template images adapt to light and dark menu bars automatically.
enum GazeMenuBarIcon {
    static func image(paused: Bool) -> NSImage {
        let image = NSImage(named: paused ? "MenuBarIconPaused" : "MenuBarIcon") ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

