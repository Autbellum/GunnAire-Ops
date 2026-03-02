import SwiftUI

struct PaymentsAndReceiptsView: View {
    @State private var paymentProcessingMessage: String = ""
    
    var body: some View {
        ZStack {
            WatermarkBackground()
            VStack(spacing: 16) {
                Text("Payments & Receipts")
                    .font(.largeTitle)
                    .foregroundColor(Color.brandGold)
                    .padding()
                Text("Track payments received and generate receipts.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .foregroundColor(.primary)
                Button("Record Payment") {
                    // TODO: Present payment recording UI
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandGold)
                .padding()
                Button("Tap to Pay") {
                    performTapToPay()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandGold)
                if !paymentProcessingMessage.isEmpty {
                    Text(paymentProcessingMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                Spacer()
            }
        }
        .navigationTitle("Payments & Receipts")
        .foregroundColor(Color.brandGold)
    }
    
    private func performTapToPay() {
        paymentProcessingMessage = "Starting Tap to Pay session..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            paymentProcessingMessage = "Tap to Pay completed (stub). Integrate actual payment processing logic."
        }
    }
}

#Preview {
    PaymentsAndReceiptsView()
}
