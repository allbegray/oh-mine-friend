import AppKit
import Foundation

/// 키보드 타이핑 속도(WPM)를 감지한다.
///
/// 감지 원천은 `CGEventSource.counterForEventType(.combinedSessionState, .keyDown)` —
/// 시스템 전역 세션의 keyDown 누적 개수다. 권한이 필요 없고, 어느 앱에 타이핑해도
/// 같은 카운터가 오른다.
///
/// `NSEvent.addGlobalMonitorForEvents(.keyDown)` 방식은 폐기했다. 그 방식은 손쉬운
/// 사용(Accessibility) 권한이 있어야만 이벤트가 들어오는데, 권한이 없으면 에러 없이
/// 조용히 아무 이벤트도 오지 않아 WPM 이 영원히 0 이 된다(사용자에게는 "열심히 쳐도
/// 응원을 안 한다"로 보인다). 게다가 이 앱은 ad-hoc 서명이라 재빌드마다 서명이 바뀌어
/// TCC 권한이 무효화되므로, 사용자가 한 번 허용해도 다음 빌드에서 다시 죽는다.
/// 카운터 폴링은 그 함정이 없다.
///
/// 모든 멤버는 메인 스레드에서만 쓴다. `poll()` 은 프레임마다 정확히 한 번 호출해야
/// 한다(카운터 증가분을 소비하는 구조라 호출이 늘어나면 타수를 나눠 갖는다).
public final class TypingActivityMonitor {
    public static let shared = TypingActivityMonitor()

    private static let enabledKey = "isTypingCheerEnabled"
    /// WPM 계산 윈도우(초). 이 창 안의 타수로 분당 타수를 환산한다.
    private static let window: TimeInterval = 4.0
    /// 프레임 한 번에 들어올 수 있는 최대 타수. 절전 복귀·카운터 리셋 때 누적치가
    /// 통째로 증가분이 되어 WPM 이 튀는 것을 막는다(초당 1920타 — 실사용에서 불가능).
    private static let maxKeystrokesPerPoll = 32
    /// 1단어 = 5타수
    private static let keystrokesPerWord: Double = 5.0

    /// 응원을 트리거하는 기준 WPM. 35 WPM ≈ 초당 3.5타.
    public static let cheerThreshold: Double = 35.0

    public var isEnabled: Bool {
        get {
            // 키가 없으면(첫 실행) true — 기존 기본값 ON 유지
            if UserDefaults.standard.object(forKey: Self.enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if !newValue { keystrokeTimestamps.removeAll() }
        }
    }

    private var keystrokeTimestamps: [TimeInterval] = []
    private var lastCounter: UInt32?

    private init() {}

    /// 매 프레임 1회 호출(메인 스레드). 전역 keyDown 카운터의 증가분을 적립한다.
    /// 꺼져 있을 때도 카운터 기준선은 계속 갱신해, 다시 켰을 때 과거 누적치가
    /// 한꺼번에 타수로 잡히지 않게 한다.
    public func poll(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let counter = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
        defer { lastCounter = counter }
        guard let last = lastCounter else { return }   // 첫 호출은 기준선만 기록
        let delta = counter &- last                     // UInt32 래핑 대응
        guard isEnabled, delta > 0 else { return }
        let count = min(Int(delta), Self.maxKeystrokesPerPoll)
        keystrokeTimestamps.append(contentsOf: repeatElement(now, count: count))
        cleanOldTimestamps(now: now)
    }

    /// 테스트 또는 강제 응원 트리거용 시뮬레이션
    public func simulateKeystrokes(count: Int = 15) {
        let now = ProcessInfo.processInfo.systemUptime
        keystrokeTimestamps.append(contentsOf: repeatElement(now, count: count))
        cleanOldTimestamps(now: now)
    }

    /// 최근 `window` 초 타수 기반 WPM
    public var currentWPM: Double {
        guard isEnabled else { return 0 }
        let now = ProcessInfo.processInfo.systemUptime
        cleanOldTimestamps(now: now)
        guard keystrokeTimestamps.count >= 3 else { return 0 }
        let kpm = Double(keystrokeTimestamps.count) * (60.0 / Self.window)
        return kpm / Self.keystrokesPerWord
    }

    private func cleanOldTimestamps(now: TimeInterval) {
        let cutoff = now - Self.window
        keystrokeTimestamps.removeAll { $0 < cutoff }
    }
}
