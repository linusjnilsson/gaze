import CoreGraphics
import Foundation
import simd

/// Millimeters in camera space: +x to the right in the camera image, +y up, +z away from the camera.
public typealias Vec3 = SIMD3<Double>

/// Pinhole model of the camera, in pixels with a lower-left origin (Vision's convention).
public struct CameraIntrinsics: Sendable, Equatable {
    public var focalLength: Double
    public var center: SIMD2<Double>

    public init(imageWidth: Double, imageHeight: Double, horizontalFOVDegrees: Double) {
        // Mac cameras report their field of view; fall back to a typical FaceTime camera if not.
        let degrees = (10...170).contains(horizontalFOVDegrees) ? horizontalFOVDegrees : 70
        focalLength = imageWidth / 2 / tan(degrees * .pi / 360)
        center = SIMD2(imageWidth / 2, imageHeight / 2)
    }

    public func project(_ p: Vec3) -> SIMD2<Double> {
        SIMD2(p.x / p.z, p.y / p.z) * focalLength + center
    }

    /// Unit ray from the camera center through a pixel.
    public func ray(through pixel: SIMD2<Double>) -> Vec3 {
        let d = (pixel - center) / focalLength
        return simd_normalize(Vec3(d.x, d.y, 1))
    }
}

public enum Rotation {
    /// Rodrigues: a rotation vector (axis × angle in radians) to a matrix.
    public static func matrix(_ v: Vec3) -> simd_double3x3 {
        let angle = simd_length(v)
        guard angle > 1e-12 else { return matrix_identity_double3x3 }
        return simd_double3x3(simd_quatd(angle: angle, axis: v / angle))
    }

    /// Yaw, pitch, and roll in radians of a head rotation, for display. Zero when facing the camera.
    public static func headAngles(_ m: simd_double3x3) -> Vec3 {
        let forward = m * Vec3(0, 0, -1)
        let up = m * Vec3(0, 1, 0)
        return Vec3(
            atan2(forward.x, -forward.z),
            atan2(forward.y, (forward.x * forward.x + forward.z * forward.z).squareRoot()),
            atan2(-up.x, up.y)
        )
    }
}

enum LinearAlgebra {
    /// Solves `A x = b` for each `b` in `rhs`, where `A` is symmetric positive-definite (row-major n×n).
    static func choleskySolve(_ a: [Double], n: Int, rhs: [[Double]]) -> [[Double]]? {
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = a[i * n + j]
                for k in 0..<j {
                    sum -= l[i * n + k] * l[j * n + k]
                }
                if i == j {
                    guard sum > 1e-12 else { return nil }
                    l[i * n + i] = sum.squareRoot()
                } else {
                    l[i * n + j] = sum / l[j * n + j]
                }
            }
        }
        return rhs.map { b in
            var y = [Double](repeating: 0, count: n)
            for i in 0..<n {
                var s = b[i]
                for k in 0..<i {
                    s -= l[i * n + k] * y[k]
                }
                y[i] = s / l[i * n + i]
            }
            var x = y
            for i in stride(from: n - 1, through: 0, by: -1) {
                var s = y[i]
                for k in (i + 1)..<n {
                    s -= l[k * n + i] * x[k]
                }
                x[i] = s / l[i * n + i]
            }
            return x
        }
    }
}

enum LeastSquares {
    /// Levenberg–Marquardt with a forward-difference Jacobian. `steps` is the finite-difference
    /// step per parameter, which should match that parameter's scale.
    static func minimize(
        _ initial: [Double],
        steps: [Double],
        iterations: Int = 30,
        residuals: ([Double]) -> [Double]
    ) -> [Double] {
        let n = initial.count
        var p = initial
        var r = residuals(p)
        var cost = sumOfSquares(r)
        var damping = 1e-3

        for _ in 0..<iterations {
            var columns: [[Double]] = []
            columns.reserveCapacity(n)
            for j in 0..<n {
                var q = p
                q[j] += steps[j]
                let rq = residuals(q)
                columns.append(zip(rq, r).map { ($0 - $1) / steps[j] })
            }

            var jtj = [Double](repeating: 0, count: n * n)
            var jtr = [Double](repeating: 0, count: n)
            for i in 0..<n {
                jtr[i] = zip(columns[i], r).reduce(0) { $0 + $1.0 * $1.1 }
                for j in 0...i {
                    let v = zip(columns[i], columns[j]).reduce(0) { $0 + $1.0 * $1.1 }
                    jtj[i * n + j] = v
                    jtj[j * n + i] = v
                }
            }

            var improved = false
            for _ in 0..<10 {
                var a = jtj
                for i in 0..<n {
                    a[i * n + i] += damping * max(jtj[i * n + i], 1e-9)
                }
                guard let delta = LinearAlgebra.choleskySolve(a, n: n, rhs: [jtr.map { -$0 }])?.first else {
                    damping *= 10
                    continue
                }
                let q = zip(p, delta).map(+)
                let rq = residuals(q)
                let c = sumOfSquares(rq)
                if c < cost {
                    let relative = (cost - c) / max(cost, 1e-12)
                    p = q
                    r = rq
                    cost = c
                    damping = max(damping * 0.3, 1e-9)
                    improved = relative > 1e-10
                    break
                }
                damping *= 10
            }
            if !improved { break }
        }
        return p
    }

    private static func sumOfSquares(_ r: [Double]) -> Double {
        r.reduce(0) { $0 + $1 * $1 }
    }
}

public func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

/// Per-axis median, which is robust to the occasional wild prediction.
public func median(_ points: [CGPoint]) -> CGPoint {
    CGPoint(x: median(points.map { Double($0.x) }), y: median(points.map { Double($0.y) }))
}
