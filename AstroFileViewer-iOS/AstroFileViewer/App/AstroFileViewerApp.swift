// v1.0.0
import SwiftUI

@main
struct AstroFileViewerApp: App {
    @StateObject private var viewModel = ViewerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onOpenURL { url in
                    viewModel.openFile(url: url)
                }
        }
    }
}
