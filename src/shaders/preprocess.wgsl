const SH_C0: f32 = 0.28209479177387814;
const SH_C1 = 0.4886025119029199;
const SH_C2 = array<f32,5>(
    1.0925484305920792,
    -1.0925484305920792,
    0.31539156525252005,
    -1.0925484305920792,
    0.5462742152960396
);
const SH_C3 = array<f32,7>(
    -0.5900435899266435,
    2.890611442640554,
    -0.4570457994644658,
    0.3731763325901154,
    -0.4570457994644658,
    1.445305721320277,
    -0.5900435899266435
);

override workgroupSize: u32;
override sortKeyPerThread: u32;

struct DispatchIndirect {
    dispatch_x: atomic<u32>,
    dispatch_y: u32,
    dispatch_z: u32,
}

struct SortInfos {
    keys_size: atomic<u32>,  // instance_count in DrawIndirect
    //data below is for info inside radix sort 
    padded_size: u32, 
    passes: u32,
    even_pass: u32,
    odd_pass: u32,
}

struct CameraUniforms {
    view: mat4x4<f32>,
    view_inv: mat4x4<f32>,
    proj: mat4x4<f32>,
    proj_inv: mat4x4<f32>,
    viewport: vec2<f32>,
    focal: vec2<f32>
};

struct RenderSettings {
    gaussian_mult: f32,
    sh_deg: f32,
}

struct Gaussian {
    pos_opacity: array<u32,2>,
    rot: array<u32,2>,
    scale: array<u32,2>
};

struct Splat {
    //TODO: store information for 2D splat rendering
    pos: u32,
    rg: u32,
    b_opacity: u32,
    conic_xy: u32,
    conic_z: u32,
    radius: u32,
};

//TODO: bind your data here
@group(0) @binding(0)
var<uniform> camera: CameraUniforms;
@group(0) @binding(1)
var<uniform> settings : RenderSettings;

@group(1) @binding(0)
var<storage, read_write> sh_coefficients: array<u32>;
@group(1) @binding(1)
var<storage, read_write> gaussians : array<Gaussian>;
@group(1) @binding(2)
var<storage, read_write> splats : array<Splat>;

@group(2) @binding(0)
var<storage, read_write> sort_infos: SortInfos;
@group(2) @binding(1)
var<storage, read_write> sort_depths : array<u32>;
@group(2) @binding(2)
var<storage, read_write> sort_indices : array<u32>;
@group(2) @binding(3)
var<storage, read_write> sort_dispatch: DispatchIndirect;

/// reads the ith sh coef from the storage buffer 
fn sh_coef(splat_idx: u32, c_idx: u32) -> vec3<f32> {
    //TODO: access your binded sh_coeff, see load.ts for how it is stored
    let max_num_coefs = 16u; // from load.ts
    let sh_color_idx = ((splat_idx * max_num_coefs * 3u) + (c_idx * 3u));
    let coeff_idx = sh_color_idx / 2u;
    let coeff0 = unpack2x16float(sh_coefficients[coeff_idx]);
    let coeff1 = unpack2x16float(sh_coefficients[coeff_idx + 1u]);

    if (sh_color_idx % 2 == 0) {
        return vec3<f32>(coeff0.x, coeff0.y, coeff1.x);
    }
    else {
        return vec3<f32>(coeff0.y, coeff1.x, coeff1.y);
    }
}

