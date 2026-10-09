import SwiftUI

struct KnownLimitationsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Known Limitations").font(.title2.weight(.semibold))
                Text("These come from how macOS launches and isolates apps. App Duplicator works around what it can and reports the rest.")
                    .foregroundStyle(.secondary)
                ForEach(KnownLimitations.all) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(item.detail).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
