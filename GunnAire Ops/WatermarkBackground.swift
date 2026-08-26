import SwiftUI

// A reusable watermark background with the app logo
struct WatermarkBackground: View {
    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 520)
            .opacity(0.025)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .ignoresSafeArea()
    }
}

#Preview {
    ZStack {
        WatermarkBackground()
        Text("Preview")
            .padding()
    }
}
