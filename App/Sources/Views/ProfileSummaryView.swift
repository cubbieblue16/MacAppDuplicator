import SwiftUI

/// Read-only label/value rows for a compatibility profile (`ProfileSummary.rows`), shared by the wizard Review step,
/// the editor's Profile section and Diagnostics.
struct ProfileSummaryView: View {
    let rows: [ProfileSummary.Row]

    var body: some View {
        ForEach(rows) { row in
            LabeledContent(row.label) {
                Text(row.value).textSelection(.enabled)
            }
        }
    }
}
