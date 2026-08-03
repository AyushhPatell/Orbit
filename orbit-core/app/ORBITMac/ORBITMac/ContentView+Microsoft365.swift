//
//  ContentView+Microsoft365.swift
//  ORBITMac
//

import SwiftUI

extension ContentView {

    var microsoft365Disclosure: some View {
        DisclosureGroup(isExpanded: $microsoft365Expanded) {
            VStack(alignment: .leading, spacing: ORBITLayout.innerSpacing) {
                Text(
                    "Read-only mail and Teams chat lists via Microsoft Graph. Create a public client app in Azure Portal (Allow public client flows), add delegated permissions Mail.Read and Chat.Read, then paste the Application (client) ID."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                TextField("Application (client) ID", text: $graphClientIdStorage)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                HStack(spacing: 10) {
                    Button {
                        graphSession.signInWithDeviceCode()
                    } label: {
                        Label("Sign in\u{2026}", systemImage: "person.badge.key")
                    }
                    .disabled(graphClientIdStorage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || graphSession.isSigningIn)

                    Button("Sign out") {
                        graphSession.signOut()
                        graphPreviewText = nil
                    }
                    .disabled(!graphSession.isSignedIn)

                    if graphSession.isSigningIn {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .font(.caption)

                if let s = graphSession.statusMessage, !s.isEmpty {
                    Text(s)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let e = graphSession.lastError, !e.isEmpty {
                    Text(e)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Button("Recent mail") {
                        Task {
                            isLoadingGraphPreview = true
                            defer { isLoadingGraphPreview = false }
                            graphPreviewText = await graphSession.fetchRecentMailPreview()
                        }
                    }
                    .disabled(!graphSession.isSignedIn || isLoadingGraphPreview)

                    Button("Recent chats") {
                        Task {
                            isLoadingGraphPreview = true
                            defer { isLoadingGraphPreview = false }
                            graphPreviewText = await graphSession.fetchRecentChatsPreview()
                        }
                    }
                    .disabled(!graphSession.isSignedIn || isLoadingGraphPreview)

                    if isLoadingGraphPreview {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .font(.caption)

                if let p = graphPreviewText, !p.isEmpty {
                    Text(p)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "envelope.badge.person.crop")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Microsoft 365")
                        .font(.subheadline.weight(.medium))
                    Text(
                        graphSession.isSignedIn
                            ? "Signed in \u{00B7} Mail & Teams chat previews"
                            : "Outlook / Teams read-only (optional)"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
