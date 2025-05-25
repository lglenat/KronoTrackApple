import Foundation
import UserNotifications
import UIKit

class NotificationManager {
    static let shared = NotificationManager()
    private var trackingNotificationIdentifier = "trackingStatusPersistent"
    
    private init() {}

    func showTrackingNotification(isTracking: Bool) {
        if isTracking {
            // Create a persistent notification for active tracking
            createPersistentTrackingNotification()
        } else {
            // When tracking stops, remove the persistent notification and show a one-time notification
            removePersistentTrackingNotification()
            showOneTimeNotification(title: NSLocalizedString("Krono Location: Tracking Stopped", comment: "Tracking stopped notification title"),
                                   body: NSLocalizedString("Tracking has stopped.", comment: "Tracking stopped notification body"))
        }
    }
    
    private func createPersistentTrackingNotification() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Krono Location: Tracking Active", comment: "Tracking active notification title")
        content.body = NSLocalizedString("Your location is being uploaded every minute.", comment: "Tracking active notification body")
        content.sound = nil // No sound for persistent notification
        
        // Make it ongoing by repeating every minute
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: true)
        
        let request = UNNotificationRequest(identifier: trackingNotificationIdentifier, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error adding persistent notification: \(error)")
            }
        }
    }
    
    private func removePersistentTrackingNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [trackingNotificationIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [trackingNotificationIdentifier])
    }
    
    private func showOneTimeNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error showing one-time notification: \(error)")
            }
        }
    }
}
