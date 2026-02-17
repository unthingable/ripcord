import AVFoundation
import AudioToolbox

enum AudioOutputFormat: String, CaseIterable, Identifiable {
    case wav = "WAV"
    case m4a = "M4A"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .m4a: return "m4a"
        }
    }
}

enum AudioQuality: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }

    func bitRate(for format: AudioOutputFormat) -> Int {
        switch format {
        case .m4a:
            switch self {
            case .low: return 64000
            case .medium: return 128000
            case .high: return 256000
            }
        case .wav:
            return 0 // Not applicable
        }
    }

    func label(for format: AudioOutputFormat) -> String {
        let kbps = bitRate(for: format) / 1000
        return "\(rawValue) (\(kbps) kbps)"
    }
}

final class AudioFileWriter: @unchecked Sendable {
    private var extAudioFile: ExtAudioFileRef?
    private let inputSampleRate: Double = AudioConstants.sampleRate
    private let wavOutputSampleRate: Double = 16000
    private let channelCount: UInt32 = 2

    let url: URL
    let format: AudioOutputFormat
    let quality: AudioQuality
    private(set) var totalFramesWritten: Int64 = 0
    private(set) var isOpen = false

    init(url: URL, format: AudioOutputFormat, quality: AudioQuality) {
        self.url = url
        self.format = format
        self.quality = quality
    }

    func open() throws {
        try checkDiskSpace(at: url)

        var outputASBD = AudioStreamBasicDescription()
        let fileTypeID: AudioFileTypeID

        switch format {
        case .wav:
            fileTypeID = kAudioFileWAVEType
            outputASBD.mSampleRate = wavOutputSampleRate
            outputASBD.mFormatID = kAudioFormatLinearPCM
            outputASBD.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
            outputASBD.mBitsPerChannel = 16
            outputASBD.mChannelsPerFrame = channelCount
            outputASBD.mBytesPerFrame = 2 * channelCount
            outputASBD.mFramesPerPacket = 1
            outputASBD.mBytesPerPacket = 2 * channelCount

        case .m4a:
            fileTypeID = kAudioFileM4AType
            outputASBD.mSampleRate = inputSampleRate // AAC at native rate — compression handles file size
            outputASBD.mFormatID = kAudioFormatMPEG4AAC
            outputASBD.mChannelsPerFrame = channelCount

        }

        let fileURL = url as CFURL
        var extFile: ExtAudioFileRef?

        // Stereo AAC requires an explicit channel layout
        var channelLayout = AudioChannelLayout()
        channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo

        var status: OSStatus
        if channelCount > 1 {
            status = withUnsafePointer(to: &channelLayout) { layoutPtr in
                ExtAudioFileCreateWithURL(fileURL, fileTypeID, &outputASBD, layoutPtr, AudioFileFlags.eraseFile.rawValue, &extFile)
            }
        } else {
            status = ExtAudioFileCreateWithURL(fileURL, fileTypeID, &outputASBD, nil, AudioFileFlags.eraseFile.rawValue, &extFile)
        }
        guard status == noErr, let extFile else {
            throw WriterError.cannotCreate(status)
        }

        // Set client data format (what we'll feed in) — Float32 at input sample rate
        var clientASBD = AudioStreamBasicDescription()
        clientASBD.mSampleRate = inputSampleRate
        clientASBD.mFormatID = kAudioFormatLinearPCM
        clientASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        clientASBD.mBitsPerChannel = 32
        clientASBD.mChannelsPerFrame = channelCount
        clientASBD.mBytesPerFrame = 4 * channelCount
        clientASBD.mFramesPerPacket = 1
        clientASBD.mBytesPerPacket = 4 * channelCount

        // For stereo compressed formats, set client channel layout before client format
        if channelCount > 1 && format == .m4a {
            var clientLayout = AudioChannelLayout()
            clientLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            status = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientChannelLayout,
                                             UInt32(MemoryLayout<AudioChannelLayout>.size), &clientLayout)
            // Non-fatal — some encoders don't require it
        }

        status = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD)
        guard status == noErr else {
            ExtAudioFileDispose(extFile)
            throw WriterError.cannotSetClientFormat(status)
        }

        // Set bitrate for compressed formats
        if format == .m4a {
            var bitRate = UInt32(quality.bitRate(for: format))
            var converterRef: AudioConverterRef?
            var size = UInt32(MemoryLayout<AudioConverterRef>.size)
            status = ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_AudioConverter, &size, &converterRef)
            if status == noErr, let converter = converterRef {
                AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                          UInt32(MemoryLayout<UInt32>.size), &bitRate)
            }
        }

        self.extAudioFile = extFile
        self.isOpen = true
    }

    /// Maximum frames per ExtAudioFileWrite call (1 second at 48kHz).
    /// AAC encoders can crash on very large buffers (e.g., 5 minutes / 14.4M frames).
    private static let maxFramesPerWrite: Int = AudioConstants.sampleRateInt

    func append(samples: [Float]) throws {
        guard let extFile = extAudioFile else {
            throw WriterError.notOpen
        }

        guard !samples.isEmpty else { return }

        let ch = Int(channelCount)
        let totalFrames = samples.count / ch

        // Write in chunks — AAC encoder can't handle millions of frames at once
        var frameOffset = 0
        while frameOffset < totalFrames {
            let chunkFrames = min(Self.maxFramesPerWrite, totalFrames - frameOffset)
            let sampleOffset = frameOffset * ch
            let chunkSamples = chunkFrames * ch
            try samples.withUnsafeBufferPointer { bufferPointer in
                guard let base = bufferPointer.baseAddress else { return }
                let chunkPointer = base + sampleOffset
                let audioBuffer = AudioBuffer(
                    mNumberChannels: channelCount,
                    mDataByteSize: UInt32(chunkSamples * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(mutating: chunkPointer)
                )
                var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)

                let status = ExtAudioFileWrite(extFile, UInt32(chunkFrames), &bufferList)
                guard status == noErr else {
                    throw WriterError.writeFailed(status)
                }
            }
            frameOffset += chunkFrames
        }

        totalFramesWritten += Int64(totalFrames)
    }

    func finalize() throws -> RecordingInfo {
        guard let extFile = extAudioFile else {
            throw WriterError.notOpen
        }

        let status = ExtAudioFileDispose(extFile)
        self.extAudioFile = nil
        self.isOpen = false

        guard status == noErr else {
            throw WriterError.finalizeFailed(status)
        }

        let duration = Double(totalFramesWritten) / inputSampleRate
        let fileSize: UInt64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        return RecordingInfo(url: url, duration: duration, fileSize: fileSize)
    }

    private func checkDiskSpace(at url: URL, minimumBytes: UInt64 = 100_000_000) throws {
        let dir = url.deletingLastPathComponent()
        guard let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage,
              available > 0 else {
            return // Can't determine — assume OK
        }
        if available < Int64(minimumBytes) {
            throw WriterError.insufficientDiskSpace
        }
    }

    enum WriterError: Error {
        case cannotCreate(OSStatus)
        case cannotSetClientFormat(OSStatus)
        case notOpen
        case writeFailed(OSStatus)
        case finalizeFailed(OSStatus)
        case insufficientDiskSpace
    }
}

struct RecordingInfo {
    var url: URL
    let duration: Double
    let fileSize: UInt64

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }

    var filename: String {
        url.lastPathComponent
    }
}
