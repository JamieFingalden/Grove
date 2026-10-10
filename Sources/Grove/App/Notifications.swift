import Foundation
import UserNotifications

/// 系统通知的收口：推送后盯流水线，到终态弹一条。
/// 通知失败（没授权、被系统拒）绝不能影响主流程 —— 全部吞掉。
enum PipelineNotifier {
    /// 第一次真正要盯流水线时才请求授权，不在启动时就弹系统对话框。
    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func notify(
        status: CIStatus,
        ref: String,
        repositoryName: String,
        repositoryRoot: URL
    ) async {
        let center = UNUserNotificationCenter.current()
        // 没授权就静默退场 —— 状态页里照样能看到。
        guard let settings = try? await center.notificationSettings(),
              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        switch status {
        case .success:
            content.title = "CI 已通过"
            content.body = "\(repositoryName) · \(ref)"
        case .failed:
            content.title = "CI 失败"
            content.body = "\(repositoryName) · \(ref) — 点开看失败摘要"
            content.sound = .default
        case .canceled:
            content.title = "CI 已取消"
            content.body = "\(repositoryName) · \(ref)"
        default:
            return
        }
        // 点击通知路由回对应仓库的项目主页。
        content.userInfo = ["repositoryRoot": repositoryRoot.path]
        content.threadIdentifier = repositoryRoot.path

        let request = UNNotificationRequest(
            identifier: "pipeline-\(repositoryRoot.path)-\(ref)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        _ = try? await center.add(request)
    }
}

/// 新提交只提醒用户；确认后才重新调用模型。
enum AIReviewNotifier {
    static let category = "grove-ai-review-update"
    static let reviewAction = "grove-ai-review-again"

    static func registerActions() async {
        let center = UNUserNotificationCenter.current()
        var categories = await center.notificationCategories()
        let review = UNNotificationAction(identifier: reviewAction, title: "重新审查", options: [.foreground])
        let later = UNNotificationAction(identifier: "grove-ai-review-later", title: "稍后", options: [])
        categories.insert(UNNotificationCategory(identifier: category, actions: [review, later],
                                                   intentIdentifiers: [], options: []))
        center.setNotificationCategories(categories)
    }

    static func notify(repositoryRoot: URL, request: PullRequest, head: String) async {
        await registerActions()
        await PipelineNotifier.requestAuthorization()
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(request.displayNumber) 有新提交"
        content.body = "\(repositoryRoot.lastPathComponent) · \(request.title)\n尚未重新审查，由你决定是否继续。"
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["repositoryRoot": repositoryRoot.path, "pullRequestNumber": request.number]
        content.threadIdentifier = "ai-review-\(request.url)"
        _ = try? await center.add(UNNotificationRequest(identifier: "ai-review-\(request.url)-\(head)",
                                                       content: content, trigger: nil))
    }
}

/// 通知点击的路由：打开项目，或者执行用户明确点击的重新审查。
/// delegate 必须是个长命的 NSObject，挂在 GroveApp 上。
@MainActor
final class PipelineNotificationRouter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    var openRepository: ((URL) -> Void)?
    var reviewPullRequest: ((URL, Int) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // app 开着也要弹横幅，不然盯梢白盯。
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo["repositoryRoot"] as? String {
            let root = URL(fileURLWithPath: path)
            if response.actionIdentifier == AIReviewNotifier.reviewAction,
               let number = response.notification.request.content.userInfo["pullRequestNumber"] as? Int {
                openRepository?(root)
                reviewPullRequest?(root, number)
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                openRepository?(root)
            }
        }
        completionHandler()
    }
}
