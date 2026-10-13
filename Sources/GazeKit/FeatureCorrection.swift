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
        let x = features.map { f in (0..<dimension).map { (Double(f[$0]) - mean[$0]) / scale } }

        // Gram matrix: with fewer frames than features, the dual form is the smaller problem.
        let n = x.count
        var gram = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var dot = 0.0
                for k in 0..<dimension { dot += x[i][k] * x[j][k] }
                gram[i * n + j] = dot
                gram[j * n + i] = dot
            }
        }

        /// Dual coefficients and offset fitted on `rows`.
        func solve(_ rows: [Int], lambda: Double) -> (alpha: [SIMD2<Double>], offset: SIMD2<Double>)? {
            let m = rows.count
            let offset = rows.reduce(SIMD2<Double>.zero) { $0 + residuals[$1] } / Double(m)
            var a = [Double](repeating: 0, count: m * m)
            for (p, i) in rows.enumerated() {
                for (q, j) in rows.enumerated() { a[p * m + q] = gram[i * n + j] }
                a[p * m + p] += lambda
            }
            let rhs = [rows.map { residuals[$0].x - offset.x }, rows.map { residuals[$0].y - offset.y }]
            guard let solution = LinearAlgebra.choleskySolve(a, n: m, rhs: rhs) else { return nil }
            return (zip(solution[0], solution[1]).map { SIMD2($0, $1) }, offset)
        }
        // Regularization relative to the features' total variance per frame (= dimension after scaling).
        // Each strength is judged by holding out one group at a time. For ridge regression that
        // needs no refit: with A = (K + λI)⁻¹, a held-out group's errors are A_gg⁻¹ (A y)_g. One
        // inverse per strength instead of one solve per group keeps a calibration with a moving
        // dot (about 50 groups, 500 frames) quick. Residuals are centered on all frames (the
        // fitted offset), which lets a held-out group nudge its own offset by 1 / groups.
        let base = Double(dimension)
        let center = residuals.reduce(SIMD2<Double>.zero, +) / Double(n)
        let centered = [residuals.map { $0.x - center.x }, residuals.map { $0.y - center.y }]
        let members = distinct.map { group in groups.indices.filter { groups[$0] == group } }
        let identity = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0 } }
        var best: (lambda: Double, error: Double)?
        var baseline = 0.0
        for lambda in [0.01, 0.03, 0.1, 0.3, 1, 3, 10].map({ $0 * base }) {
            var a = gram
            for i in 0..<n { a[i * n + i] += lambda }
            guard let inverse = LinearAlgebra.choleskySolve(a, n: n, rhs: identity) else { continue }
            let ay = centered.map { y in (0..<n).map { i in (0..<n).reduce(0.0) { $0 + inverse[i][$1] * y[$1] } } }
            var errors: [Double] = []
            var baselineErrors: [Double] = []
            for test in members {
                let m = test.count
                var block = [Double](repeating: 0, count: m * m)
                for (p, i) in test.enumerated() { for (q, j) in test.enumerated() { block[p * m + q] = inverse[i][j] } }
                guard let heldOut = LinearAlgebra.choleskySolve(block, n: m, rhs: ay.map { y in test.map { y[$0] } }) else { continue }
                // Error of the group's mean prediction, as validation judges a target.
                errors.append(simd_length(SIMD2(heldOut[0].reduce(0, +), heldOut[1].reduce(0, +)) / Double(m)))
                baselineErrors.append(simd_length(test.reduce(SIMD2<Double>.zero) { $0 + residuals[$1] } / Double(m)))
            }
            let error = errors.reduce(0, +) / Double(max(errors.count, 1))
            baseline = baselineErrors.reduce(0, +) / Double(max(baselineErrors.count, 1))
            if best == nil || error < best!.error { best = (lambda, error) }
        }
        let all = Array(0..<n)
        guard let best, let fit = solve(all, lambda: best.lambda) else { return nil }
        var weights = [Double](repeating: 0, count: 2 * dimension)
        for (i, alpha) in fit.alpha.enumerated() {
            for k in 0..<dimension {
                weights[k] += alpha.x * x[i][k]
                weights[dimension + k] += alpha.y * x[i][k]
            }
        }
        let correction = FeatureCorrection(mean: mean.map(Float.init), scale: Float(scale), weights: weights.map(Float.init), offset: fit.offset)
        return (correction, best.error, baseline)
    }
}
