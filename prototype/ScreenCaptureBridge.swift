import AVFoundation
import Cocoa
import ScreenCaptureKit

/// 看一眼的实时画面：一扇窗口的一条捕获流，帧直接喂给 `videoLayer`。
///
/// @unchecked Sendable：流、代数、帧计数都在 `stateLock` 里。`filter`、`configuration`
/// 不在锁里，依赖调用方从主线程串行地开流、停流（同一时刻不会有两个 start）。
final class WindowStreamCapture: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    let videoLayer = AVSampleBufferDisplayLayer()

    /// 看一眼开着的时候指针就在画面上，按 30fps 取帧。
    private static let framesPerSecond = 30

    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var configuration = SCStreamConfiguration()
    private let stateLock = NSLock()
    private var _isStopped = false
    // 流代数：每次 start 自增。异步 stop/flush/帧回调都要确认自己仍属于
    // 当前代数，否则旧流的 flush 会把新流刚显示的画面清掉。
    private var _captureGeneration: UInt64 = 0
    // 每路 capture 一条串行帧队列：SCStreamOutput 的采样帧在这里修补与投递。
    private let frameQueue = DispatchQueue(label: "WindowShade.glance-frames", qos: .userInteractive)
    /// 带像素的帧：画面没变化时系统也会送来不带图像的状态帧，“已经是实时画面”只看这个。
    private var _pixelFrameCount: UInt64 = 0

    override init() {
        super.init()
        videoLayer.videoGravity = .resize
        videoLayer.backgroundColor = NSColor.clear.cgColor
    }

    var pixelFrameCount: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _pixelFrameCount
    }

    func start(window: SCWindow, display: SCDisplay?) async throws {
        if stream != nil { return }
        let newFilter = SCContentFilter(desktopIndependentWindow: window)
        filter = newFilter
        configure(window: window, display: display)
        try await startStream(filter: newFilter)
    }

    func stop() {
        stateLock.lock()
        _isStopped = true
        let generation = _captureGeneration
        let activeStream = stream
        stream = nil
        stateLock.unlock()
        if let activeStream {
            Task { [activeStream] in
                do {
                    try await activeStream.stopCapture()
                } catch {
                    // -3808：流已经自己停了。
                    if (error as NSError).code != -3808 {
                        wlog("glance: capture stop failed \(error.localizedDescription)")
                    }
                }
            }
        }
        DispatchQueue.main.async { [weak self, videoLayer] in
            // 若在 flush 执行前已重新开流（generation 递增），旧 flush 不应清掉
            // 新流已经开始显示的画面。
            guard let self else { return }
            let currentGeneration = self.stateLock.withLock { self._captureGeneration }
            guard currentGeneration == generation else { return }
            if #available(macOS 15.0, *) {
                videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) {}
            } else {
                videoLayer.flushAndRemoveImage()
            }
        }
    }

    private func startStream(filter: SCContentFilter) async throws {
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        // frameQueue 本身就是串行队列，直接作为 sampleHandlerQueue。
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        let generation = stateLock.withLock {
            _captureGeneration &+= 1
            let g = _captureGeneration
            stream = newStream
            _isStopped = false
            return g
        }
        do {
            try await newStream.startCapture()
        } catch {
            stateLock.withLock {
                guard stream === newStream else { return }
                stream = nil
                _isStopped = true
            }
            wlog("glance: startCapture failed generation=\(generation) \(error.localizedDescription)")
            throw error
        }
    }

    private func configure(window: SCWindow, display: SCDisplay?) {
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 3
        configuration.scalesToFit = true
        if #available(macOS 13.0, *) {
            configuration.capturesAudio = false
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.framesPerSecond))
        if #available(macOS 14.0, *), let filter {
            let scale = max(1, Int(filter.pointPixelScale))
            configuration.width = max(1, Int(ceil(filter.contentRect.width)) * scale)
            configuration.height = max(1, Int(ceil(filter.contentRect.height)) * scale)
        } else {
            let frame = window.frame
            let screen = display.flatMap { screenForDisplayID($0.displayID) }
                ?? screenForCocoaFrame(NSRect(origin: .zero, size: frame.size))
                ?? NSScreen.main
            let scale = screen?.backingScaleFactor ?? 2
            configuration.width = max(1, Int(ceil(frame.width * scale)))
            configuration.height = max(1, Int(ceil(frame.height * scale)))
        }
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        stateLock.lock()
        let stopped = _isStopped
        // 帧必须来自当前流：旧流晚到的回调会被 stream 身份挡掉。
        let isCurrentStream = self.stream === stream
        stateLock.unlock()
        guard !stopped, isCurrentStream else { return }
        // 这扇窗正被我们的流捕获，系统在它的红绿灯处画了录屏胶囊：交给画面之前修掉。
        CaptureIndicatorRemoval.clean(sampleBuffer)
        if CMSampleBufferGetImageBuffer(sampleBuffer) != nil { stateLock.withLock { _pixelFrameCount &+= 1 } }
        deliver(sampleBuffer)
    }

    // macOS 15 的 sampleBufferRenderer.enqueue 线程安全，直接在帧队列上投递；
    // 旧系统必须回主线程。
    private func deliver(_ sampleBuffer: CMSampleBuffer) {
        if #available(macOS 15.0, *) {
            videoLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            // 帧到这里已经修完、不再改动；旧系统只能在主线程 enqueue，跨线程的只是这份只读的帧。
            nonisolated(unsafe) let sampleBuffer = sampleBuffer
            DispatchQueue.main.async { [videoLayer] in
                Self.enqueueOnMain(sampleBuffer, into: videoLayer)
            }
        }
    }

    @MainActor private static func enqueueOnMain(_ buffer: CMSampleBuffer, into layer: AVSampleBufferDisplayLayer) {
        if #available(macOS 15.0, *) {
            layer.sampleBufferRenderer.enqueue(buffer)
        } else {
            layer.enqueue(buffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        wlog("glance: capture stopped with error \(error.localizedDescription)")
        stateLock.withLock {
            guard self.stream === stream else { return }
            self.stream = nil
            _isStopped = true
            _captureGeneration &+= 1
        }
    }
}
