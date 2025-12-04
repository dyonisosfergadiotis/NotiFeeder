import Foundation
import BackgroundTasks
import SwiftUI

final class BackgroundRefreshManager {
    static let shared = BackgroundRefreshManager()
    private init() {}

    static let taskIdentifier = "de.dyonisos.NotiFeeder.refresh"

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            if let refreshTask = task as? BGAppRefreshTask {
                self.handle(refreshTask)
            } else {
                task.setTaskCompleted(success: false)
            }
        }
    }

    func schedule(after interval: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            #if DEBUG
            print("BGTask submit failed: \(error)")
            #endif
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        // Always reschedule for the next time
        schedule()

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        // Replace this block with your real refresh logic (fetch feeds, update store, schedule local notifications as needed)
        let refreshOp = BlockOperation {
            // TODO: Perform your background fetch/update here
            Thread.sleep(forTimeInterval: 2) // simulate work
        }

        task.expirationHandler = {
            queue.cancelAllOperations()
        }

        refreshOp.completionBlock = {
            let success = !refreshOp.isCancelled
            task.setTaskCompleted(success: success)
        }

        queue.addOperation(refreshOp)
    }
}

// A small helper to wire setup into SwiftUI App entry without touching App file here.
struct BackgroundRefreshSetupModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                BackgroundRefreshManager.shared.register()
                BackgroundRefreshManager.shared.schedule()
            }
    }
}

extension View {
    func enableBackgroundRefresh() -> some View {
        modifier(BackgroundRefreshSetupModifier())
    }
}

#Preview {
    Text("Hello")
        .enableBackgroundRefresh()
}
