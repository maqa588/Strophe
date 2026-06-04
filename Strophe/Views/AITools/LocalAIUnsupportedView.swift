//
//  LocalAIUnsupportedView.swift
//  Strophe
//
//  Created by Codex on 2026/06/04.
//

import SwiftUI

struct LocalAIUnsupportedView: View {
    var message: String = AIBackendClient.unsupportedDeviceMessage
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.stropheText)

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(Color.stropheSecondaryBackground.opacity(0.7))
        .cornerRadius(12)
    }
}
