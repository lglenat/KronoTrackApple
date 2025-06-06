import Foundation
import UserNotifications
import UIKit

class NotificationManager {
    static let shared = NotificationManager()
    private let trackingNotificationIdentifier = "trackingStatus"
    
    private init() {}

    func showTrackingNotification(isTracking: Bool) {
        if isTracking {
            // Remove any existing previous notifications
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            // Create a one-time notification to inform user that tracking is active
            showTrackingActiveNotification()
        } else {
            // When tracking stops, remove the tracking notification, keep others
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [trackingNotificationIdentifier])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [trackingNotificationIdentifier])
        }
    }
    
    private func showTrackingActiveNotification() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("KronoTrack: location tracking active.", comment: "Tracking active notification title")
        content.body = NSLocalizedString("Background location tracking enabled.", comment: "Tracking active notification body")
        content.sound = .default
        
        // Create a simple request with no trigger (delivers immediately)
        let request = UNNotificationRequest(identifier: trackingNotificationIdentifier, content: content, trigger: nil)
        
        // Add to notification center
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error showing tracking notification: \(error)")
            }
        }
    }
    
    func showSimpleNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error showing simple notification: \(error)")
            }
        }
    }
}
