import AVFoundation
import Flutter
import VideoToolbox

/// Video compression with AVAssetReader -> AVAssetWriter (hardware VideoToolbox
/// encoder). One AVVideoComposition does rotation, scaling, frame-rate capping
/// and HDR -> SDR (BT.709) conversion; AAC audio is copied through untouched.
public class RimgVideoPlugin: NSObject, FlutterPlugin, RimgVideoHostApi {
  private var flutterApi: RimgVideoFlutterApi?
  private var jobs: [String: Job] = [:]
  private let lock = NSLock()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = RimgVideoPlugin()
    RimgVideoHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    instance.flutterApi = RimgVideoFlutterApi(binaryMessenger: registrar.messenger())
  }

  func probe(path: String) async throws -> VideoInfoMsg {
    try Probe.read(URL(fileURLWithPath: path))
  }

  func cancel(jobId: String) throws {
    lock.lock()
    let job = jobs[jobId]
    lock.unlock()
    job?.cancel()
  }

  func compress(request: VideoRequestMsg) async throws -> VideoResultMsg {
    let input = URL(fileURLWithPath: request.inputPath)
    let output = URL(fileURLWithPath: request.outputPath)
    try? FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: output)

    let job = try Job(request: request, input: input, output: output) { [weak self] progress in
      guard let api = self?.flutterApi else { return }
      Task { @MainActor in try? await api.onProgress(jobId: request.jobId, progress: progress) }
    }
    lock.lock()
    jobs[request.jobId] = job
    lock.unlock()
    defer {
      lock.lock()
      jobs[request.jobId] = nil
      lock.unlock()
    }

    do {
      try await job.run()
    } catch {
      try? FileManager.default.removeItem(at: output)
      throw error
    }
    let out = try Probe.read(output)
    let sideways = out.rotation % 180 != 0
    return VideoResultMsg(
      width: sideways ? out.height : out.width,
      height: sideways ? out.width : out.height,
      durationMs: out.durationMs,
      fileBytes: out.fileBytes,
      videoCodec: job.codec)
  }
}

private func err(_ code: String, _ message: String) -> RimgVideoError {
  RimgVideoError(code: code, message: message, details: nil)
}

