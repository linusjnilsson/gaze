import Accelerate
import Foundation
import simd

/// A per-user correction of the gaze network, learned from its internal features.
///
/// A generic network is off for each person in a consistent, person-specific way (eye shape,
/// glasses, how the eyelids sit), and that shows up in the features its final layer reads. Ridge
/// regression from those features to the network's error on labeled frames (calibration dots,
/// later clicks) learns this person's correction, in (pitch, yaw) in the normalized camera.
public struct FeatureCorrection: Sendable, Codable, Equatable {
    /// Feature means and a common scale, so the regularization treats every feature alike.
    var mean: [Float]
    var scale: Float
    /// `[pitch weights..., yaw weights...]`, one per feature.
    var weights: [Float]
    var offset: SIMD2<Double>

    public func correction(for features: [Float]) -> SIMD2<Double> {
        let n = mean.count
        guard features.count == n else { return .zero }
        var pitch = 0.0, yaw = 0.0
        for i in 0..<n {
            let f = Double((features[i] - mean[i]) / scale)
            pitch += f * Double(weights[i])
            yaw += f * Double(weights[n + i])
        }
        return offset + SIMD2(pitch, yaw)
    }

    /// Fits the correction for `residuals` (true minus predicted angles). Frames in the same `group`
    /// (looking at the same target) are held out together to choose the regularization, since
    /// they're far from independent. `nil` with fewer than four groups.
    public static func fit(features: [[Float]], residuals: [SIMD2<Double>], groups: [Int]) -> (correction: FeatureCorrection, heldOutError: Double, baselineError: Double)? {
        let distinct = Array(Set(groups)).sorted()
        guard distinct.count >= 4, let dimension = features.first?.count, features.count == residuals.count else { return nil }

        var mean = [Double](repeating: 0, count: dimension)
        for f in features { for i in 0..<dimension { mean[i] += Double(f[i]) } }
        mean = mean.map { $0 / Double(features.count) }
        var variance = 0.0
        for f in features { for i in 0..<dimension { variance += pow(Double(f[i]) - mean[i], 2) } }
        let scale = max((variance / Double(features.count)).squareRoot(), 1e-6)
        // Scaled features, n × d row-major.
        let n = features.count, d = dimension
        var x = [Double](repeating: 0, count: n * d)
        for (i, f) in features.enumerated() {
            for k in 0..<d { x[i * d + k] = (Double(f[k]) - mean[k]) / scale }
        }
        var xt = [Double](repeating: 0, count: d * n)
        vDSP_mtransD(x, 1, &xt, 1, vDSP_Length(d), vDSP_Length(n))
        // XᵀX, d × d: the primal form, whose size doesn't grow with the number of frames. (The
        // dual form, n × n, grew with the cube of the frames: minutes for a two-display calibration.)
        var xtx = [Double](repeating: 0, count: d * d)
        vDSP_mmulD(xt, 1, x, 1, &xtx, 1, vDSP_Length(d), vDSP_Length(d), vDSP_Length(n))

        // Residuals are centered on all frames (the fitted offset), which lets a held-out group
        // nudge its own offset by 1 / groups.
        let center = residuals.reduce(SIMD2<Double>.zero, +) / Double(n)
        // Centered residuals, n × 2 row-major, and Xᵀy, d × 2.
        var y = [Double](repeating: 0, count: n * 2)
        for (i, r) in residuals.enumerated() {
            y[i * 2] = r.x - center.x
            y[i * 2 + 1] = r.y - center.y
        }
        var xty = [Double](repeating: 0, count: d * 2)
        vDSP_mmulD(xt, 1, y, 1, &xty, 1, vDSP_Length(d), 2, vDSP_Length(n))
        let members = distinct.map { group in groups.indices.filter { groups[$0] == group } }
        let baseline = members.map { test in
            simd_length(test.reduce(SIMD2<Double>.zero) { $0 + residuals[$1] } / Double(test.count))
        }.reduce(0, +) / Double(members.count)

        // Regularization relative to the features' total variance per frame (= dimension after scaling).
        // Each strength is judged by holding out one group at a time. For ridge regression that
        // needs no refit: with the hat matrix H = X (XᵀX + λI)⁻¹ Xᵀ, a held-out group's errors are
        // (I − H_gg)⁻¹ (y − Hy)_g.
        var best: (lambda: Double, error: Double, weights: [Double])?
        for lambda in [0.01, 0.03, 0.1, 0.3, 1, 3, 10].map({ $0 * Double(d) }) {
            var a = xtx
            for i in 0..<d { a[i * d + i] += lambda }
            guard let inverse = LinearAlgebra.choleskyInverse(a, n: d) else { continue }
            // Weights (d × 2), fitted values (n × 2), and P = X (XᵀX + λI)⁻¹ (n × d), so H_ij = P_i · X_j.
            var weights = [Double](repeating: 0, count: d * 2)
            vDSP_mmulD(inverse, 1, xty, 1, &weights, 1, vDSP_Length(d), 2, vDSP_Length(d))
            var fitted = [Double](repeating: 0, count: n * 2)
            vDSP_mmulD(x, 1, weights, 1, &fitted, 1, vDSP_Length(n), 2, vDSP_Length(d))
            var p = [Double](repeating: 0, count: n * d)
            vDSP_mmulD(x, 1, inverse, 1, &p, 1, vDSP_Length(n), vDSP_Length(d), vDSP_Length(d))
            var errors: [Double] = []
            for test in members {
                let m = test.count
                var block = [Double](repeating: 0, count: m * m)
                p.withUnsafeBufferPointer { p in
                    x.withUnsafeBufferPointer { x in
                        for (r, i) in test.enumerated() {
                            for (c, j) in test.enumerated() where c >= r {
                                var h = 0.0
                                vDSP_dotprD(p.baseAddress! + i * d, 1, x.baseAddress! + j * d, 1, &h, vDSP_Length(d))
                                block[r * m + c] = (r == c ? 1 : 0) - h
                                block[c * m + r] = block[r * m + c]
                            }
                        }
                    }
                }
                let rhs = [test.map { y[$0 * 2] - fitted[$0 * 2] }, test.map { y[$0 * 2 + 1] - fitted[$0 * 2 + 1] }]
                guard let heldOut = LinearAlgebra.choleskySolve(block, n: m, rhs: rhs) else { continue }
                // Error of the group's mean prediction, as validation judges a target.
                errors.append(simd_length(SIMD2(heldOut[0].reduce(0, +), heldOut[1].reduce(0, +)) / Double(m)))
            }
            let error = errors.reduce(0, +) / Double(max(errors.count, 1))
            if best == nil || error < best!.error { best = (lambda, error, weights) }
        }
        guard let best else { return nil }
        // Weights as [pitch..., yaw...].
        let weights = (0..<d).map { best.weights[$0 * 2] } + (0..<d).map { best.weights[$0 * 2 + 1] }
        let correction = FeatureCorrection(mean: mean.map(Float.init), scale: Float(scale), weights: weights.map(Float.init), offset: center)
        return (correction, best.error, baseline)
    }
}
