struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    //TODO: information passed from vertex shader to fragment shader
    @location(0) center: vec2<f32>,
    @location(1) color: vec3<f32>,
    @location(2) opacity: f32,
    @location(3) conic: vec3<f32>,
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
    pos: u32,
    rg: u32,
    b_opacity: u32,
    conic_xy: u32,
    conic_z: u32,
    radius: u32,
};

@group(0) @binding(0)
var<uniform> camera: CameraUniforms;

@group(1) @binding(0)
var<storage, read> splats : array<Splat>;
@group(1) @binding(1)
var<storage, read> sort_indices : array<u32>;

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    //TODO: reconstruct 2D quad based on information from splat, pass 
    var out: VertexOutput;

    let v_idx = input.vertex_index;
    let inst_idx = input.instance_index;
    let curr_splat = splats[sort_indices[inst_idx]];

    let pos = unpack2x16float(curr_splat.pos);
    let rg = unpack2x16float(curr_splat.rg);
    let b_opacity = unpack2x16float(curr_splat.b_opacity);
    let conic_xy = unpack2x16float(curr_splat.conic_xy);
    let conic_z = unpack2x16float(curr_splat.conic_z);
    let radius = unpack2x16float(curr_splat.radius);

    let tri_verts = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, 1.0), vec2<f32>(-1.0, -1.0),
        vec2<f32>(1.0, -1.0), vec2<f32>(1.0, -1.0),
        vec2<f32>(1.0, 1.0), vec2<f32>(-1.0, 1.0));
    let curr_tri_vert = tri_verts[v_idx];

    out.position = vec4f(pos + radius * curr_tri_vert, 0.0, 1.0);
    out.center = (pos * vec2f(0.5, -0.5) + 0.5);
    out.color = vec3<f32>(rg.xy, b_opacity.x);

    out.opacity = b_opacity.y;
    out.conic = vec3<f32>(conic_xy.xy, conic_z.x);

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let color = in.color;
    let conic = in.conic;
    let opacity = in.opacity;
    let pos = (in.center * camera.viewport) - in.position.xy;
    
    let exp_q = (conic.x * pos.x * pos.x) + (2.0 * conic.y * pos.x * pos.y) + (conic.z * pos.y * pos.y);
    let alpha = clamp(exp(exp_q / -2.0), 0.0, 0.99);

    return vec4<f32>(color, 1.0) * opacity * alpha;
}