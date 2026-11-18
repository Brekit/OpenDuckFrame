import Foundation
func require(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
for fps in [60.0, 60_000.0/1_001, 30.0, 30_000.0/1_001, 120.0] {
    var gate = CaptureCardRateGate()
    let target = CaptureCardPolicy.sourceFPS(captureFPS: fps, thirtyFPS: true)!
    let n = Int(fps * 10)
    let accepted = (0..<n).filter { gate.accepts(Double($0)/fps, sourceFPS: target) }.count
    require(abs(Double(accepted) - target*10) <= 2, "Rate drift at \(fps): \(accepted)")
}
var gate = CaptureCardRateGate()
require(gate.accepts(10, sourceFPS: 30), "first frame")
require(!gate.accepts(10.01, sourceFPS: 30), "early frame")
require(gate.accepts(0, sourceFPS: 30), "clock reset")
require(!gate.accepts(.nan, sourceFPS: 30), "invalid timestamp")
require(gate.accepts(1, sourceFPS: nil), "passthrough")
let qhd = CaptureCardPolicy.score(width:2560,height:1440,fps:60,compressed:false,displayWidth:2560,displayHeight:1440)
let uhd = CaptureCardPolicy.score(width:3840,height:2160,fps:60,compressed:false,displayWidth:2560,displayHeight:1440)
require(qhd < uhd, "Prefer display-size native capture")
print("Capture card rate and recommendation policies passed")
