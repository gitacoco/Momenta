import SwiftUI

/// A client's visual mark: the uploaded logo when present, otherwise a
/// brand-color dot. Used in the client list, dashboard cards, and settings.
struct ClientAvatar: View {
    // Emphasized inside a focused list row's selection, where the accent fill
    // would otherwise swallow a transparent logo or a dark brand color.
    @Environment(\.backgroundProminence) private var backgroundProminence

    let client: ClientConfig
    var size: CGFloat = 14

    private var needsBacking: Bool {
        backgroundProminence == .increased
    }

    var body: some View {
        if let image = LogoStore.image(named: client.logoFileName) {
            let shape = RoundedRectangle(cornerRadius: size * 0.25)
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(shape)
                .background {
                    if needsBacking {
                        shape.fill(.white)
                    }
                }
        } else {
            Circle()
                .fill(Color(hex: client.colorHex))
                .frame(width: size * 0.7, height: size * 0.7)
                .frame(width: size, height: size)
                .background {
                    if needsBacking {
                        Circle().fill(.white)
                    }
                }
        }
    }
}
