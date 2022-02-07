import CoreLocation
import UIKit
@_spi(Experimental) public final class DefaultViewportTransition {

    // modifications to options will take effect the next
    // time run(from:to:completion:) is invoked
    public var options: DefaultViewportTransitionOptions

    private let animationHelper: DefaultViewportTransitionAnimationHelperProtocol

    private let cameraAnimationsManager: CameraAnimationsManagerProtocol

    internal init(options: DefaultViewportTransitionOptions,
                  animationHelper: DefaultViewportTransitionAnimationHelperProtocol,
                  cameraAnimationsManager: CameraAnimationsManagerProtocol) {
        self.options = options
        self.animationHelper = animationHelper
        self.cameraAnimationsManager = cameraAnimationsManager
    }
}

extension DefaultViewportTransition: ViewportTransition {
    public func run(to toState: ViewportState,
                    completion: @escaping (Bool) -> Void) -> Cancelable {
        let resultCancelable = CompositeCancelable()

        resultCancelable.add(toState.observeDataSource { [options, animationHelper] cameraOptions in

            resultCancelable.add(animationHelper.animate(
                to: cameraOptions,
                maxDuration: options.maxDuration * 8 / 10) { (finished) in
                    guard finished else {
                        completion(false)
                        return
                    }

                    let catchUpAnimator = self.cameraAnimationsManager.makeCatchUpAnimator(
                        toCameraOptions: cameraOptions,
                        duration: options.maxDuration * 2 / 10)

                    let observeDataSourceCancelable = toState.observeDataSource { cameraOptions in
                        catchUpAnimator.toCameraOptions = cameraOptions
                        return true
                    }

                    resultCancelable.add(observeDataSourceCancelable)

                    catchUpAnimator.completion = { (finished) in
                        observeDataSourceCancelable.cancel()
                        completion(finished)
                    }

                    catchUpAnimator.startAnimation()

                    resultCancelable.add(catchUpAnimator)
                })
            // stop receiving updates (ignore moving targets)
            return false
        })
        return resultCancelable
    }
}

internal final class CatchUpAnimator: NSObject, CameraAnimatorInterface {

    internal var toCameraOptions: CameraOptions
    internal var completion: ((Bool) -> Void)?

    private var startDate: Date?
    private let duration: TimeInterval

    private let cameraOptionsInterpolator: CameraOptionsInterpolatorProtocol
    private let mapboxMap: MapboxMapProtocol
    private let dateProvider: DateProvider
    private weak var delegate: CameraAnimatorDelegate?

    private let cancelableContainer = CancelableContainer()

    internal init(toCameraOptions: CameraOptions,
                  duration: TimeInterval,
                  cameraOptionsInterpolator: CameraOptionsInterpolatorProtocol,
                  mapboxMap: MapboxMapProtocol,
                  dateProvider: DateProvider,
                  delegate: CameraAnimatorDelegate) {
        self.toCameraOptions = toCameraOptions
        self.duration = duration
        self.cameraOptionsInterpolator = cameraOptionsInterpolator
        self.mapboxMap = mapboxMap
        self.dateProvider = dateProvider
        self.delegate = delegate
        super.init()
    }

    internal private(set) var state: UIViewAnimatingState = .inactive

    internal func cancel() {
        stopAnimation()
    }

    internal func startAnimation() {
        assert(startDate == nil)
        startDate = dateProvider.now
        state = .active
        delegate?.cameraAnimatorDidStartRunning(self)
    }

    internal func stopAnimation() {
        state = .inactive
        delegate?.cameraAnimatorDidStopRunning(self)
        completion?(false)
        completion = nil
    }

    internal func update() {
        guard let startDate = startDate, let completion = completion else {
            return
        }

        let percent = dateProvider.now.timeIntervalSince(startDate) / duration

        let fromCameraOptions = CameraOptions(cameraState: mapboxMap.cameraState, anchor: nil)

        let newCameraOptions = cameraOptionsInterpolator.interpolate(from: fromCameraOptions, to: toCameraOptions, percent: percent)

        mapboxMap.setCamera(to: newCameraOptions)

        if percent >= 1 {
            completion(true)
            self.completion = nil
        }
    }
}

internal protocol CameraOptionsInterpolatorProtocol: AnyObject {
    func interpolate(from fromCameraOptions: CameraOptions,
                     to toCameraOptions: CameraOptions,
                     percent: Double) -> CameraOptions
}

internal final class CameraOptionsInterpolator: CameraOptionsInterpolatorProtocol {
    private let coordinateInterpolator: CoordinateInterpolatorProtocol
    private let edgeInsetsInterpolator: EdgeInsetsInterpolatorProtocol
    private let pointInterpolator: PointInterpolatorProtocol
    private let interpolator: InterpolatorProtocol
    private let directionInterpolator: InterpolatorProtocol

    internal init(coordinateInterpolator: CoordinateInterpolatorProtocol,
                  edgeInsetsInterpolator: EdgeInsetsInterpolatorProtocol,
                  pointInterpolator: PointInterpolatorProtocol,
                  interpolator: InterpolatorProtocol,
                  directionInterpolator: InterpolatorProtocol) {
        self.coordinateInterpolator = coordinateInterpolator
        self.edgeInsetsInterpolator = edgeInsetsInterpolator
        self.pointInterpolator = pointInterpolator
        self.interpolator = interpolator
        self.directionInterpolator = directionInterpolator
    }

