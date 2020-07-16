/*
See LICENSE folder for this sample’s licensing information.

Abstract:
The sample app's main view controller.
*/

import UIKit
import ARKit
import Combine
import VideoToolbox
import SceneKit
import SCNRecorder

class ViewController: UIViewController {

    @IBOutlet var sceneView: ARSCNView!
    @IBOutlet var messageLabel: RoundedLabel!
    @IBOutlet weak var durationLabel: UILabel!
    private var recordStarted = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        sceneView.rendersContinuously = true
        
        // Add black plane in front of camera
        let plane = SCNPlane(width: 10.0, height: 10.0)
        plane.firstMaterial?.diffuse.contents = UIColor.black
        let planeNode = SCNNode(geometry: plane)
        sceneView.pointOfView?.addChildNode(planeNode)
        planeNode.position = SCNVector3(0, 0, -5)
        
        // It is recommended to prepare the view for recording at viewDidLoad
        do { try sceneView.prepareForRecording() }
        catch { print("Something went wrong during recording preparation: \(error)") }
        
        self.durationLabel.text = nil
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        let sessionConfig = ARFaceTrackingConfiguration()
        sessionConfig.providesAudioData = true
        sessionConfig.frameSemantics.insert(.personSegmentation)
        sceneView.session.run(sessionConfig, options: [])
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        sceneView.session.pause()
    }

    @IBAction func onTap(_ sender: UITapGestureRecognizer) {
        if recordStarted {
            messageLabel.displayMessage("Recording ended", duration: 1.0)
            
            // Finish recording
            sceneView.finishVideoRecording { (recording) in
              // Update UI
              self.durationLabel.text = nil
            }
        } else {
            messageLabel.displayMessage("Recording started", duration: 1.0)
            do {
              let videoRecording = try sceneView.startVideoRecording(fileType: .mp4, timeScale: 600, segmentation: true)
              
              // Observe for duration
              videoRecording.duration.observer = { [weak self] duration in
                DispatchQueue.main.async {
                  let seconds = Int(duration)
                  self?.durationLabel.text = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                }
              }
            }
            catch { print("Something went wrong during video-recording preparation: \(error)") }
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
