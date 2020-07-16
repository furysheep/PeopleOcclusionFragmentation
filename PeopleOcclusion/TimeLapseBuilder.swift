import AVFoundation
import UIKit
import Combine

// This is a simple structure that combines the output of AVAssetWriterDelegate with an increasing segment index.
struct Segment {
    let index: Int
    let data: Data
    let isInitializationSegment: Bool
    let report: AVAssetSegmentReport?
}

// This function sends each segment to the provided Subject, then marks the Subject as completed.
// You must keep a strong reference to the returned object until the operation completes.
func generateBuilder<S>(configuration: FMP4WriterConfiguration, subject: S) -> TimeLapseBuilder<S>
where S: Subject, S.Output == Segment, S.Failure == Error {
    let readerWriter = TimeLapseBuilder(configuration: configuration, subject: subject)
    readerWriter.start()
    return readerWriter
}

let kErrorDomain = "TimeLapseBuilder"
let kFailedToStartAssetWriterError = 0
let kFailedToAppendPixelBufferError = 1

class TimeLapseBuilder<S>: NSObject, AVAssetWriterDelegate where S: Subject, S.Output == Segment, S.Failure == Error  {
    private let videoWriter: AVAssetWriter
    private let startTimeOffset: CMTime
    private let subject: S
    private let videoWriterInput: AVAssetWriterInput
    private let videoDone = PassthroughSubject<Void, Error>()
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor!
    private var done: AnyCancellable?
    private var segmentIndex = 0
    
    private var frameCount: Int64 = 0
    
    private let videoWidth: Int, videoHeight: Int
    private var pixelBuffers = [CVPixelBuffer]()
    
    private var started = false
    
    init(configuration: FMP4WriterConfiguration, subject: S) {
        self.startTimeOffset = configuration.startTimeOffset
        videoWidth = configuration.videoCompressionSettings[AVVideoWidthKey] as! Int
        videoHeight = configuration.videoCompressionSettings[AVVideoHeightKey] as! Int
        self.subject = subject
        videoWriter = AVAssetWriter(contentType: UTType(configuration.outputContentType.rawValue)!)
        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: configuration.videoCompressionSettings)
        videoWriter.add(videoWriterInput)
        super.init()
        
        // Configure the asset writer for writing data in fragmented MPEG-4 format.
        videoWriter.outputFileTypeProfile = configuration.outputFileTypeProfile
        videoWriter.preferredOutputSegmentInterval = CMTime(seconds: Double(configuration.segmentDuration), preferredTimescale: 1)
        videoWriter.initialSegmentStartTime = configuration.startTimeOffset
        videoWriter.delegate = self
        
        done = videoDone.sink(receiveCompletion: { [weak self] completion in
                self?.finish(completion: completion)
            }, receiveValue: { _ in })
    }
    
    public func start() {
        // reset buffers
        pixelBuffers.removeAll()
        
        let sourceBufferAttributes = [
            (kCVPixelBufferPixelFormatTypeKey as String): Int(kCVPixelFormatType_32ARGB),
            (kCVPixelBufferWidthKey as String): Float(videoWidth),
            (kCVPixelBufferHeightKey as String): Float(videoHeight)] as [String : Any]
        
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: sourceBufferAttributes
        )
        guard videoWriter.startWriting() else {
            subject.send(completion: .failure(videoWriter.error!))
            return
        }
        
        frameCount = 0
        
        videoWriter.startSession(atSourceTime: startTimeOffset)
        assert(pixelBufferAdaptor.pixelBufferPool != nil)
        
        let media_queue = DispatchQueue(label: "mediaInputQueue")
        
        var error: NSError?
        started = true
        videoWriterInput.requestMediaDataWhenReady(on: media_queue) {[weak self] in
            guard let self = self else { return }
            let fps: Int32 = 30
            let frameDuration = CMTimeMake(value: 1, timescale: fps)
            
            while self.videoWriterInput.isReadyForMoreMediaData && self.pixelBuffers.count > 0 {
                let pixelBuffer = self.pixelBuffers.remove(at: 0)
                let lastFrameTime = CMTimeMake(value: self.frameCount, timescale: fps)
                let presentationTime = self.frameCount == 0 ? lastFrameTime : CMTimeAdd(lastFrameTime, frameDuration)
                
                if !self.pixelBufferAdaptor.append(
                    pixelBuffer,
                    withPresentationTime: presentationTime
                ) {
                    error = NSError(
                        domain: kErrorDomain,
                        code: kFailedToAppendPixelBufferError,
                        userInfo: ["description": "AVAssetWriterInputPixelBufferAdapter failed to append pixel buffer"]
                    )
                    
                    break
                }
                
                self.frameCount += 1
            }
            
            if !self.started {
                self.videoWriterInput.markAsFinished()
                self.videoDone.send(completion: .finished)
            }
        }
        
        if let error = error {
            subject.send(completion: .failure(error))
        }
    }
    
    public func finish() {
        started = false
    }
    
    public func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        pixelBuffers.append(pixelBuffer)
    }
    
    // MARK: AVAssetWriterDelegate -
    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        let isInitializationSegment: Bool
        
        switch segmentType {
        case .initialization:
            isInitializationSegment = true
        case .separable:
            isInitializationSegment = false
        @unknown default:
            print("Skipping segment with unrecognized type \(segmentType)")
            return
        }
        
        let segment = Segment(index: segmentIndex, data: segmentData, isInitializationSegment: isInitializationSegment, report: segmentReport)
        subject.send(segment)
        segmentIndex += 1
    }
    
    // MARK: - Private
    // Call this when done transferring video data.
    // Here you evaluate the final status of the AVAssetReader and AVAssetWriter, then mark the Subject as finished.
    private func finish(completion: Subscribers.Completion<Error>) {
        switch completion {
        case .failure:
            videoWriter.cancelWriting()
            subject.send(completion: completion)
        default:
            videoWriter.finishWriting {
                if self.videoWriter.status == .completed {
                    self.subject.send(completion: .finished)
                } else {
                    assert(self.videoWriter.status == .failed)
                    self.subject.send(completion: .failure(self.videoWriter.error!))
                }
            }
        }
    }
}
