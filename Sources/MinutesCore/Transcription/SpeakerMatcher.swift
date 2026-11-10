import Foundation

/// Keeps speaker labels consistent across recording parts of one meeting (resumed or merged calls):
/// a newly diarized speaker whose voice embedding matches an existing one gets that speaker's label.
public enum SpeakerMatcher {
    /// Cosine similarity above which two diarization embeddings are taken as the same person.
    /// Measured on real calls: same person across two parts 0.93, different people 0.11.
    public static let threshold: Float = 0.6

    /// Maps each new label to its final label. Matched speakers take the existing label; unmatched ones keep their
    /// label if it is still free, otherwise get the next free "Speaker N". "Me" and "Them" stay as they are.
    /// New embeddings are added to `existingEmbeddings` under their final labels.
    public static func mapping(
        newLabels: [String], newEmbeddings: [String: [Float]], existingLabels: Set<String>,
        existingEmbeddings: inout [String: [Float]]
    ) -> [String: String] {
        var order: [String] = []
        for label in newLabels where !order.contains(label) { order.append(label) }
        var result: [String: String] = [:]
        var taken = existingLabels.union(existingEmbeddings.keys)
        var claimed: Set<String> = []

        // Best matches first, one-to-one.
        var pairs: [(new: String, old: String, score: Float)] = []
        for (new, vector) in newEmbeddings where order.contains(new) {
            for (old, ref) in existingEmbeddings {
                let score = cosine(vector, ref)
                if score >= threshold { pairs.append((new, old, score)) }
            }
        }
        for pair in pairs.sorted(by: { $0.score > $1.score }) where result[pair.new] == nil && !claimed.contains(pair.old) {
            result[pair.new] = pair.old
            claimed.insert(pair.old)
        }

        var next = (taken.compactMap { Int($0.replacingOccurrences(of: "Speaker ", with: "")) }.max() ?? 0) + 1
        for label in order where result[label] == nil {
            if label == "Me" || label == "Them" {
                result[label] = label
            } else if !taken.contains(label) {
                result[label] = label
            } else {
                while taken.contains("Speaker \(next)") { next += 1 }
                result[label] = "Speaker \(next)"
            }
            taken.insert(result[label]!)
        }
        for (label, vector) in newEmbeddings {
            guard let final = result[label] else { continue }
            if existingEmbeddings[final] == nil { existingEmbeddings[final] = vector }
        }
        return result
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
}
