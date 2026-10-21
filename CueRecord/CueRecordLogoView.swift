import SwiftUI

struct CueRecordLogoView: View {
    var cornerRadius: CGFloat = 8

    var body: some View {
        Image("录课台Logo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .aspectRatio(1, contentMode: .fit)
    }
}
