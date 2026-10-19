import Accelerate
import Foundation

// A neural scorer for the identification layer's lattice (see `ScriptTaggerLattice`): a bidirectional LSTM reads the
// keys, then a layer gives each key its tag scores and each run of keys its score as one Latin word, from the LSTM's
// states at its ends and what is known about it as a word. It reads the same as the linear model (`ScriptTaggerModel`),
// but learns which combinations matter. Trained offline on what `NeuralInputs` exports.

/// What the neural scorer reads about the keys of an input, as small numbers: the same for training and in use
struct NeuralInputs {
    /// For each key: letter, digit or symbol (0 is padding)
    var characters: [UInt8] = []
    /// For each key: lower case letter 0, capital 1, digit 2, other 3
    var cases: [UInt8] = []
    /// For each key, bits: romaji whole before it, whole after it, letters left unread after it, the first key, the last
    /// key, a word of the analysis as Japanese starts at it, the analysis says nothing about it, the analysis's word is
    /// one the dictionary does not know
    var flags: [UInt8] = []
    /// For each key, the character models' four scores (see `CharacterModels.scores`)
    var models: [Int8] = []
    /// For each key, from the analysis: the word's length, its value per character, the kind of characters it is
    /// written in (4 when none), the value of the whole reading per character
    var analysis: [UInt8] = []
    /// For each key, the part of speech of its word in the analysis (`noPartOfSpeech` when none)
    var partsOfSpeech: [UInt16] = []
    /// For each key, the lexicon's four values (see `ScriptTaggerFeatures.lexicon(of:in:)`)
    var lexicon: [UInt8] = []
    /// For each key, what is known about the keys from it as one word, for each length (see `KeyShape.words`)
    var words: [[UInt8]] = []
    /// For each key, the second pass's evidence (see `ScriptTaggerFeatures.evidence`): for the keys before it, then
    /// for the keys from it, each its kind, the word's length, whether the word is unknown, its value, the total value
    var evidence: [UInt8] = []
    /// For each key, the part of speech of the word before it and of the word from it in that evidence
    var evidenceParts: [UInt16] = []
    /// For each key, its context (see `ScriptTaggerFeatures.conditionedAnalyses`): whether a word starts at it, the
    /// word's length, its value, the kind of characters it is written in (4 when none), the total value, how far the
    /// analysis's position is, whether the word is unknown, whether any analysis reads the key
    var context: [UInt8] = []
    /// For each key, the part of speech of its context's word (`noPartOfSpeech` when none)
    var contextParts: [UInt16] = []
    /// Whether the shape had the context (without it, the context is the default for every key)
    var hasContext = false
    /// Whether the shape had the evidence (without it, every key's evidence is unselected)
    var hasEvidence = false
    /// A key's context when no analysis reads it, or the shape has none
    static let noContext: [UInt8] = [0, 0, 0, 4, 0, 24, 0, 0]
    var isComplete = false

    static let noPartOfSpeech: UInt16 = 1399
    static let characterCount = 45

    /// The index of a key's character: a to z, 0 to 9, - , . + ? !, other ASCII, anything else
    static func characterIndex(_ key: Character) -> UInt8 {
        guard key.isASCII, let scalar = key.lowercased().unicodeScalars.first else {
            return 1
        }
        switch scalar.value {
        case 97 ... 122:
            return UInt8(scalar.value - 97 + 2)
        case 48 ... 57:
            return UInt8(scalar.value - 48 + 28)
        default:
            return UInt8(38 + (Array("-,.+?!").firstIndex(of: Character(scalar)) ?? 6))
        }
    }

