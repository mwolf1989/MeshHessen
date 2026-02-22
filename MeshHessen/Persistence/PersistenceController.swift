import CoreData
import Foundation

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "MeshHessen")
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { [weak self] _, error in
            guard let self else { return }

            self.container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            self.container.viewContext.automaticallyMergesChangesFromParent = true
            self.container.viewContext.retainsRegisteredObjects = true

            if let error {
                AppLogger.shared.log("[Persistence] Failed to load persistent store: \(error.localizedDescription)")
            } else {
                AppLogger.shared.log("[Persistence] Persistent store loaded", debug: true)
            }
        }
    }

    /// Initializer that accepts a pre-built NSManagedObjectModel — used by SPM unit tests
    /// where .xcdatamodeld cannot be compiled into a .momd resource.
    init(managedObjectModel: NSManagedObjectModel, inMemory: Bool = true) {
        container = NSPersistentContainer(name: "MeshHessen", managedObjectModel: managedObjectModel)
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { [weak self] _, error in
            guard let self else { return }
            self.container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            self.container.viewContext.automaticallyMergesChangesFromParent = true
            self.container.viewContext.retainsRegisteredObjects = true
        }
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = true
        return context
    }
}
