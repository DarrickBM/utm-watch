import SwiftUI
import UTMWatchCore

/// Pointer position inside the brief, in the brief's own coordinates (origin top-left).
/// The hover panel belongs to an inactive app, where SwiftUI's own hover tracking is not dependable,
/// so the status item controller feeds the position it already polls.
final class BriefPointer: ObservableObject {
    @Published var point: CGPoint?
}

private struct ExplainFrame: Equatable {
    var rect: CGRect
    var text: String
}

private struct ExplainFramesKey: PreferenceKey {
    static var defaultValue: [ExplainFrame] = []
    static func reduce(value: inout [ExplainFrame], nextValue: () -> [ExplainFrame]) { value.append(contentsOf: nextValue()) }
}

/// The compact summary shown when hovering the menu bar item.
struct BriefView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var showsHint: Bool
    @ObservedObject var pointer = BriefPointer()
    /// Called when the content height may have changed (an explanation appeared or went away).
    var onLayoutChange: () -> Void = {}

    @State private var explanation: String?
    @State private var frames: [ExplainFrame] = []

    private func explanation(at point: CGPoint?) -> String? {
        guard let point else { return nil }
        return frames.first { $0.rect.insetBy(dx: 0, dy: -3).contains(point) }?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("UTM Watch").font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("Live, every \(Int(model.snapshot?.intervalSeconds ?? 2)) s").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if let snap = model.snapshot {
                let vms = snap.rows.filter { $0.pid != nil }
                if vms.isEmpty {
                    Text("No VM running").foregroundStyle(.secondary)
                }
                ForEach(vms, id: \.id) { vm in
                    VMBriefRow(vm: vm, units: settings.rateUnits, explanation: $explanation)
                    Divider()
                }
                HostBrief(host: snap.host, explanation: $explanation)
                ForEach(snap.notices, id: \.self) { note in
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Collecting first sample…").foregroundStyle(.secondary)
            }

            // The explanation area is reserved at the height of the longest explanation that could show,
            // so the panel keeps one size whether or not a value is being hovered.
            let possible = model.snapshot.map(Self.explanations) ?? []
            if !possible.isEmpty {
                ZStack(alignment: .topLeading) {
                    ForEach(possible, id: \.self) { callout($0).hidden() }
                    if let explanation {
                        callout(explanation)
                    } else {
                        Text("Hover a value marked with a warning sign to see what it means")
                            .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
            } else if showsHint {
                Text("Click the menu bar item to open details and history")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: 392)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .coordinateSpace(name: "brief")
        .onPreferenceChange(ExplainFramesKey.self) { frames = $0 }
        .onChange(of: pointer.point) { _, point in
            let found = explanation(at: point)
            if found != explanation { explanation = found }
        }
        .onChange(of: explanation) { onLayoutChange() }
    }

    private func callout(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Every explanation that hovering could currently bring up.
    private static func explanations(_ s: Snapshot) -> [String] {
        var out = s.rows.filter { $0.pid != nil }.compactMap { Explain.cpu($0) }
        out += [Explain.allocatable(s.host), Explain.cores(s.host), Explain.swap(s.host), Explain.pressure(s.host)].compactMap { $0 }
        return out
    }
}

/// A "label ... value" line. When `explanation` is non-nil the value gets a warning mark and hovering
/// the line shows the explanation at the bottom of the brief.
private struct ValueLine: View {
    let label: String
    let value: String
    let explanation: String?
    @Binding var active: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 8)
            if explanation != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityLabel("Warning")
            }
            Text(value).monospacedDigit().fixedSize()
        }
        .contentShape(Rectangle())
        .background(GeometryReader { geo in
            Color.clear.preference(key: ExplainFramesKey.self,
                                   value: explanation.map { [ExplainFrame(rect: geo.frame(in: .named("brief")), text: $0)] } ?? [])
        })
        .onHover { inside in
            guard let explanation else { return }
            if inside { active = explanation } else if active == explanation { active = nil }
        }
        .onChange(of: explanation) { _, new in
            // The value went back to normal (or changed) while hovered: keep the callout in step.
            if active != nil, active != new { active = new }
        }
    }
}

private struct VMBriefRow: View {
    let vm: VMRow
    let units: RateUnits
    @Binding var explanation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(vm.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("↓ \(Format.rate(vm.downRate, units: units))   ↑ \(Format.rate(vm.upRate, units: units))")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .top, spacing: 14) {
                Meter(label: "CPU", value: Format.cores(vm.cpuCores, vm.cpuAllocated),
                      fraction: fraction(vm.cpuCores, vm.cpuAllocated.map { Double($0) }),
                      explanation: Explain.cpu(vm), active: $explanation)
                Meter(label: "Memory", value: Format.memoryPair(vm.memoryBytes, vm.memoryAllocatedBytes),
                      fraction: fraction(vm.memoryBytes.map { Double($0) }, vm.memoryAllocatedBytes.map { Double($0) }),
                      explanation: nil, active: $explanation)
            }
        }
    }

    private func fraction(_ used: Double?, _ limit: Double?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return min(1, max(0, used / limit))
    }
}

private struct Meter: View {
    let label: String
    let value: String
    let fraction: Double?
    let explanation: String?
    @Binding var active: String?

    var body: some View {
        VStack(spacing: 4) {
            ValueLine(label: label, value: value, explanation: explanation, active: $active)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(explanation == nil ? Color.accentColor : Color.orange)
                        .frame(width: geo.size.width * (fraction ?? 0))
                }
            }
            .frame(height: 5)
        }
    }
}

/// Host figures, one per line so no label is ever truncated.
private struct HostBrief: View {
    let host: HostSummary
    @Binding var explanation: String?

    var body: some View {
        VStack(spacing: 6) {
            ValueLine(label: "Allocatable memory", value: Format.memory(host.allocatable),
                      explanation: Explain.allocatable(host), active: $explanation)
            ValueLine(label: "Cores allocated", value: "\(host.allocatedCores) / \(host.physicalCores)",
                      explanation: Explain.cores(host), active: $explanation)
            ValueLine(label: "Swap",
                      value: host.swapTotal > 0 ? "\(Format.memory(host.swapUsed)) / \(Format.memory(host.swapTotal))" : "off",
                      explanation: Explain.swap(host), active: $explanation)
            ValueLine(label: "Memory pressure", value: host.pressure.rawValue.capitalized,
                      explanation: Explain.pressure(host), active: $explanation)
        }
    }
}
