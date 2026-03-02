import SwiftUI

// A reusable watermark background with the app logo
struct WatermarkBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .padding(80)
                .opacity(0.035)
                .allowsHitTesting(false)
        }
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