// spherical harmonics evaluation with Condon–Shortley phase
fn computeColorFromSH(dir: vec3<f32>, v_idx: u32, sh_deg: u32) -> vec3<f32> {
    var result = SH_C0 * sh_coef(v_idx, 0u);

    if sh_deg > 0u {

        let x = dir.x;
        let y = dir.y;
        let z = dir.z;

        result += - SH_C1 * y * sh_coef(v_idx, 1u) + SH_C1 * z * sh_coef(v_idx, 2u) - SH_C1 * x * sh_coef(v_idx, 3u);

        if sh_deg > 1u {

            let xx = dir.x * dir.x;
            let yy = dir.y * dir.y;
            let zz = dir.z * dir.z;
            let xy = dir.x * dir.y;
            let yz = dir.y * dir.z;
            let xz = dir.x * dir.z;

            result += SH_C2[0] * xy * sh_coef(v_idx, 4u) + SH_C2[1] * yz * sh_coef(v_idx, 5u) + SH_C2[2] * (2.0 * zz - xx - yy) * sh_coef(v_idx, 6u) + SH_C2[3] * xz * sh_coef(v_idx, 7u) + SH_C2[4] * (xx - yy) * sh_coef(v_idx, 8u);

            if sh_deg > 2u {
                result += SH_C3[0] * y * (3.0 * xx - yy) * sh_coef(v_idx, 9u) + SH_C3[1] * xy * z * sh_coef(v_idx, 10u) + SH_C3[2] * y * (4.0 * zz - xx - yy) * sh_coef(v_idx, 11u) + SH_C3[3] * z * (2.0 * zz - 3.0 * xx - 3.0 * yy) * sh_coef(v_idx, 12u) + SH_C3[4] * x * (4.0 * zz - xx - yy) * sh_coef(v_idx, 13u) + SH_C3[5] * z * (xx - yy) * sh_coef(v_idx, 14u) + SH_C3[6] * x * (xx - 3.0 * yy) * sh_coef(v_idx, 15u);
            }
        }
    }
    result += 0.5;

    return  max(vec3<f32>(0.), result);
}

// code adapted from graphdeco-inria/diff-gaussian-rasterization repo
fn covariance3D(gaussian: Gaussian, gs_multiplier: f32) -> array<f32, 6> {
    let rot_0 = unpack2x16float(gaussian.rot[0]);
    let rot_1 = unpack2x16float(gaussian.rot[1]);
    let quat = vec4<f32>(rot_0.x, rot_0.y, rot_1.x, rot_1.y);
    let x = quat.y;
    let y = quat.z;
    let z = quat.w;
    let r = quat.x;

    let R = mat3x3<f32>(
        vec3<f32>(1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - r * z), 2.0 * (x * z + r * y)),
        vec3<f32>(2.0 * (x * y + r * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - r * x)),
        vec3<f32>(2.0 * (x * z - r * y), 2.0 * (y * z + r * x), 1.0 - 2.0 * (x * x + y * y)));

    let scale_0 = unpack2x16float(gaussian.scale[0]);
    let scale_1 = unpack2x16float(gaussian.scale[1]);
    let scale = exp(vec3<f32>(scale_0.x, scale_0.y, scale_1.x)) * gs_multiplier;

    let S = mat3x3<f32>(
        vec3<f32>(scale.x, 0.0, 0.0),
        vec3<f32>(0.0, scale.y, 0.0),
        vec3<f32>(0.0, 0.0, scale.z)
    );

    // let cov_mat = R * S * transpose(S) * transpose(R);
    let M = S * R;
    let cov_mat = transpose(M) * M;

    let flat_mat = array<f32, 6>(cov_mat[0][0], cov_mat[0][1], cov_mat[0][2], cov_mat[1][1], cov_mat[1][2], cov_mat[2][2]);
    return flat_mat;

}

// code adapted from graphdeco-inria/diff-gaussian-rasterization repo
fn covariance2D(cov_3D: array<f32, 6>, mean_view: vec4<f32>, focal: vec2<f32>) -> vec3<f32> {
    var t = mean_view.xyz;
    let focal_x = camera.focal.x;
    let focal_y = camera.focal.y;
    let viewmatrix = camera.view;

    let fovx = camera.viewport.x * 0.5 / focal_x;
    let fovy = camera.viewport.y * 0.5 / focal_y;
    let limx = 1.3 * fovx;
    let limy = 1.3 * fovy;
    let txtz = t.x / t.z;
    let tytz = t.y / t.z;
    t.x = min(limx, max(-limx, txtz)) * t.z;
	t.y = min(limy, max(-limy, tytz)) * t.z;

	let J = mat3x3<f32>(
		vec3<f32>(focal_x / t.z, 0.0, -(focal_x * t.x) / (t.z * t.z)),
		vec3<f32>(0.0, focal_y / t.z, -(focal_y * t.y) / (t.z * t.z)),
		vec3<f32>(0.0, 0.0, 0.0));

	let W = mat3x3<f32>(
		viewmatrix[0].x, viewmatrix[1].x, viewmatrix[2].x,
		viewmatrix[0].y, viewmatrix[1].y, viewmatrix[2].y,
		viewmatrix[0].z, viewmatrix[1].z, viewmatrix[2].z);

	let T = W * J;

	let Vrk = mat3x3<f32>(
		cov_3D[0], cov_3D[1], cov_3D[2],
		cov_3D[1], cov_3D[3], cov_3D[4],
		cov_3D[2], cov_3D[4], cov_3D[5]);

	var cov = transpose(T) * transpose(Vrk) * T;

    // numerical stability
	cov[0][0] = cov[0][0] + 0.3;
	cov[1][1] = cov[1][1] + 0.3;
	return vec3<f32>(cov[0][0], cov[0][1], cov[1][1]);

}

