//
//  AutoCaptionView+FormCards.swift
//  Strophe
//
//  Created by Antigravity on 2026/07/12.
//

import SwiftUI

extension AutoCaptionView {

    @ViewBuilder
    func recognitionChoiceCard(
        title: String,
        systemImage: String,
        status: String,
        detail: String,
        isProminent: Bool,
        isAvailable: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isProminent && isAvailable ? Color.stropheAccent : .secondary)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(LocalizedStringKey(title))
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)

                    Spacer()

                    Text(LocalizedStringKey(status))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(isAvailable ? Color.stropheAccent : .secondary)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stropheSecondaryBackground.opacity(isProminent ? 0.7 : 0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isProminent && isAvailable ? Color.stropheAccent.opacity(0.55) : Color.stropheBorder, lineWidth: 1)
        )
        .opacity(isAvailable ? 1.0 : 0.62)
    }

    @ViewBuilder
    var cloudConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("cloud_recognition", systemImage: "cloud")
                    .font(.headline)
                    .foregroundStyle(Color.stropheText)

                Spacer()

                Text("available")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.stropheAccent)
            }

            HStack {
                Text("server_address")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(AIBackendClient.defaultCloudBaseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(Color.stropheText)
                    .lineLimit(1)
            }

            HStack {
                Text("subtitle_mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("full_sentence")
                    .font(.caption)
                    .foregroundStyle(Color.stropheText)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.stropheBorder, lineWidth: 1)
            )
    }

    @ViewBuilder
    var mediaStatusCard: some View {
        if project.videoURL == nil {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("no_media_loaded_1")
                        .fontWeight(.semibold)
                    Text("please_import_a_video_or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.stropheSecondaryBackground)
            .cornerRadius(12)
        } else {
            HStack {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(Color.stropheAccent)
                Text("current_media_format \(project.documentDisplayName)")
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(Color.stropheText)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.stropheSecondaryBackground)
            .cornerRadius(12)
        }
    }
}