    init(keys: [Character], shape: ScriptTaggerFeatures.KeyShape) {
        let count = keys.count
        for (index, key) in keys.enumerated() {
            self.characters.append(Self.characterIndex(key))
            self.cases.append(key.isUppercase ? 1 : key.isLetter ? 0 : key.isNumber ? 2 : 3)
            let analysis = shape.morphology?[index] ?? ScriptTaggerFeatures.noMorphology
            let analyzed = analysis != ScriptTaggerFeatures.noMorphology
            var flags: UInt8 = 0
            for (bit, isOn) in [
                shape.boundary[index], shape.boundary[index + 1], shape.pending[index], index == 0, index == count - 1,
                analyzed && analysis[0] == 1, !analyzed, analyzed && analysis[4] == 1
            ].enumerated() where isOn {
                flags |= 1 << bit
            }
            self.flags.append(flags)
            self.models += shape.modelScores?[index] ?? [0, 0, 0, 0]
            self.analysis += analyzed ? [UInt8(analysis[1]), UInt8(analysis[2]), UInt8(analysis[5]), UInt8(analysis[6])] : [0, 0, 4, 0]
            self.partsOfSpeech.append(analyzed ? UInt16(min(analysis[3], UInt32(Self.noPartOfSpeech - 1))) : Self.noPartOfSpeech)
            self.lexicon += shape.lexicon?[index] ?? [0, 0, 0, 0]
            if let context = shape.context?[index], context != ScriptTaggerFeatures.noContext {
                self.context += [UInt8(context[0]), UInt8(context[1]), UInt8(context[2]), UInt8(context[5]), UInt8(context[6]), UInt8(context[7]), UInt8(context[4]), 1]
                self.contextParts.append(UInt16(min(context[3], UInt32(Self.noPartOfSpeech - 1))))
            } else {
                self.context += Self.noContext
                self.contextParts.append(Self.noPartOfSpeech)
            }
            // Without the evidence, every key gets the unselected vectors, as the keys the first pass does not point at
            for values in [shape.before?[index], shape.after?[index]].map({ $0 ?? ScriptTaggerFeatures.unselectedEvidence }) {
                self.evidence += [UInt8(values[0]), UInt8(values[1]), UInt8(values[2]), UInt8(values[3]), UInt8(values[5])]
                self.evidenceParts.append(UInt16(min(values[4], UInt32(Self.noPartOfSpeech - 1))))
            }
        }
        self.words = shape.words
        self.isComplete = shape.isComplete
        self.hasContext = shape.context != nil
        self.hasEvidence = shape.before != nil && shape.after != nil
    }
}

/// The neural scorer: its weights, read from neural.bin (OGN1, the length of a JSON header that names each array's
/// offset and shape, then the float32 values), as the training writes them
struct NeuralScriptScorer: ScriptScorer {
    static let maxWordLength = 20
    /// The attributes of a word without the second pass's evidence, and those of the evidence (see `wordAttributes`)
    private static let baseAttributeCount = 57
    private static let evidenceAttributeCount = 44
    let hidden: Int
    /// The scores are to be added to the linear model's (tagger.bin): the network learned what that model misses
    let isOnLinearModel: Bool
    /// The network is a second pass: it reads the analyses on each side of the words the first pass finds likely (see
    /// `ScriptTaggerFeatures.evidence`)
    let isConditioned: Bool
    /// The network reads each key's context from the analyses around every position (see
    /// `ScriptTaggerFeatures.conditionedAnalyses`)
    let readsContext: Bool
    /// The inputs of a key without its context, and those of the context (see `keyInputs`)
    private static let baseInputCount = 51
    private static let contextInputCount = 21

    private var wordAttributeCount: Int {
        Self.baseAttributeCount + (self.isConditioned ? Self.evidenceAttributeCount : 0)
    }
    private let arrays: [String: [Float]]

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count > 8, data.prefix(4) == Data("OGN1".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let headerLength = Int(data.subdata(in: 4 ..< 8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        struct Header: Decodable {
            var hidden: Int
            var onLinear: Bool?
            var conditioned: Bool?
            var context: Bool?
            var arrays: [String: [AnyCodableNumber]]
        }
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 8 ..< 8 + headerLength))
        let values = data.subdata(in: 8 + headerLength ..< data.count).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var arrays: [String: [Float]] = [:]
        for (name, entry) in header.arrays {
            guard entry.count == 2, case .number(let offset) = entry[0], case .shape(let shape) = entry[1] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let count = shape.reduce(1, *)
            guard offset + count <= values.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            arrays[name] = Array(values[offset ..< offset + count])
        }
        self.hidden = header.hidden
        self.isOnLinearModel = header.onLinear ?? false
        self.isConditioned = header.conditioned ?? false
        self.readsContext = header.context ?? false
        self.arrays = arrays
    }

