# Krono Location iOS App

This is the iOS version of the Krono Location app, ported from Android. It allows users to select a marathon event (course), enter their bib number, birth year, and race code, and start/stop GPS tracking. When tracking is started, the app uploads the user's location every minute to the KronoTiming server, even in the background.

## Features
- Select a course from a dropdown (populated from a remote server)
- Enter bib number, date of birth, and race code for authentication
- Start/stop location tracking, get GPX trace from server and show it on a map along with user location
- Location is uploaded every minute in the background
- Notifications for tracking state and errors

## Technologies
- Swift, SwiftUI, iOS 15+
- MapKit for maps
- CoreLocation for background location
- URLSession for networking
- UserNotifications for notifications

## Notes
- The app uses iOS background location best practices to ensure location is uploaded even if the app is in the background or the screen is off (as much as iOS allows)
- Branding, endpoints, and features match the Android version as closely as possible
