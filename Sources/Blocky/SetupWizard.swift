//
//  SetupWizard.swift
//  Blocky
//
//  PART 6 — The first-run wizard. Four rows that tell the truth about the
//  machine (folder, versions, Homebrew, Java) and offer one-tap fixes for
//  the two that can actually break. Everything runs visibly — the same
//  terminal the launcher uses, not a hidden dialog.
//

import SwiftUI
import BlockyKit

struct SetupWizardView: View {
    @ObservedObject var manager: SetupManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(spacing: 8) {
                ForEach(manager.rows) { row in
                    rowView(row)
                }
            }

            if !manager.stream.isEmpty {
                terminal
            }

            HStack {
                Spacer()
                Button("Start playing") {
                    manager.markSetupComplete()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Color.accentColor)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { manager.runChecks() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BLOCKY SETUP")
                .font(.system(size: 15, weight: .heavy, design: .monospaced))
                .kerning(3)
            Text("Blocky checks the four things a Minecraft launch needs, and fixes the two that commonly break — right here.")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepsReady: Int {
        manager.rows.filter(\.isOK).count
    }

    // MARK: Rows

    private func rowView(_ row: SetupManager.Row) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stateGlyph(row.state)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .kerning(1.4)
                    .foregroundStyle(.primary)
                Text(row.detail)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if let action = row.actionTitle {
                    Button(action) { manager.performAction(for: row) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(Color.accentColor)
                        .disabled(row.state == .fixing || row.state == .blocked)
                }
                if let secondary = row.secondaryTitle {
                    Button(secondary) { manager.performSecondary(for: row) }
                        .buttonStyle(.link)
                        .font(.system(size: 9, design: .monospaced))
                }
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .blockyBox(10, scrim: 0.10, lift: 0.18)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(edgeColor(for: row.state), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func stateGlyph(_ state: SetupManager.Row.State) -> some View {
        switch state {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        case .todo:
            Image(systemName: "circle")
                .foregroundStyle(Color.accentColor)
        case .blocked:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
        case .fixing:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.red)
        }
    }

    private func edgeColor(for state: SetupManager.Row.State) -> Color {
        switch state {
        case .ok:      return Color.primary.opacity(0.10)
        case .todo:    return Color.accentColor.opacity(0.45)
        case .blocked: return Color.primary.opacity(0.08)
        case .fixing:  return Color.accentColor.opacity(0.6)
        case .failed:  return Color.red.opacity(0.55)
        }
    }

    // MARK: Terminal

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(manager.stream.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 110)
            .blockyBox(8, scrim: 0.34, lift: 0.18)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .onChange(of: manager.stream.count) { _ in
                if let last = manager.stream.last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}
