import XCTest
@testable import MapboxMaps

final class ZoomPinchChangedBehaviorTests: BasePinchChangedBehaviorTests {
    override func setUp() {
        super.setUp()
        behavior = ZoomPinchBehavior(
            initialCameraState: initialCameraState,
            initialPinchMidpoint: initialPinchMidpoint,
            mapboxMap: mapboxMap)
    }

    func testUpdate() {
        let pinchScale = CGFloat.random(in: 0.1..<10)

        behavior.update(
            pinchMidpoint: .random(),
            pinchScale: pinchScale,
            pinchAngle: .random(in: 0..<2 * .pi))

        XCTAssertEqual(
            mapboxMap.setCameraStub.invocations.map(\.parameters),
            [CameraOptions(
                anchor: initialPinchMidpoint,
                zoom: initialCameraState.zoom + log2(pinchScale))])
    }
}
