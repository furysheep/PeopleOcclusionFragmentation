/*
See LICENSE folder for this sample’s licensing information.

Abstract:
The sample app's main view controller.
*/

import UIKit
import RealityKit
import ARKit
import Combine

class ViewController: UIViewController {

    @IBOutlet var arView: ARView!
    @IBOutlet var messageLabel: RoundedLabel!
    private var recordStarted = false
    private var builder: TimeLapseBuilder<PassthroughSubject<Segment, Error>>?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let plane = MeshResource.generatePlane(width: 2, height: 2) // size in metres
        let material = SimpleMaterial(color: .black, isMetallic: false)
        let entity = ModelEntity(mesh: plane, materials: [material])
        
        // Place model on a horizontal plane.
        let anchor = AnchorEntity(.camera)
        arView.scene.anchors.append(anchor)
               
        anchor.transform.translation = [0, 0, -0.5]

        anchor.children.append(entity)
        
        // Load face mask
//        arView.scene.anchors.append(try! Shades.loadBlack())

        guard ARFaceTrackingConfiguration.supportsFrameSemantics(.personSegmentation) else {
            fatalError("People occlusion is not supported on this device.")
        }
        
        let sessionConfig = ARFaceTrackingConfiguration()
        sessionConfig.frameSemantics.insert(.personSegmentation)
        arView.session.run(sessionConfig)
        arView.session.delegate = self
        arView.renderOptions.remove(.disableAREnvironmentLighting)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }

    @IBAction func onTap(_ sender: UITapGestureRecognizer) {
        if recordStarted {
            messageLabel.displayMessage("Recording ended", duration: 1.0)
            builder?.finish()
        } else {
            messageLabel.displayMessage("Recording started", duration: 1.0)
            clearTempFolder()
            let config = FMP4WriterConfiguration(outputDirectoryPath: NSTemporaryDirectory())

            // These are needed to keep the asynchronous operations running.

            var segmentAndIndexFileWriter: AnyCancellable?

            let outputDirectoryURL = URL(fileURLWithPath: config.outputDirectoryPath, isDirectory: true)
            print("Writing segment files to directory \(outputDirectoryURL)")
            
            // Set up the processing pipelines.
            
            // Generate a stream of Segment structures.
            // This will be hooked up to the segment generation code after the processing chains have been set up.
            let segmentGenerator = PassthroughSubject<Segment, Error>()
            
            // Generate an index file from a stream of Segments.
            let indexFileGenerator = segmentGenerator.reduceToIndexFile(using: config)
            
            // Write each segment to disk.
            let segmentFileWriter = segmentGenerator
                .tryMap { segment in
                    let segmentFileName = segment.fileName(forPrefix: config.segmentFileNamePrefix)
                    let segmentFileURL = URL(fileURLWithPath: segmentFileName, isDirectory: false, relativeTo: outputDirectoryURL)

                    print("writing \(segment.data.count) bytes to \(segmentFileName)")
                    try segment.data.write(to: segmentFileURL)
                }
            
            // Write the index file to disk.
            let indexFileWriter = indexFileGenerator
                .tryMap { finalIndexFile in
                    let indexFileURL = URL(fileURLWithPath: config.indexFileName, isDirectory: false, relativeTo: outputDirectoryURL)
                    
                    print("writing index file to \(config.indexFileName)")
                    try finalIndexFile.write(to: indexFileURL, atomically: false, encoding: .utf8)
                }
            
            // Collect the results of segment and index file writing.
            segmentAndIndexFileWriter = segmentFileWriter.merge(with: indexFileWriter)
                .sink(receiveCompletion: { completion in
                    // Evaluate the result.
                    switch completion {
                    case .finished:
                        assert(self.builder != nil)
                        assert(segmentAndIndexFileWriter != nil)
                        print("Finished writing segment data")
                    case .failure(let error):
                        switch error {
                        case let localizedError as LocalizedError:
                            print("Error: \(localizedError.errorDescription ?? String(describing: localizedError))")
                        default:
                            print("Error: \(error)")
                        }
                    }
                }, receiveValue: {})
            
            // Now that all the processing pipelines are set up, start the flow of data and wait for completion.
            builder = generateBuilder(configuration: config, subject: segmentGenerator)
        }
        recordStarted = !recordStarted
    }
    
    private func clearTempFolder() {
        let fileManager = FileManager.default
        let tempFolderPath = NSTemporaryDirectory()
        do {
            let filePaths = try fileManager.contentsOfDirectory(atPath: tempFolderPath)
            for filePath in filePaths {
                try fileManager.removeItem(atPath: tempFolderPath + filePath)
            }
        } catch {
            print("Could not clear temp folder: \(error)")
        }
    }
}

extension ViewController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if recordStarted {
            builder?.appendPixelBuffer(frame.capturedImage)
        }
    }
}
