// Holds a weak reference to the currently active TriageViewModel so MCP tools
// can ask it to apply marks / read images. ContentViewSupport pokes the
// reference in via .onAppear once the view model is constructed.
//
// Weak so we don't hold the view model alive after the window goes away.
import Foundation

@MainActor
final class MCPViewModelBridge {
    static let shared = MCPViewModelBridge()
    weak var viewModel: TriageViewModel?
    private init() {}
}
