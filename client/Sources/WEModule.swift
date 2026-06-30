import Foundation

/// The module protocol in the Shell + Module architecture
/// Currently only VoiceModule exists; Chat/Files/Tools can be added in the future
@MainActor
protocol WEModule: AnyObject {
    var name: String { get }
    var isActive: Bool { get set }

    func onHotKeyDown()
    func onHotKeyUp()
}
