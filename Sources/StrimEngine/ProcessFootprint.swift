import Darwin
import Foundation

/// The kernel's `phys_footprint` for this process: the number Activity Monitor and jetsam use. It
/// includes Metal buffers (wired GPU allocations), which RSS does not, so it is the figure the
/// memory budget must be held against.
enum ProcessFootprint {
    static func bytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
