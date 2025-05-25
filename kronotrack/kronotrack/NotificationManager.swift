import Foundation
import UserNotifications
import UIKit

class NotificationManager {
    static let shared = NotificationManager()
    private let trackingNotificationIdentifier = "trackingStatus"
    
    private init() {}

    func showTrackingNotification(isTracking: Bool) {
        if isTracking {
            // Create a one-time notification to inform user that tracking is active
            showTrackingActiveNotification()
        } else {
            // When tracking stops, just remove any existing notifications
            clearTrackingNotifications()
        }
    }
    
    private func showTrackingActiveNotification() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Krono Location: Tracking Active", comment: "Tracking active notification title")
        content.body = NSLocalizedString("Your location is being uploaded every minute.", comment: "Tracking active notification body")
        content.sound = .default
        content.categoryIdentifier = "TRACKING_STATUS"
        
        // Create a request for immediate delivery (no trigger)
        let request = UNNotificationRequest(identifier: trackingNotificationIdentifier, content: content, trigger: nil)
        
        // Add to notification center
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error showing tracking notification: \(error)")
            }
        }
    }
    
    private func clearTrackingNotifications() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [trackingNotificationIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [trackingNotificationIdentifier])
    }
}
