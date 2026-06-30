import Foundation

@MainActor
final class ModuleManager {
    private var modules: [String: WEModule] = [:]

    /// The currently active module (hotkey events are routed to this module)
    var activeModule: WEModule? {
        modules.values.first { $0.isActive }
    }

    var moduleNames: [String] {
        Array(modules.keys)
    }

    func register(_ module: WEModule) {
        modules[module.name] = module
        // The first registered module is active by default
        if modules.count == 1 {
            module.isActive = true
        }
        Logger.log("ModuleManager", "Registered module: \(module.name)")
    }

    func activate(_ name: String) {
        for (key, module) in modules {
            module.isActive = (key == name)
        }
    }
}
