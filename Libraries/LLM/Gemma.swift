// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXFast
import MLXNN

// port of https://github.com/ml-explore/mlx-examples/blob/main/llms/mlx_lm/models/gemma.py

// specialized norm for gemma
private class RMSNorm: Module, UnaryLayer {
    let weight: MLXArray
    let eps: Float

    public init(dimensions: Int, eps: Float = 1e-5) {
        self.weight = MLXArray.ones([dimensions])
        self.eps = eps
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        return MLXFast.rmsNorm(x, weight: 1.0 + self.weight, eps: self.eps)
    }
}

private class Attention: Module {

    let args: GemmaConfiguration
    let scale: Float

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear

    let rope: RoPE

    public init(_ args: GemmaConfiguration) {
        self.args = args

        let dim = args.hiddenSize
        let heads = args.attentionHeads
        let kvHeads = args.kvHeads

        let headDim = args.headDimensions
        self.scale = pow(Float(headDim), -0.5)

        self._wq.wrappedValue = Linear(dim, heads * headDim, bias: false)
        self._wk.wrappedValue = Linear(dim, kvHeads * headDim, bias: false)
        self._wv.wrappedValue = Linear(dim, kvHeads * headDim, bias: false)
        self._wo.wrappedValue = Linear(heads * headDim, dim, bias: false)

        self.rope = RoPE(
            dimensions: headDim, traditional: args.ropeTraditional, base: args.ropeTheta)
    }

    public func callAsFunction(
        _ x: MLXArray, mask: MLXArray? = nil, cache: KVCache?
    ) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))

        var queries = wq(x)
        var keys = wk(x)
        var values = wv(x)

        // prepare the queries, keys and values for the attention computation
        queries = queries.reshaped(B, L, args.attentionHeads, -1).transposed(0, 2, 1, 3)
        keys = keys.reshaped(B, L, args.kvHeads, -1).transposed(0, 2, 1, 3)
        values = values.reshaped(B, L, args.kvHeads, -1).transposed(0, 2, 1, 3)

        if let cache {
            queries = rope(queries, offset: cache.offset)
            keys = rope(keys, offset: cache.offset)
            (keys, values) = cache.update(keys: keys, values: values)
        } else {
            queries = rope(queries)
            keys = rope(keys)
        }

        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: scale, mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return wo(output)
    }
}

private class MLP: Module, UnaryLayer {

    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    public init(dimensions: Int, hiddenDimensions: Int) {
        self._gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        self._down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        self._up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(gelu(gate(x)) * up(x))
    }
}

private class TransformerBlock: Module {

    @ModuleInfo(key: "self_attn") var attention: Attention
    let mlp: MLP

    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    public init(_ args: GemmaConfiguration) {
        self._attention.wrappedValue = Attention(args)
        self.mlp = MLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
        self._inputLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize, eps: args.rmsNormEps)
        self._postAttentionLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    public func callAsFunction(
        _ x: MLXArray, mask: MLXArray? = nil, cache: KVCache?
    ) -> MLXArray {
        var r = attention(inputLayerNorm(x), mask: mask, cache: cache)
        let h = x + r
        r = mlp(postAttentionLayerNorm(h))
        let out = h + r
        return out
    }
}

public class GemmaModelInner: Module {

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding

    fileprivate let layers: [TransformerBlock]
    fileprivate let norm: RMSNorm

    let hiddenScale: Float

    public init(_ args: GemmaConfiguration) {
        precondition(args.vocabularySize > 0)

        self._embedTokens.wrappedValue = Embedding(
            embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)

        self.hiddenScale = pow(Float(args.hiddenSize), 0.5)

        self.layers = (0 ..< args.hiddenLayers)
            .map { _ in
                TransformerBlock(args)
            }
        self.norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]? = nil) -> MLXArray {
        var h = embedTokens(inputs)
        h = h * hiddenScale

        let mask: MLXArray? = createAttentionMask(h: h, cache: cache)

        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[i])
        }

        return norm(h)
    }
}

public class GemmaModel: Module, LLMModel, KVCacheDimensionProvider, @unchecked Sendable {

    public let vocabularySize: Int
    public let kvHeads: [Int]
    public let headDim: IntOrPair

    let model: GemmaModelInner

    public init(_ args: GemmaConfiguration) {
        self.vocabularySize = args.vocabularySize
        self.kvHeads = (0 ..< args.hiddenLayers).map { _ in args.kvHeads }
        self.headDim = .init(args.headDimensions)
        self.model = GemmaModelInner(args)
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        var out = model(inputs, cache: cache)
        out = matmul(out, model.embedTokens.weight.T)
        return out
    }
}

public struct GemmaConfiguration: Codable, Sendable {

    var hiddenSize: Int
    var hiddenLayers: Int
    var intermediateSize: Int
    var attentionHeads: Int
    var headDimensions: Int
    var rmsNormEps: Float
    var vocabularySize: Int
    var kvHeads: Int
    var ropeTheta: Float = 10_000
    var ropeTraditional: Bool = false

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case headDimensions = "head_dim"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case kvHeads = "num_key_value_heads"
        case ropeTheta = "rope_theta"
        case ropeTraditional = "rope_traditional"
    }

    public init(from decoder: Decoder) throws {
        // custom implementation to handle optional keys with required values
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(
            keyedBy: CodingKeys.self)

        self.hiddenSize = try container.decode(
            Int.self, forKey: CodingKeys.hiddenSize)
        self.hiddenLayers = try container.decode(
            Int.self, forKey: CodingKeys.hiddenLayers)
        self.intermediateSize = try container.decode(
            Int.self, forKey: CodingKeys.intermediateSize)
        self.attentionHeads = try container.decode(
            Int.self, forKey: CodingKeys.attentionHeads)
        self.headDimensions = try container.decode(
            Int.self, forKey: CodingKeys.headDimensions)
        self.rmsNormEps = try container.decode(
            Float.self, forKey: CodingKeys.rmsNormEps)
        self.vocabularySize = try container.decode(
            Int.self, forKey: CodingKeys.vocabularySize)
        self.kvHeads = try container.decode(Int.self, forKey: CodingKeys.kvHeads)
        self.ropeTheta =
            try container.decodeIfPresent(Float.self, forKey: CodingKeys.ropeTheta)
            ?? 10_000
        self.ropeTraditional =
            try container.decodeIfPresent(
                Bool.self, forKey: CodingKeys.ropeTraditional) ?? false
    }
}

// MARK: - LoRA

extension GemmaModel: LoRAModel {
    public func loraLinearLayers() -> LoRALinearLayers {
        model.layers.map { ($0.attention, ["q_proj", "v_proj"]) }
    }
}
