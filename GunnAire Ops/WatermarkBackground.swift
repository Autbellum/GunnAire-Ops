import SwiftUI

// A reusable watermark background with the app logo
struct WatermarkBackground: View {
    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .opacity(0.08)
            .blur(radius: 1)
            .allowsHitTesting(false)
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
