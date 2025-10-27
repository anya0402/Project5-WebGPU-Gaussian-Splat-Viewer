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
    conic_z_radius: u32,
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
    let conic_z_radius = unpack2x16float(curr_splat.conic_z_radius);

    let tri_verts = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, 1.0), vec2<f32>(-1.0, -1.0),
        vec2<f32>(1.0, -1.0), vec2<f32>(1.0, -1.0),
        vec2<f32>(1.0, 1.0), vec2<f32>(-1.0, 1.0));
    let curr_tri_vert = tri_verts[v_idx];

    let radius = conic_z_radius.y;
    let diameter = vec2<f32>(radius / camera.viewport) * 2.0; // ** why is radius vec2
    let offset = curr_tri_vert * diameter;

    out.position = vec4<f32>(pos.x + offset.x, pos.y + offset.y, 0.0, 1.0);
    out.center = vec2<f32>(pos.x, pos.y);
    out.color = vec3<f32>(rg.xy, b_opacity.x);
    // let gauss_ratio = f32(b_opacity.y);
    // out.color = vec3<f32>(0.0, gauss_ratio, 0.0);

    out.opacity = b_opacity.y;
    out.conic = vec3<f32>(conic_xy.xy, conic_z_radius.x);

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {

    // let pos = in.position;
    // let depth_ratio = in.color.y;
    // let clamped = clamp(depth_ratio, 0.0, 1.0);
    // let color_mixed = mix(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 0.0, 0.0), clamped);
    // return vec4<f32>(color_mixed, 1.0);

    // --------------------------------------------------

    // var pos_ndc = 2.0 * (in.position.xy / camera.viewport) - vec2(1.0, 1.0);
    // pos_ndc.y = -pos_ndc.y;

    // var offset_screen = pos_ndc - in.center;
    // offset_screen.x = -offset_screen.x;
    // offset_screen *= camera.viewport * 0.5;

    // var exponent = 
    //     in.conic.x * offset_screen.x * offset_screen.x
    //     + in.conic.z * offset_screen.y * offset_screen.y
    //     + in.conic.y * offset_screen.x * offset_screen.y;

    // let color = in.color;
    // let opacity = in.opacity;

    // return vec4<f32>(color, 1.0) * opacity * exp(-exponent/2.0);

    // --------------------------------------------------

    let color = in.color;
    let conic = in.conic;
    let opacity = in.opacity;
    var pos = 2.0 * (in.position.xy / camera.viewport) - vec2(1.0, 1.0);
    pos.y = -pos.y;
    pos = pos - in.center;
    pos.x = -pos.x;
    pos = pos * camera.viewport * 0.5;
    
    let exp_q = (conic.x * pos.x * pos.x) + (conic.y * pos.x * pos.y) + (conic.z * pos.y * pos.y);
    let alpha = clamp(exp(exp_q / -2.0), 0.0, 0.99);

    return vec4<f32>(color, 1.0) * opacity * alpha;

    // --------------------------------------------------

    // let color = in.color;
    // let conic = in.conic;
    // let pos = (in.position.xy / in.position.w) - in.center;
    
    // let exp_q = (conic.x * pos.x * pos.x) + (conic.y * pos.x * pos.y) + (conic.z * pos.y * pos.y);
    // let alpha = clamp(exp(exp_q / -2.0), 0.0, 0.99);

    // return vec4<f32>(color * alpha, alpha);
}