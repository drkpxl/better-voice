import Foundation

@MainActor
final class ModuleManager {
    private var modules: [String: BetterVoiceModule] = [:]

    /// The currently active module (hotkey events are routed to this module)
    var activeModule: BetterVoiceModule? {
        modules.values.first { $0.isActive }
    }

    var moduleNames: [String] {
        Array(modules.keys)
    }

    func register(_ module: BetterVoiceModule) {
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
