//
//  ScriptImportSheet.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

struct ScriptImportSheet: View {
    @Binding var scriptText: String
    @Binding var isPresented: Bool
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("import_script")
                .font(.title2.bold())

            Text("paste_script_instructions")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $scriptText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(minHeight: 240)

            HStack {
                Button("btn_cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import \(lineCount) Segments") {
                    onImport()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        #if os(macOS)
        .frame(height: 400)
        #endif
    }

    private var lineCount: Int {
        scriptText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }
}