/// One reader -> writer export.
private final class Job {
  let codec: VideoCodecMsg
  private let reader: AVAssetReader
  private let writer: AVAssetWriter
  private let videoOut: AVAssetReaderVideoCompositionOutput
  private let videoIn: AVAssetWriterInput
  private let audio: (AVAssetReaderOutput, AVAssetWriterInput)?
  private let duration: CMTime
  private let onProgress: (Double) -> Void
  private let stateLock = NSLock()
  private var _cancelled = false
  private var cancelled: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _cancelled
  }

  init(request r: VideoRequestMsg, input: URL, output: URL, onProgress: @escaping (Double) -> Void) throws {
    self.onProgress = onProgress
    let asset = AVURLAsset(url: input, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let vTrack = asset.tracks(withMediaType: .video).first else {
      throw err("input", "No readable video track in \(input.lastPathComponent)")
    }
    duration = asset.duration
    do {
      reader = try AVAssetReader(asset: asset)
      writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    } catch {
      throw err("input", "Cannot open video: \(error.localizedDescription)")
    }
    writer.shouldOptimizeForNetworkUse = true  // moov first: playable while uploading

    let size = CGSize(width: Int(r.width), height: Int(r.height))
    let srcFps = vTrack.nominalFrameRate > 0 ? vTrack.nominalFrameRate : 30
    let fps = r.maxFps > 0 ? min(srcFps, Float(r.maxFps)) : srcFps

    // Video composition: orientation + scale into `size`, frame rate cap,
    // and BT.709 output colour (converts HLG/PQ HDR to SDR).
    let comp = AVMutableVideoComposition()
    comp.renderSize = size
    comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
    comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    let t = vTrack.preferredTransform
    let shown = CGRect(origin: .zero, size: vTrack.naturalSize).applying(t)
    let fit = t
      .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
      .concatenating(CGAffineTransform(scaleX: size.width / shown.width, y: size.height / shown.height))
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
    layer.setTransform(fit, at: .zero)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    instruction.layerInstructions = [layer]
    comp.instructions = [instruction]

    videoOut = AVAssetReaderVideoCompositionOutput(
      videoTracks: [vTrack],
      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    videoOut.videoComposition = comp
    videoOut.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOut) else { throw err("input", "Cannot decode this video") }
    reader.add(videoOut)

    // Encoder settings; HEVC falls back to H.264 where unavailable.
    func settings(_ c: VideoCodecMsg) -> [String: Any] {
      var props: [String: Any] = [
        AVVideoAverageBitRateKey: Int(r.videoBitrate),
        AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
        AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()) * 2,
      ]
      if c == .h264 {
        props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        props[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
      } else {
        props[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
      }
      return [
        AVVideoCodecKey: c == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
        AVVideoWidthKey: Int(r.width),
        AVVideoHeightKey: Int(r.height),
        AVVideoCompressionPropertiesKey: props,
        AVVideoColorPropertiesKey: [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
      ]
    }
    var c = r.codec
    if c == .hevc && !writer.canApply(outputSettings: settings(.hevc), forMediaType: .video) { c = .h264 }
    codec = c
    videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings(c))
    videoIn.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoIn) else { throw err("encoder", "Encoder rejected \(r.width)x\(r.height)") }
    writer.add(videoIn)

    // Audio: copy AAC as-is; re-encode anything else to AAC 128 kbps.
    if let aTrack = asset.tracks(withMediaType: .audio).first,
      let fmt = aTrack.formatDescriptions.first.map({ $0 as! CMAudioFormatDescription })
    {
      let isAAC = CMFormatDescriptionGetMediaSubType(fmt) == kAudioFormatMPEG4AAC
      let aOut: AVAssetReaderTrackOutput
      let aIn: AVAssetWriterInput
      if isAAC {
        aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
        aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fmt)
      } else {
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee
        aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVNumberOfChannelsKey: min(2, Int(asbd?.mChannelsPerFrame ?? 2)),
          AVSampleRateKey: min(48000, asbd?.mSampleRate ?? 44100),
          AVEncoderBitRateKey: 128000,
        ])
      }
      aIn.expectsMediaDataInRealTime = false
      if reader.canAdd(aOut) && writer.canAdd(aIn) {
        reader.add(aOut)
        writer.add(aIn)
        audio = (aOut, aIn)
      } else {
        audio = nil
      }
    } else {
      audio = nil
    }
  }

  func cancel() {
    stateLock.lock()
    _cancelled = true
    stateLock.unlock()
    reader.cancelReading()
  }

  func run() async throws {
    guard reader.startReading() else {
      throw err("input", "Cannot read video: \(reader.error?.localizedDescription ?? "unknown")")
    }
    guard writer.startWriting() else {
      throw err("encoder", "Cannot start encoder: \(writer.error?.localizedDescription ?? "unknown")")
    }
    writer.startSession(atSourceTime: .zero)

    let total = max(duration.seconds, 0.001)
    var lastReport = 0.0
    let group = DispatchGroup()
    pump(videoIn, videoOut, label: "video", group: group) { [weak self] pts in
      let p = min(1, max(0, pts.seconds / total))
      if p - lastReport >= 0.02 {
        lastReport = p
        self?.onProgress(p)
      }
    }
    if let (aOut, aIn) = audio { pump(aIn, aOut, label: "audio", group: group, onSample: nil) }
    await withCheckedContinuation { cont in group.notify(queue: .global()) { cont.resume() } }

    if cancelled {
      writer.cancelWriting()
      throw err("cancelled", "cancelled")
    }
    if reader.status == .failed {
      writer.cancelWriting()
      throw err("input", "Decoding failed: \(reader.error?.localizedDescription ?? "unknown")")
    }
    if writer.status == .failed {
      throw err("encoder", "Encoding failed: \(writer.error?.localizedDescription ?? "unknown")")
    }
    await writer.finishWriting()
    if writer.status != .completed {
      throw err("io", "Writing failed: \(writer.error?.localizedDescription ?? "unknown")")
    }
    onProgress(1)
  }

  /// Moves samples from reader output to writer input until either runs out.
  private func pump(
    _ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String,
    group: DispatchGroup, onSample: ((CMTime) -> Void)?
  ) {
    group.enter()
    var finished = false
    let queue = DispatchQueue(label: "rimg_video.\(label)")
    input.requestMediaDataWhenReady(on: queue) { [weak self] in
      guard let self, !finished else { return }
      while input.isReadyForMoreMediaData {
        let sample = self.cancelled ? nil : output.copyNextSampleBuffer()
        guard let sample, self.writer.status == .writing, input.append(sample) else {
          input.markAsFinished()
          finished = true
          group.leave()
          return
        }
        onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
      }
    }
  }
}

/// Reads basic facts about a video file.
private enum Probe {
  static func read(_ url: URL) throws -> VideoInfoMsg {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    guard let bytes = attrs?[.size] as? Int64 else {
      throw err("input", "Cannot read \(url.path)")
    }
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let v = asset.tracks(withMediaType: .video).first,
      let fmt = v.formatDescriptions.first.map({ $0 as! CMFormatDescription })
    else {
      throw err("input", "Not a readable video: \(url.lastPathComponent)")
    }
    let durationMs = Int64((asset.duration.seconds * 1000).rounded())
    let a = asset.tracks(withMediaType: .audio).first

    // preferredTransform -> clockwise display rotation (iPhone portrait = 90).
    let t = v.preferredTransform
    var deg = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
    deg = ((deg % 360) + 360) % 360

    let transfer = CMFormatDescriptionGetExtension(
      fmt, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
    let isHdr =
      transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
      || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)

    let sub = CMFormatDescriptionGetMediaSubType(fmt)
    let fourcc = String(
      [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((sub >> $0) & 0xff))) })

    return VideoInfoMsg(
      width: Int64(v.naturalSize.width.rounded()),
      height: Int64(v.naturalSize.height.rounded()),
      rotation: Int64(deg),
      durationMs: durationMs,
      bitrate: durationMs > 0 ? bytes * 8000 / durationMs : 0,
      frameRate: Double(v.nominalFrameRate > 0 ? v.nominalFrameRate : 30),
      videoCodec: fourcc,
      hasAudio: a != nil,
      audioBitrate: Int64(a?.estimatedDataRate ?? 0),
      isHdr: isHdr,
      fileBytes: bytes)
  }
}
