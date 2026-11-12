import Darwin
import SwiftUI

/// `-CameraMonitorDiagnostics YES`: shows the app's memory footprint over
/// the player so long-running device tests can check it doesn't grow.
struct DiagnosticsBadge: View {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "CameraMonitorDiagnostics") }

    @State private var megabytes = 0

    var body: some View {
        Text("\(megabytes) MB")
            .font(.caption.monospacedDigit())
            .padding(4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityIdentifier("diagnostics.memory")
            .accessibilityValue("\(megabytes)")
            .task {
                while !Task.isCancelled {
                    megabytes = Self.footprintMB()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
