//
//  ServersPanel.swift
//  Blocky
//
//  PART 7 — Recommended multiplayer servers. Every row pings the real
//  Minecraft protocol, so what you see is proof it is connectable: version
//  label, live player counts, latency, MOTD. Tap a tile to launch straight
//  into that server (the address is written to servers.dat so it shows in
//  Minecraft's multiplayer list).
//

import SwiftUI
import BlockyKit

@MainActor
final class ServerStatusModel: ObservableObject {
    @Published private(set) var statuses: [UUID: ServerStatus] = [:]

    private let client = ServerPingClient()

    func status(for entry: ServerEntry) -> ServerStatus {
        statuses[entry.id] ?? ServerStatus(state: .checking)
    }

    /// Pings any entry not already being probed. Concurrent, bounded.
    func refreshAll() {
        let entries = ServerDirectory.recommended
        for entry in entries where statuses[entry.id] == nil {
            statuses[entry.id] = ServerStatus(state: .checking)
        }
        Task.detached { [client] in
            await withTaskGroup(of: (UUID, ServerStatus).self) { group in
                for entry in entries {
                    group.addTask { (entry.id, await client.ping(entry)) }
                }
                for await (id, status) in group {
                    await MainActor.run { self.statuses[id] = status }
                }
            }
        }
    }
}

extension ServerStatus {
    var dotColor: Color {
        switch state {
        case .online:     return Color.green
        case .offline:    return Color.red.opacity(0.8)
        case .unreachable: return Color.orange
        case .checking:   return Color.secondary.opacity(0.4)
        }
    }

    var summary: String {
        switch state {
        case .online:
            if let online = playersOnline, let max = playersMax {
                return "\(online)/\(max) playing" + (latencyMS.map { " · \($0)ms" } ?? "")
            }
            return "online" + (latencyMS.map { " · \($0)ms" } ?? "")
        case .offline:    return "offline now"
        case .unreachable: return "can't reach"
        case .checking:   return "checking…"
        }
    }
}

// MARK: - Chips (main column)

/// The main column's marquee: cracked-friendly servers as compact scrollable
/// tiles. Tap a tile and Minecraft joins that server as soon as it boots.
struct ServerChips: View {
    @ObservedObject var model: ServerStatusModel
    var launchServer: (ServerEntry) -> Void
    var showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PLAY WITH FRIENDS")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .kerning(1.8)
                    .foregroundStyle(.tertiary)
                    .legibleShadow()
                Spacer()
                Button("see all") { showAll() }
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                    .buttonStyle(.link)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ServerDirectory.recommended) { entry in
                        tile(entry)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func tile(_ entry: ServerEntry) -> some View {
        let status = model.status(for: entry)
        let online = status.playersOnline ?? 0
        let max = status.playersMax ?? 0
        let latency = status.latencyMS.map { "\($0)ms" } ?? "—"
        let isOnline = status.state == .online

        return VStack(spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(status.dotColor)
                    .frame(width: 6, height: 6)
                Text(entry.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)
            }

            if isOnline, max > 0 {
                Text("\(online)/\(max) · \(latency)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(status.summary)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: true)
        .frame(minWidth: 108)
        .blockyBox(10, scrim: 0.20, lift: 0.16)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: status.state)
        .onTapGesture {
            launchServer(entry)
        }
        .help("Join \(entry.address) when Minecraft opens")
    }
}

// MARK: - Full list (sheet)

struct ServersSheet: View {
    @ObservedObject var model: ServerStatusModel
    var launchServer: (ServerEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customAddress = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SERVERS")
                .font(.system(size: 15, weight: .heavy, design: .monospaced))
                .kerning(3)

            HStack(spacing: 8) {
                TextField("mc.example.org", text: $customAddress)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .blockyBox(8, scrim: 0.12, lift: 0.12)
                    .onSubmit(joinTyped)
                Button("Join") { joinTyped() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color.accentColor)
                    .disabled(ServerDirectory.parseAddress(customAddress) == nil)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(ServerDirectory.recommended) { entry in
                        row(entry)
                    }
                }
            }

            HStack {
                Text("Minecraft joins the server as soon as it opens")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(22)
        .frame(width: 460, height: 460)
        .onAppear { model.refreshAll() }
    }

    private func joinTyped() {
        guard let entry = ServerDirectory.parseAddress(customAddress) else { return }
        launchServer(entry)
    }

    private func row(_ entry: ServerEntry) -> some View {
        let status = model.status(for: entry)
        return HStack(spacing: 10) {
            Circle()
                .fill(status.dotColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(entry.blurb)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.address)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Text(status.summary)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let motd = status.motd, !motd.isEmpty {
                    Text(motd)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .blockyBox(10, scrim: 0.10, lift: 0.20)
        .contentShape(Rectangle())
        .onTapGesture {
            launchServer(entry)
        }
        .help("Join \(entry.address) when Minecraft opens")
    }
}