    /// A number or a list of numbers in the header
    private enum AnyCodableNumber: Decodable {
        case number(Int)
        case shape([Int])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                self = .number(number)
            } else {
                self = .shape(try container.decode([Int].self))
            }
        }
    }

    private func weights(_ name: String) -> [Float] {
        self.arrays[name] ?? []
    }

    /// y = W x + b for each row x of `inputs` (rows × columns), with W of out × columns as nn.Linear keeps it, by BLAS
    private func linear(_ inputs: [Float], rows: Int, _ name: String, bias: Bool = true) -> [Float] {
        let weight = self.weights(name + ".weight")
        let columns = inputs.count / max(rows, 1)
        let out = weight.count / max(columns, 1)
        var result = [Float](repeating: 0, count: rows * out)
        if bias {
            let values = self.weights(name + ".bias")
            for row in 0 ..< rows {
                result.replaceSubrange(row * out ..< (row + 1) * out, with: values)
            }
        }
        guard rows > 0, out > 0, columns > 0 else {
            return result
        }
        // result (rows × out) += inputs (rows × columns) · weightᵀ (columns × out)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(out), Int32(columns), 1, inputs, Int32(columns), weight, Int32(columns), 1, &result, Int32(out))
        return result
    }

    private static func sigmoid(_ value: Float) -> Float {
        1 / (1 + exp(-value))
    }

    /// The LSTM's states for each key, read forward or backward
    private func lstm(_ inputs: [Float], count: Int, _ name: String, reverse: Bool) -> [Float] {
        let size = self.hidden
        let gatesFromInputs = self.linear(inputs, rows: count, name + ".wx")
        let recurrent = self.weights(name + ".wh.weight")
        var h = [Float](repeating: 0, count: size)
        var c = [Float](repeating: 0, count: size)
        var gates = [Float](repeating: 0, count: 4 * size)
        var outputs = [Float](repeating: 0, count: count * size)
        for step in 0 ..< count {
            let t = reverse ? count - 1 - step : step
            gates.replaceSubrange(0 ..< 4 * size, with: gatesFromInputs[t * 4 * size ..< (t + 1) * 4 * size])
            // gates += recurrent (4·size × size) · h
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(4 * size), Int32(size), 1, recurrent, Int32(size), h, 1, 1, &gates, 1)
            for k in 0 ..< size {
                let input = Self.sigmoid(gates[k])
                let forget = Self.sigmoid(gates[size + k])
                let candidate = tanh(gates[2 * size + k])
                let output = Self.sigmoid(gates[3 * size + k])
                c[k] = forget * c[k] + input * candidate
                h[k] = output * tanh(c[k])
            }
            outputs.replaceSubrange(t * size ..< (t + 1) * size, with: h)
        }
        return outputs
    }

    /// For each key, what the LSTM reads: its letter, case, romaji state, the models' scores, the analysis, the lexicon
    private func keyInputs(_ inputs: NeuralInputs) -> [Float] {
        let count = inputs.characters.count
        let characters = self.weights("characters.weight")
        let cases = self.weights("cases.weight")
        let scripts = self.weights("scripts.weight")
        let partsOfSpeech = self.weights("parts_of_speech.weight")
        var result: [Float] = []
        result.reserveCapacity(count * (Self.baseInputCount + (self.readsContext ? Self.contextInputCount : 0)))
        for index in 0 ..< count {
            result += characters[Int(inputs.characters[index]) * 16 ..< (Int(inputs.characters[index]) + 1) * 16]
            result += cases[Int(inputs.cases[index]) * 4 ..< (Int(inputs.cases[index]) + 1) * 4]
            for bit in 0 ..< 8 {
                result.append(Float((inputs.flags[index] >> bit) & 1))
            }
            for model in 0 ..< 4 {
                result.append(Float(inputs.models[index * 4 + model]) / 4)
            }
            let analysis = inputs.analysis[index * 4 ..< index * 4 + 4].map(Float.init)
            result += [analysis[0] / 6, analysis[1] / 16, analysis[3] / 16]
            let script = Int(inputs.analysis[index * 4 + 2])
            result += scripts[script * 3 ..< (script + 1) * 3]
            let part = Int(inputs.partsOfSpeech[index])
            result += partsOfSpeech[part * 8 ..< (part + 1) * 8]
            let lexicon = inputs.lexicon[index * 4 ..< index * 4 + 4].map(Float.init)
            result += [lexicon[0] / 12, lexicon[1] / 12, lexicon[2], lexicon[3]]
            result.append(inputs.isComplete ? 1 : 0)
            if self.readsContext {
                // The context (see train.py's key_inputs): whether a word starts at the key, its length, value, script,
                // the total value, which side its analysis's position is on and how far, unknown, read, part of speech
                let context = inputs.context[index * 8 ..< index * 8 + 8].map(Float.init)
                let offset = Int(context[5])
                let side = offset < 12 ? 0 : offset < 24 ? 1 : 2
                result += [context[0], context[1] / 6, context[2] / 16]
                let script = Int(context[3])
                result += scripts[script * 3 ..< (script + 1) * 3]
                result.append(context[4] / 16)
                result += (0 ..< 3).map { $0 == side ? 1 : 0 }
                result.append(offset < 24 ? Float(offset % 12) / 12 : 0)
                result += [context[6], context[7]]
                let part = Int(inputs.contextParts[index])
                result += partsOfSpeech[part * 8 ..< (part + 1) * 8]
            }
        }
        return result
    }

    /// What is known about the keys from `start` of `length` as one word (see train.py's word_inputs)
    /// Counts before each key: capitals, words of the analysis starting, particles and auxiliaries starting
    private struct Sums {
        var capitals = [0]
        var starts = [0]
        var particles = [0]
    }

    private func wordAttributes(_ inputs: NeuralInputs, start: Int, length: Int, sums: Sums) -> [Float] {
        let count = inputs.characters.count
        let end = start + length
        let last = end - 1
        let atEnd = end >= count
        func bit(_ index: Int, _ number: Int) -> Float {
            Float((inputs.flags[index] >> number) & 1)
        }
        let value = inputs.words[start][length - 1]
        let known = Int(value >> 6)
        let inside = sums.starts[end] - sums.starts[start + 1]
        let firstStarts = bit(start, 5)
        let afterStarts: Float = atEnd ? 2 : bit(end, 5)
        let single: Float = firstStarts * (atEnd ? 1 : afterStarts == 1 ? 1 : 0) * (inside == 0 ? 1 : 0)
        var result = [Float](repeating: 0, count: self.wordAttributeCount)
        result[known] = 1
        result[3] = (Float(value & 63) - 32) / 8
        result[4 + min(length, 12) - 1] = 1
        result[16] = inputs.cases[start] == 1 ? 1 : 0
        result[17] = sums.capitals[end] - sums.capitals[start + 1] > 0 ? 1 : 0
        result[18] = sums.capitals[end] - sums.capitals[start] == length ? 1 : 0
        result[19] = bit(start, 0) * bit(last, 1)
        result[20] = start == 0 ? 1 : 0
        result[21] = atEnd ? 1 : 0
        result[22] = inputs.isComplete ? 1 : 0
        result[23] = bit(last, 2)
        result[24] = bit(last, 1)
        result[25] = firstStarts
        result[26 + Int(afterStarts)] = 1
        result[29] = atEnd ? 0 : bit(end, 7)
        result[30] = single
        result[31 + min(inside, 3)] = 1
        result[35] = sums.particles[end] - sums.particles[start + 1] > 0 ? 1 : 0
        result[36 + Int(inputs.analysis[start * 4 + 2])] = 1
        let partsOfSpeech = self.weights("parts_of_speech.weight")
        let first = Int(inputs.partsOfSpeech[start])
        let after = atEnd ? Int(NeuralInputs.noPartOfSpeech) : Int(inputs.partsOfSpeech[end])
        result.replaceSubrange(41 ..< 49, with: partsOfSpeech[first * 8 ..< (first + 1) * 8])
        result.replaceSubrange(49 ..< 57, with: partsOfSpeech[after * 8 ..< (after + 1) * 8])
        if self.isConditioned {
            // The evidence before the word and after it: its kind, the length of the word next to the boundary, whether
            // that word is unknown, its value, the total value, and its part of speech
            let hasEvidence = inputs.evidence.count == count * 10
            var offset = Self.baseAttributeCount
            for side in 0 ..< 2 {
                var values: [UInt8] = [0, 0, 0, 0, 0]
                var part = Int(NeuralInputs.noPartOfSpeech)
                if side == 0, hasEvidence {
                    values = Array(inputs.evidence[start * 10 ..< start * 10 + 5])
                    part = Int(inputs.evidenceParts[start * 2])
                } else if side == 1, atEnd {
                    values = [1, 0, 0, 0, 0]
                } else if hasEvidence {
                    values = Array(inputs.evidence[end * 10 + 5 ..< end * 10 + 10])
                    part = Int(inputs.evidenceParts[end * 2 + 1])
                }
                result[offset + min(Int(values[0]), 3)] = 1
                result[offset + 4 + min(Int(values[1]), 6)] = 1
                result[offset + 11] = Float(values[2])
                result[offset + 12] = Float(values[3]) / 16
                result[offset + 13] = Float(values[4]) / 16
                result.replaceSubrange(offset + 14 ..< offset + 22, with: partsOfSpeech[part * 8 ..< (part + 1) * 8])
                offset += 22
            }
        }
        return result
    }

    /// The scores of every way to read the input
    func lattice(keys: [Character], shape: ScriptTaggerFeatures.KeyShape) -> ScriptTaggerLattice {
        let inputs = NeuralInputs(keys: keys, shape: shape)
        let count = keys.count
        let size = self.hidden
        let x = self.keyInputs(inputs)
        let forward = self.lstm(x, count: count, "forward_lstm", reverse: false)
        let backward = self.lstm(x, count: count, "backward_lstm", reverse: true)
        var states = [Float]()
        states.reserveCapacity(count * 2 * size)
        for index in 0 ..< count {
            states += forward[index * size ..< (index + 1) * size]
            states += backward[index * size ..< (index + 1) * size]
        }
        let emissions = self.linear(states, rows: count, "emissions")
        let first = self.linear(states, rows: count, "word_first")
        let last = self.linear(states, rows: count, "word_last", bias: false)
        let next = self.linear(states, rows: count, "word_next", bias: false)
        let projection = first.count / max(count, 1)
        let attributeWeights = self.weights("word_attributes.weight")
        let outWeights = self.weights("word_out.weight")
        let outBias = self.weights("word_out.bias").first ?? 0
        let linearWeights = self.weights("word_linear.weight")
        var sums = Sums()
        for index in 0 ..< count {
            let starts = (inputs.flags[index] >> 5) & 1 == 1
            let part = inputs.partsOfSpeech[index]
            sums.capitals.append(sums.capitals[index] + (inputs.cases[index] == 1 ? 1 : 0))
            sums.starts.append(sums.starts[index] + (starts ? 1 : 0))
            sums.particles.append(sums.particles[index] + (starts && 147 ... 554 ~= part ? 1 : 0))
        }
        // Every word's attributes in one matrix, projected at once by BLAS
        var spans: [(start: Int, length: Int)] = []
        var attributes: [Float] = []
        for start in 0 ..< count {
            for length in stride(from: 1, through: min(inputs.words[start].count, Self.maxWordLength), by: 1) {
                spans.append((start, length))
                attributes += self.wordAttributes(inputs, start: start, length: length, sums: sums)
            }
        }
        var projected = [Float](repeating: 0, count: spans.count * projection)
        var linearScores = [Float](repeating: 0, count: spans.count)
        if !spans.isEmpty {
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(spans.count), Int32(projection), Int32(self.wordAttributeCount), 1, attributes, Int32(self.wordAttributeCount), attributeWeights, Int32(self.wordAttributeCount), 0, &projected, Int32(projection))
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(spans.count), Int32(self.wordAttributeCount), 1, attributes, Int32(self.wordAttributeCount), linearWeights, 1, 0, &linearScores, 1)
        }
        var words = keys.map { _ in [Double]() }
        for (index, span) in spans.enumerated() {
            let end = span.start + span.length
            var score = outBias + linearScores[index]
            for unit in 0 ..< projection {
                let value = projected[index * projection + unit] + first[span.start * projection + unit] + last[(end - 1) * projection + unit]
                    + (end < count ? next[end * projection + unit] : 0)
                score += outWeights[unit] * tanh(value)
            }
            words[span.start].append(Double(score))
        }
        return ScriptTaggerLattice(
            emissions: (0 ..< count).map { index in (0 ..< 3).map { Double(emissions[index * 3 + $0]) } },
            words: words,
            transitions: self.weights("transitions").map(Double.init),
            starts: self.weights("starts").map(Double.init)
        )
    }
}

