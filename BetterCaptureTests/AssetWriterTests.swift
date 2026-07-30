//
//  AssetWriterTests.swift
//  BetterCaptureTests
//
//  Created by Krishna Ramaroson on 28.07.26.
//

import AVFoundation
import ScreenCaptureKit
import Testing
@testable import BetterCapture

/// Tests for the video frame count AssetWriter reports when finishing a recording.
///
/// A capture source that stops delivering frames - a disconnected display, for example -
/// while audio keeps flowing produces a file with audio tracks and no video track. The
/// frame count is what lets the caller detect that case.
@MainActor
struct AssetWriterTests {

    private let videoSize = CGSize(width: 640, height: 480)

    // MARK: - Tests

    @Test func audioOnlyRecordingReportsZeroVideoFrames() async throws {
        let settings = makeStore()
        settings.captureSystemAudio = true

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        // Audio flows for the whole session, no video sample ever arrives
        for index in 0..<10 {
            let presentationTime = CMTime(value: CMTimeValue(index * 1024), timescale: 48000)
            assetWriter.appendAudioSample(try makeSilentAudioSampleBuffer(at: presentationTime))
        }

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        #expect(result.videoFrameCount == 0)

        // The recording is kept - audio is still worth saving - and it holds no video track
        #expect(FileManager.default.fileExists(atPath: result.url.path()))
        let videoTracks = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video)
        #expect(videoTracks.isEmpty)
    }

    @Test func recordingWithVideoReportsFramesWritten() async throws {
        let settings = makeStore()

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        for index in 0..<5 {
            let presentationTime = CMTime(value: CMTimeValue(index), timescale: 60)
            assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: presentationTime))
        }

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        #expect(result.videoFrameCount == 5)
    }

    @Test func cancelAfterFinishingDoesNotDeleteTheSavedRecording() async throws {
        let settings = makeStore()

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()
        assetWriter.appendVideoSample(try makeVideoSampleBuffer(at: .zero))

        let result = try await assetWriter.finishWriting()
        defer { try? FileManager.default.removeItem(at: result.url) }

        // A failed setup for the next recording leaves the previous session's state in place,
        // and the recovery path cancels the writer. The saved file must survive that.
        assetWriter.cancel()

        #expect(FileManager.default.fileExists(atPath: result.url.path()))
    }

    @Test func recordingWithoutAnySampleThrows() async throws {
        let settings = makeStore()

        let assetWriter = AssetWriter()
        try assetWriter.setup(url: makeOutputURL(), settings: settings, videoSize: videoSize)
        try assetWriter.startWriting()

        await #expect(throws: AssetWriterError.self) {
            try await assetWriter.finishWriting()
        }
    }

    // MARK: - Helpers

    /// Creates a SettingsStore backed by a fresh, empty UserDefaults suite.
    private func makeStore() -> SettingsStore {
        let suiteName = "com.sattlerjoshua.BetterCaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return SettingsStore(defaults: defaults)
    }

    private func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
    }

    /// Creates a buffer of silent 48 kHz stereo audio.
    private func makeSilentAudioSampleBuffer(at presentationTime: CMTime) throws -> CMSampleBuffer {
        let frameCount: AVAudioFrameCount = 1024

        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)
        )
        let pcmBuffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        pcmBuffer.frameLength = frameCount

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        #expect(createStatus == noErr)

        let buffer = try #require(sampleBuffer)
        let attachStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcmBuffer.mutableAudioBufferList
        )
        #expect(attachStatus == noErr)

        return buffer
    }

    /// Creates an empty BGRA video frame marked complete, as ScreenCaptureKit would deliver it.
    private func makeVideoSampleBuffer(at presentationTime: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let pixelBufferStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(videoSize.width),
            Int(videoSize.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary] as CFDictionary,
            &pixelBuffer
        )
        #expect(pixelBufferStatus == kCVReturnSuccess)
        let imageBuffer = try #require(pixelBuffer)

        var formatDescription: CMFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        )
        #expect(formatStatus == noErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        let videoFormat = try #require(formatDescription)

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: videoFormat,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        #expect(createStatus == noErr)
        let buffer = try #require(sampleBuffer)

        // appendVideoSample only accepts frames the capture engine marked complete
        let attachments = try #require(
            CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [NSMutableDictionary]
        )
        let attachment = try #require(attachments.first)
        attachment[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue

        return buffer
    }
}
