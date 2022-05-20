struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) texCoords: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) texCoords: vec2<f32>,
};

@group(0) @binding(0)
var t_t: texture_2d<f32>;

@group(0) @binding(1)
var s_t: sampler;

@stage(vertex)
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    out.clip_position = vec4<f32>(in.position, 1.0);
    out.texCoords = in.texCoords;

    return out;
}

@stage(fragment)
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return textureSample(t_t, s_t, in.texCoords);
}