/// The sum of scorers' lattices: the neural scorer on top of the linear model
struct CombinedScriptScorer: ScriptScorer {
    let scorers: [any ScriptScorer]
    /// How much of each scorer's scores goes in: 1 each adds a network's scores to the linear model's; 1/n each averages n
    /// networks, which keeps the decoding costs as they were chosen for one
    let weights: [Double]

    init(scorers: [any ScriptScorer], weights: [Double]? = nil) {
        self.scorers = scorers
        self.weights = weights ?? scorers.map { _ in 1 }
    }

    func lattice(keys: [Character], shape: ScriptTaggerFeatures.KeyShape) -> ScriptTaggerLattice {
        let lattices = self.scorers.map { $0.lattice(keys: keys, shape: shape) }
        func sum(_ arrays: [[Double]]) -> [Double] {
            var result = [Double](repeating: 0, count: arrays[0].count)
            for (array, weight) in zip(arrays, self.weights) {
                for index in array.indices {
                    result[index] += weight * array[index]
                }
            }
            return result
        }
        return ScriptTaggerLattice(
            emissions: keys.indices.map { key in sum(lattices.map { $0.emissions[key] }) },
            words: keys.indices.map { start in sum(lattices.map { $0.words[start] }) },
            transitions: sum(lattices.map(\.transitions)),
            starts: sum(lattices.map(\.starts))
        )
    }
}
