import SwiftUI

// A reusable watermark background with the app logo. Anchored to a corner
// and mostly clipped off-screen so it never sits behind primary content —
// centering it previously placed it directly behind card text and numbers.
struct WatermarkBackground: View {
    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 520)
            .opacity(0.012)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: 160, y: 160)
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
