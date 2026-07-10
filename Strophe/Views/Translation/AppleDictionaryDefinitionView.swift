import SwiftUI

struct AppleDictionaryDefinitionView: View {
    let definition: AppleDictionaryDefinition

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(definition.headword)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                if !definition.metadata.isEmpty {
                    Text(definition.metadata)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))

            ForEach(Array(definition.senses.enumerated()), id: \.offset) { index, sense in
                senseView(sense, fallbackNumber: index + 1)
                if index < definition.senses.count - 1 {
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
    }

    private func senseView(_ sense: AppleDictionaryDefinition.Sense, fallbackNumber: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(sense.number ?? "\(fallbackNumber)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.stropheAccent)
                .frame(minWidth: 22, minHeight: 22)
                .background(Color.stropheAccent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 9) {
                if !sense.definition.isEmpty {
                    Text(sense.definition)
                        .font(.body.weight(.medium))
                        .lineSpacing(3)
                }

                ForEach(Array(sense.examples.enumerated()), id: \.offset) { _, example in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.stropheAccent)
                        Text(example)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
