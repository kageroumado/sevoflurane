import Propofol
import SwiftUI

/// The three numbers behind the Custom thread-waiting preset, editable the
/// way a game's own advanced settings are.
struct TuningParametersFields: View {
    @Binding var parameters: TuningParameters

    private static let fieldWidth: CGFloat = 90

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            spin("Wait spin", value: $parameters.waitSpin)
            spin("Object spin", value: $parameters.objectSpin)
            Toggle("Reduce spinning after repeated misses", isOn: $parameters.adaptive)
            Text("Each iteration takes about 0.4 ns. 5200 iterations take two microseconds; 0 disables spinning.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, Theme.Space.lg)
    }

    private func spin(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField(title, value: clamped(value), format: .number.grouping(.never))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: Self.fieldWidth)
        }
    }

    private func clamped(_ value: Binding<Int>) -> Binding<Int> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, TuningParameters.spinRange.lowerBound), TuningParameters.spinRange.upperBound) },
        )
    }
}