@compute @workgroup_size(workgroupSize,1,1)
fn preprocess(@builtin(global_invocation_id) gid: vec3<u32>, @builtin(num_workgroups) wgs: vec3<u32>) {
    let idx = gid.x;
    //TODO: set up pipeline as described in instruction
    if (idx >= arrayLength(&gaussians)) {
        return;
    }

    let gauss = gaussians[idx];
    let gs_mult = settings.gaussian_mult;
    let sh_deg_val = u32(settings.sh_deg);

    let gauss_xy = unpack2x16float(gauss.pos_opacity[0]);
    let gauss_z = unpack2x16float(gauss.pos_opacity[1]);
    let gauss_pos = vec4<f32>(gauss_xy.x, gauss_xy.y, gauss_z.x, 1.0);
    let world_to_view = camera.view * gauss_pos;
    let view_to_clip = camera.proj * world_to_view;
    let gauss_ndc = view_to_clip.xyz / view_to_clip.w;
    let near_plane = 0.01;
    let far_plane = 100.0;
    let gauss_depth = far_plane - world_to_view.z;

    let gauss_opacity = gauss_z.y;
    let opacity_sigmoid = 1.0 / (1.0 + exp(-gauss_opacity));


    // cull with 1.2x bounding box 
    if (gauss_ndc.x < -1.2 || gauss_ndc.x > 1.2 || gauss_ndc.y < -1.2 || gauss_ndc.y > 1.2 || world_to_view.z < near_plane || world_to_view.z > far_plane) {
        return;
    }

    // covariance and radius (code adapted from graphdeco-inria/diff-gaussian-rasterization repo)
    let cov_3d = covariance3D(gauss, gs_mult);
    let cov_2d = covariance2D(cov_3d, world_to_view, camera.focal);
    let det = (cov_2d.x * cov_2d.z - cov_2d.y * cov_2d.y);
    if (det == 0) {
        return; // avoid divide by 0
    }
    let det_inv = 1.0 / det;
    let conic_inv = vec3<f32>(cov_2d.z * det_inv, -cov_2d.y * det_inv, cov_2d.x * det_inv);
    let mid = 0.5 * (cov_2d.x + cov_2d.z);
    let lambda1 = mid + sqrt(max(0.1, mid * mid - det));
    let lambda2 = mid - sqrt(max(0.1, mid * mid - det));
    let gauss_radius = ceil(3.0 * sqrt(max(lambda1, lambda2))) * 2.0 / camera.viewport;

    // get color
    let color_dir = normalize(gauss_pos.xyz - camera.view_inv[3].xyz);
    let color_vec = computeColorFromSH(color_dir, idx, sh_deg_val);

    // sort depth
    let sort_key_idx = atomicAdd(&sort_infos.keys_size, 1u);
    sort_depths[sort_key_idx] = bitcast<u32>(gauss_depth);
    sort_indices[sort_key_idx] = sort_key_idx;

    let keys_per_dispatch = workgroupSize * sortKeyPerThread; 
    // increment DispatchIndirect.dispatchx each time you reach limit for one dispatch of keys
    if (sort_key_idx % keys_per_dispatch == 0) {
        atomicAdd(&sort_dispatch.dispatch_x, 1u);
    }

    // put info into splats
    splats[sort_key_idx].pos = pack2x16float(gauss_ndc.xy);
    splats[sort_key_idx].conic_xy = pack2x16float(conic_inv.xy);
    splats[sort_key_idx].conic_z = pack2x16float(vec2(conic_inv.z, 0.0));
    splats[sort_key_idx].radius = pack2x16float(gauss_radius);
    splats[sort_key_idx].rg = pack2x16float(color_vec.rg);
    splats[sort_key_idx].b_opacity = pack2x16float(vec2(color_vec.b, opacity_sigmoid));
}