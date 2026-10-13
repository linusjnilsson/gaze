import Foundation
import simd

/// A learned, smooth correction for what the geometric model still gets wrong on one display:
/// errors that vary with where on screen you look and how your head is positioned (iris detection
/// bias toward the corners, the generic face model's mismatch at some head angles, …).
///
/// Kernel ridge regression with a Gaussian kernel on the geometric hit point and head pose. Far
/// from any training data it fades to zero, leaving the geometric prediction untouched.
public struct ResidualCorrection: Sendable, Codable, Equatable {
    public var displayID: UInt32
    var mean: [Double]
    var scale: [Double]
    /// Standardized feature vectors of the training points.
    var centers: [[Double]]
    var alphaX: [Double]
    var alphaY: [Double]
    var bandwidth: Double

    /// Corrections are capped (millimeters) so the learned layer refines geometry but never overrides it.
    public static let limit = 60.0

    /// Smallest standard deviation per feature (radians), so a feature that barely varied during
    /// learning (e.g. a head that sat still) doesn't get blown up into noise.
    static let minimumScale: [Double] = [0.03, 0.03, 0.05, 0.05]

    /// Eye-in-head yaw and pitch plus head yaw and pitch, in radians. What's left after geometry
    /// stems mainly from where the iris sits in the eye (detection bias) and how well the generic
    /// face fits at a given head angle; head position is already handled geometrically.
    static func features(observation o: GazeObservation) -> [Double] {
        let head = Rotation.headAngles(o.headRotation)
        return [o.eyeAngles.x, o.eyeAngles.y, head.x, head.y]
    }

    public func correction(for features: [Double]) -> SIMD2<Double> {
        let z = standardize(features)
        let g = -0.5 / (bandwidth * bandwidth)
        var v = SIMD2<Double>.zero
        for (i, center) in centers.enumerated() {
            var d2 = 0.0
            for j in z.indices {
                let d = z[j] - center[j]
                d2 += d * d
            }
            let k = exp(g * d2)
            v.x += alphaX[i] * k
            v.y += alphaY[i] * k
        }
        let length = simd_length(v)
        return length > Self.limit ? v * (Self.limit / length) : v
    }

    /// Fits `residuals` (target − geometric hit, mm) with per-point `weights`. A higher `lambda`
    /// trusts the data less; low-weight points are trusted proportionally less.
    static func fit(
        displayID: UInt32,
        features: [[Double]],
        residuals: [SIMD2<Double>],
        weights: [Double],
        bandwidth: Double,
        lambda: Double
    ) -> ResidualCorrection? {
        let n = features.count
        guard n >= 20, let dimension = features.first?.count else { return nil }

        var mean = [Double](repeating: 0, count: dimension)
        for f in features {
            for j in 0..<dimension { mean[j] += f[j] / Double(n) }
        }
        var scale = [Double](repeating: 0, count: dimension)
        for f in features {
            for j in 0..<dimension { scale[j] += (f[j] - mean[j]) * (f[j] - mean[j]) / Double(n) }
        }
        scale = zip(scale, minimumScale).map { max($0.squareRoot(), $1) }

        var partial = ResidualCorrection(displayID: displayID, mean: mean, scale: scale, centers: [], alphaX: [], alphaY: [], bandwidth: bandwidth)
        let centers = features.map(partial.standardize)
        let maxWeight = weights.max() ?? 1

        let g = -0.5 / (bandwidth * bandwidth)
        var kernel = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var d2 = 0.0
                for k in 0..<dimension {
                    let d = centers[i][k] - centers[j][k]
                    d2 += d * d
                }
                let value = exp(g * d2)
                kernel[i * n + j] = value
                kernel[j * n + i] = value
            }
            kernel[i * n + i] += lambda * maxWeight / max(weights[i], 1e-6)
        }
        guard let alphas = LinearAlgebra.choleskySolve(kernel, n: n, rhs: [residuals.map(\.x), residuals.map(\.y)]) else { return nil }

        partial.centers = centers
        partial.alphaX = alphas[0]
        partial.alphaY = alphas[1]
        return partial
    }

    private func standardize(_ f: [Double]) -> [Double] {
        zip(f, zip(mean, scale)).map { ($0 - $1.0) / $1.1 }
    }
}
