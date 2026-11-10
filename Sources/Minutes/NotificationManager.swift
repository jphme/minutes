import AppKit
import MinutesCore
import UserNotifications

/// macOS notifications: "Meeting detected — Start transcribing" with actions, and "Notes ready".
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    private let detectedID = "meeting-detected"
    private let detectedCategory = "MEETING_DETECTED"
    private let resumeCategory = "MEETING_RESUME"
    private let notesCategory = "NOTES_READY"

    func setup() {
        center.delegate = self
        let start = UNNotificationAction(identifier: "START", title: "Start transcribing", options: [])
        let ignore = UNNotificationAction(identifier: "IGNORE", title: "Not now", options: [])
        let open = UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: detectedCategory, actions: [start, ignore], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: resumeCategory,
                actions: [
                    UNNotificationAction(identifier: "RESUME", title: "Continue previous meeting", options: []),
                    UNNotificationAction(identifier: "START", title: "New meeting", options: []), ignore,
                ], intentIdentifiers: []),
            UNNotificationCategory(identifier: notesCategory, actions: [open], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postMeetingDetected(app: MicApp, eventTitle: String?, resumeTitle: String? = nil) {
        let content = UNMutableNotificationContent()
        let isCall = ["FaceTime", "WhatsApp"].contains(app.name)
        if let resumeTitle {
            content.title = "Rejoined \(app.name)?"
            content.body = "Continue transcribing “\(resumeTitle)”, or start a new meeting."
            content.categoryIdentifier = resumeCategory
        } else {
            content.title = eventTitle ?? (app.name == "Slack" ? "Huddle detected" : isCall ? "Call detected" : "Meeting detected")
            content.body = "\(app.name) is using the microphone. Transcribe this meeting?"
            content.categoryIdentifier = detectedCategory
        }
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: detectedID, content: content, trigger: nil))
    }

    func removeMeetingDetected() {
        center.removeDeliveredNotifications(withIdentifiers: [detectedID])
    }

    func postNotesReady(meeting: Meeting) {
        let content = UNMutableNotificationContent()
        content.title = "Notes ready"
        content.body = meeting.title
        content.categoryIdentifier = notesCategory
        content.userInfo = ["meeting": meeting.id.uuidString]
        center.add(UNNotificationRequest(identifier: "notes-\(meeting.id)", content: content, trigger: nil))
    }

    func postInfo(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Show banners even while the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        let meetingID = (response.notification.request.content.userInfo["meeting"] as? String).flatMap(UUID.init)
        Task { @MainActor in
            let model = AppModel.shared
            switch (category, action) {
            case (resumeCategory, "RESUME"), (resumeCategory, UNNotificationDefaultActionIdentifier):
                if let m = model.resumable { await model.resumeRecording(m) } else { await model.startRecording() }
                if action == UNNotificationDefaultActionIdentifier { WindowOpener.openMain() }
            case (detectedCategory, "START"), (detectedCategory, UNNotificationDefaultActionIdentifier), (resumeCategory, "START"):
                await model.startRecording()
                if action == UNNotificationDefaultActionIdentifier { WindowOpener.openMain() }
            case (detectedCategory, "IGNORE"), (detectedCategory, UNNotificationDismissActionIdentifier),
                (resumeCategory, "IGNORE"), (resumeCategory, UNNotificationDismissActionIdentifier):
                model.dismissDetection()
            case (notesCategory, _):
                if let meetingID { model.selection = meetingID }
                WindowOpener.openMain()
            default:
                break
            }
            completionHandler()
        }
    }
}
