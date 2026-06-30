import Foundation

/// L2 纠错的处理类型（对照 Pipeline 的 kind 字段）
/// Outcome of the L2 polish step for a segment.
public enum L2Kind: String, Sendable {
    case changed   // L2 改动了文本
    case identity  // L2 输出 == 输入
    case failed    // L2 调用失败或返回 nil
    case skipped   // polish.enabled=false 时跳过
}

/// 会议转录片段
/// 一个 MeetingSegment 对应 SegmentBuffer 的一次 flush
/// - text: 展示给用户的最终文本（L2 成功时 = L2 输出；失败/跳过时 = rawText）
/// - rawText: 本批次 SA final 段原文拼接（调试 + 蒸馏留存）
/// - l2Kind: L2 的处理结果，用于验收和日志回溯
/// - speakerName: 用户在收尾面板里给该说话人指定的名字（会话级，不持久化）
public struct MeetingSegment: Sendable, Identifiable {
    public let id = UUID()
    public let text: String
    public let rawText: String
    public let startTime: TimeInterval   // 相对于会议开始的秒数
    public let endTime: TimeInterval
    public let speakerId: String?        // FluidAudio 分配的说话人 ID
    public let l2Kind: L2Kind
    public let isFinal: Bool
    public let speakerName: String?      // 用户指定的说话人名字（可空）

    public init(
        text: String,
        rawText: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerId: String?,
        l2Kind: L2Kind,
        isFinal: Bool,
        speakerName: String? = nil
    ) {
        self.text = text
        self.rawText = rawText
        self.startTime = startTime
        self.endTime = endTime
        self.speakerId = speakerId
        self.l2Kind = l2Kind
        self.isFinal = isFinal
        self.speakerName = speakerName
    }

    /// 显示用的说话人标签。优先用用户指定的名字，否则 "<prefix> <id>"。
    /// `prefix` 由调用方传入（已本地化），保持 WECore 不依赖本地化层。
    public func speakerLabel(prefix: String) -> String? {
        resolveSpeakerLabel(speakerId: speakerId, speakerName: speakerName, prefix: prefix)
    }
}

/// 会议结果
public struct MeetingResult: Sendable {
    public let segments: [MeetingSegment]
    public let duration: TimeInterval
    public let audioPath: String?
    public let date: Date

    public init(segments: [MeetingSegment], duration: TimeInterval, audioPath: String?, date: Date = Date()) {
        self.segments = segments
        self.duration = duration
        self.audioPath = audioPath
        self.date = date
    }
}
