import SwiftUI

/// A client's visual mark: the uploaded logo when present, otherwise a
/// brand-color dot. Used in the client list, dashboard cards, and settings.
struct ClientAvatar: View {
    let client: ClientConfig
    var size: CGFloat = 14

    var body: some View {
        if let image = LogoStore.image(named: client.logoFileName) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
        } else {
            Circle()
                .fill(Color(hex: client.colorHex))
                .frame(width: size * 0.7, height: size * 0.7)
                .frame(width: size, height: size)
        }
    }
}