    internal func interpolate(from fromCameraOptions: CameraOptions,
                     to toCameraOptions: CameraOptions,
                     percent: Double) -> CameraOptions {
        let center = optionalInterpolate(from: fromCameraOptions.center, to: toCameraOptions.center, percent: percent, interpolate: coordinateInterpolator.interpolate(from:to:percent:))
        let padding = optionalInterpolate(from: fromCameraOptions.padding, to: toCameraOptions.padding, percent: percent, interpolate: edgeInsetsInterpolator.interpolate(from:to:percent:))
        let anchor = optionalInterpolate(from: fromCameraOptions.anchor, to: toCameraOptions.anchor, percent: percent, interpolate: pointInterpolator.interpolate(from:to:percent:))
        let zoom = optionalInterpolate(from: fromCameraOptions.zoom.map(Double.init(_:)), to: toCameraOptions.zoom.map(Double.init(_:)), percent: percent, interpolate: interpolator.interpolate(from:to:percent:))
        let bearing = optionalInterpolate(from: fromCameraOptions.bearing, to: toCameraOptions.bearing, percent: percent, interpolate: directionInterpolator.interpolate(from:to:percent:))
        let pitch = optionalInterpolate(from: fromCameraOptions.pitch.map(Double.init(_:)), to: toCameraOptions.pitch.map(Double.init(_:)), percent: percent, interpolate: interpolator.interpolate(from:to:percent:))

        return CameraOptions(
            center: center,
            padding: padding,
            anchor: anchor,
            zoom: zoom.map(CGFloat.init(_:)),
            bearing: bearing,
            pitch: pitch.map(CGFloat.init(_:)))
    }

    private func optionalInterpolate<T>(from: T?, to: T?, percent: Double, interpolate: (T, T, Double) -> T) -> T? {
        if let from = from, let to = to {
            return interpolate(from, to, percent)
        } else {
            return to
        }
    }
}

internal protocol CoordinateInterpolatorProtocol: AnyObject {
    func interpolate(from fromCoordinate: CLLocationCoordinate2D,
                     to toCoordinate: CLLocationCoordinate2D,
                     percent: Double) -> CLLocationCoordinate2D
}

internal final class CoordinateInterpolator: CoordinateInterpolatorProtocol {
    private let interpolator: InterpolatorProtocol
    private let latitudeInterpolator: InterpolatorProtocol

    internal init(interpolator: InterpolatorProtocol,
                  latitudeInterpolator: InterpolatorProtocol) {
        self.interpolator = interpolator
        self.latitudeInterpolator = latitudeInterpolator
    }

    internal func interpolate(from fromCoordinate: CLLocationCoordinate2D,
                              to toCoordinate: CLLocationCoordinate2D,
                              percent: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: latitudeInterpolator.interpolate(
                from: fromCoordinate.latitude,
                to: toCoordinate.latitude,
                percent: percent),
            longitude: interpolator.interpolate(
                from: fromCoordinate.longitude,
                to: toCoordinate.longitude,
                percent: percent))
    }
}

internal protocol EdgeInsetsInterpolatorProtocol: AnyObject {
    func interpolate(from fromEdgeInsets: UIEdgeInsets,
                     to toEdgeInsets: UIEdgeInsets,
                     percent: Double) -> UIEdgeInsets
}

internal final class EdgeInsetsInterpolator: EdgeInsetsInterpolatorProtocol {
    private let interpolator: InterpolatorProtocol

    internal init(interpolator: InterpolatorProtocol) {
        self.interpolator = interpolator
    }

    internal func interpolate(from fromEdgeInsets: UIEdgeInsets,
                              to toEdgeInsets: UIEdgeInsets,
                              percent: Double) -> UIEdgeInsets {
        UIEdgeInsets(
            top: interpolator.interpolate(from: fromEdgeInsets.top, to: toEdgeInsets.top, percent: percent),
            left: interpolator.interpolate(from: fromEdgeInsets.left, to: toEdgeInsets.left, percent: percent),
            bottom: interpolator.interpolate(from: fromEdgeInsets.bottom, to: toEdgeInsets.bottom, percent: percent),
            right: interpolator.interpolate(from: fromEdgeInsets.right, to: toEdgeInsets.right, percent: percent))
    }
}

internal protocol PointInterpolatorProtocol: AnyObject {
    func interpolate(from fromPoint: CGPoint,
                     to toPoint: CGPoint,
                     percent: Double) -> CGPoint
}

internal final class PointInterpolator: PointInterpolatorProtocol {
    private let interpolator: InterpolatorProtocol

    internal init(interpolator: InterpolatorProtocol) {
        self.interpolator = interpolator
    }

    internal func interpolate(from fromPoint: CGPoint,
                              to toPoint: CGPoint,
                              percent: Double) -> CGPoint {
        CGPoint(
            x: interpolator.interpolate(
                from: fromPoint.x,
                to: toPoint.x,
                percent: percent),
            y: interpolator.interpolate(
                from: fromPoint.y,
                to: toPoint.y,
                percent: percent))
    }
}
