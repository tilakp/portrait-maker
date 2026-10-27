enum LinearAlgebra {
    /// Least squares: the x that makes `rows * x` nearest to `values`. Solves the normal
    /// equations with Gaussian elimination. Returns nil when the system is singular.
    static func leastSquares(_ rows: [[Double]], _ values: [Double]) -> [Double]? {
        guard let n = rows.first?.count, rows.count >= n else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for (row, v) in zip(rows, values) {
            for r in 0..<n {
                for c in 0..<n { a[r][c] += row[r] * row[c] }
                a[r][n] += row[r] * v
            }
        }
        return solve(a)
    }

    /// Solves a square system given as an augmented matrix [A | b], with partial pivoting.
    static func solve(_ augmented: [[Double]]) -> [Double]? {
        var a = augmented
        let n = a.count
        for col in 0..<n {
            let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) })!
            a.swapAt(col, pivot)
            guard abs(a[col][col]) > 1e-12 else { return nil }
            for r in 0..<n where r != col {
                let f = a[r][col] / a[col][col]
                for c in col...n { a[r][c] -= f * a[col][c] }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }
}
