struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    //TODO: information passed from vertex shader to fragment shader
    @location(0) opacity: f32,
};

struct VertexInput {
    @builtin(vertex_index) vertex_index: u32,
    @builtin(instance_index) instance_index: u32
}

struct CameraUniforms {
    view: mat4x4<f32>,
    view_inv: mat4x4<f32>,
    proj: mat4x4<f32>,
    proj_inv: mat4x4<f32>,
    viewport: vec2<f32>,
    focal: vec2<f32>
};

struct Splat {
    //TODO: information defined in preprocess compute shader
    pos: vec3<f32>,
    opacity: f32,
};

@group(0) @binding(0)
var<uniform> camera: CameraUniforms;

@group(1) @binding(0)
var<storage, read_write> splats : array<Splat>;
@group(1) @binding(1)
var<storage, read_write> sort_indices : array<u32>;

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    //TODO: reconstruct 2D quad based on information from splat, pass 
    var out: VertexOutput;

    // dummy reads
    let _test_focal = camera.focal.x;
    let test_pos = splats[0].pos.x;
    let test_sort = sort_indices[0];

    out.position = vec4<f32>(1., 1., 0, 1.);

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return vec4<f32>(1.0, 1.0, 1.0, in.opacity);
    // return vec4<f32>(1.);
}