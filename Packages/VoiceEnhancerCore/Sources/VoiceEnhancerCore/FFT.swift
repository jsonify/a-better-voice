import Foundation

/// In-place iterative radix-2 complex FFT. Pure Swift, so it behaves the same on every platform.
final class FFT {
    let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReversed: [Int]

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        let half = size / 2
        cosTable = (0..<half).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sinTable = (0..<half).map { Float(sin(2 * Double.pi * Double($0) / Double(size))) }
        var bits = 0
        while 1 << bits < size { bits += 1 }
        bitReversed = (0..<size).map { index in
            var reversed = 0
            var value = index
            for _ in 0..<bits {
                reversed = (reversed << 1) | (value & 1)
                value >>= 1
            }
            return reversed
        }
    }

    func forward(real: inout [Float], imag: inout [Float]) {
        transform(real: &real, imag: &imag, inverse: false)
    }

    /// Inverse transform, scaled by 1/size so that `inverse(forward(x)) == x`.
    func inverse(real: inout [Float], imag: inout [Float]) {
        transform(real: &real, imag: &imag, inverse: true)
        let scale = 1 / Float(size)
        for index in 0..<size {
            real[index] *= scale
            imag[index] *= scale
        }
    }

    private func transform(real: inout [Float], imag: inout [Float], inverse: Bool) {
        precondition(real.count == size && imag.count == size)
        let n = size
        let sign: Float = inverse ? 1 : -1
        cosTable.withUnsafeBufferPointer { cosines in
            sinTable.withUnsafeBufferPointer { sines in
                bitReversed.withUnsafeBufferPointer { order in
                    real.withUnsafeMutableBufferPointer { re in
                        imag.withUnsafeMutableBufferPointer { im in
                            for i in 0..<n {
                                let j = order[i]
                                if j > i {
                                    re.swapAt(i, j)
                                    im.swapAt(i, j)
                                }
                            }
                            var length = 2
                            while length <= n {
                                let half = length / 2
                                let step = n / length
                                var start = 0
                                while start < n {
                                    for k in 0..<half {
                                        let c = cosines[k * step]
                                        let s = sign * sines[k * step]
                                        let top = start + k
                                        let bottom = top + half
                                        let tRe = re[bottom] * c - im[bottom] * s
                                        let tIm = re[bottom] * s + im[bottom] * c
                                        re[bottom] = re[top] - tRe
                                        im[bottom] = im[top] - tIm
                                        re[top] += tRe
                                        im[top] += tIm
                                    }
                                    start += length
                                }
                                length *= 2
                            }
                        }
                    }
                }
            }
        }
    }
}
