import { PointCloud } from '../utils/load';
import preprocessWGSL from '../shaders/preprocess.wgsl';
import renderWGSL from '../shaders/gaussian.wgsl';
import { get_sorter,c_histogram_block_rows,C } from '../sort/sort';
import { Renderer } from './renderer';

export interface GaussianRenderer extends Renderer {
  settings_buffer: GPUBuffer;
}

// Utility to create GPU buffers
const createBuffer = (
  device: GPUDevice,
  label: string,
  size: number,
  usage: GPUBufferUsageFlags,
  data?: ArrayBuffer | ArrayBufferView
) => {
  const buffer = device.createBuffer({ label, size, usage });
  if (data) device.queue.writeBuffer(buffer, 0, data);
  return buffer;
};

export default function get_renderer(
  pc: PointCloud,
  device: GPUDevice,
  presentation_format: GPUTextureFormat,
  camera_buffer: GPUBuffer,
): GaussianRenderer {

  const sorter = get_sorter(pc.num_points, device);
  
  // ===============================================
  //            Initialize GPU Buffers
  // ===============================================

  const nulling_data = new Uint32Array([0]);
  const indirect_data = new Uint32Array([6, 0, 0, 0]);
  const settings_data = new Float32Array([1.0, pc.sh_deg]);
  const splat_buffer_size = pc.num_points * (4 * 6); // 5 u32, size 4

  const nulling_buffer = createBuffer(
    device, "nulling buffer", 4, GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST, nulling_data);

  const indirect_render_buffer = createBuffer(
    device, "indirect render buffer", 4 * 4, GPUBufferUsage.INDIRECT | GPUBufferUsage.COPY_DST, indirect_data);

  const splat_buffer = createBuffer(
    device, "splat buffer", splat_buffer_size, GPUBufferUsage.STORAGE);

  const settings_buffer = createBuffer(
    device, "settings buffer", 4 * 2, GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST, settings_data);

  // ===============================================
  //    Create Compute Pipeline and Bind Groups
  // ===============================================
  const preprocess_pipeline = device.createComputePipeline({
    label: 'preprocess',
    layout: 'auto',
    compute: {
      module: device.createShaderModule({ code: preprocessWGSL }),
      entryPoint: 'preprocess',
      constants: {
        workgroupSize: C.histogram_wg_size,
        sortKeyPerThread: c_histogram_block_rows,
      },
    },
  });

  const uniform_bind_group = device.createBindGroup({
    label: 'uniform',
    layout: preprocess_pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: camera_buffer } },
      { binding: 1, resource: { buffer: settings_buffer } },
    ],
  });

  const gaussian_bind_group = device.createBindGroup({
    label: 'gaussian',
    layout: preprocess_pipeline.getBindGroupLayout(1),
    entries: [
      { binding: 0, resource: { buffer: pc.sh_buffer } },
      { binding: 1, resource: { buffer: pc.gaussian_3d_buffer } },
      { binding: 2, resource: { buffer: splat_buffer } },
    ],
  });

  const sort_bind_group = device.createBindGroup({
    label: 'sort',
    layout: preprocess_pipeline.getBindGroupLayout(2),
    entries: [
      { binding: 0, resource: { buffer: sorter.sort_info_buffer } },
      { binding: 1, resource: { buffer: sorter.ping_pong[0].sort_depths_buffer } },
      { binding: 2, resource: { buffer: sorter.ping_pong[0].sort_indices_buffer } },
      { binding: 3, resource: { buffer: sorter.sort_dispatch_indirect_buffer } },
    ],
  });


  // ===============================================
  //    Create Render Pipeline and Bind Groups
  // ===============================================
  const render_shader = device.createShaderModule({code: renderWGSL});
  const render_pipeline = device.createRenderPipeline({
    label: 'render',
    layout: 'auto',
    vertex: {
      module: render_shader,
      entryPoint: 'vs_main',
    },
    fragment: {
      module: render_shader,
      entryPoint: 'fs_main',
      targets: [{
        format: presentation_format,
        blend: {
            color: {
              srcFactor: 'one',
              dstFactor: 'one-minus-src-alpha',
              operation: 'add',
            },
            alpha: {
              srcFactor: 'one',
              dstFactor: 'one-minus-src-alpha',
              operation: 'add',
            },
        },
      }],
    },
    primitive: {
      topology: 'triangle-list',
    },
  });

  const camera_bind_group = device.createBindGroup({
    label: 'gaussian render camera',
    layout: render_pipeline.getBindGroupLayout(0),
    entries: [{binding: 0, resource: { buffer: camera_buffer }}],
  });

  const gaussian_render_bind_group = device.createBindGroup({
    label: 'gaussian render gaussians',
    layout: render_pipeline.getBindGroupLayout(1),
    entries: [
      {binding: 0, resource: { buffer: splat_buffer }},
      {binding: 1, resource: { buffer: sorter.ping_pong[0].sort_indices_buffer }}
    ],
  });

  // ===============================================
  //    Command Encoder Functions
  // ===============================================
  
  const preprocess = (encoder: GPUCommandEncoder) => {
    encoder.copyBufferToBuffer(nulling_buffer, 0, sorter.sort_info_buffer, 0, 4);
    encoder.copyBufferToBuffer(nulling_buffer, 0, sorter.sort_dispatch_indirect_buffer, 0, 4);
    const pass = encoder.beginComputePass({
      label: 'gaussian preprocess',
    });
    pass.setPipeline(preprocess_pipeline);
    pass.setBindGroup(0, uniform_bind_group);
    pass.setBindGroup(1, gaussian_bind_group);
    pass.setBindGroup(2, sort_bind_group);
    pass.dispatchWorkgroups(Math.ceil(pc.num_points / C.histogram_wg_size));

    pass.end();
  };

  const render = (encoder: GPUCommandEncoder, texture_view: GPUTextureView) => {
    encoder.copyBufferToBuffer(sorter.sort_info_buffer, 0, indirect_render_buffer, 4, 4);
    const pass = encoder.beginRenderPass({
      label: 'gaussian render',
      colorAttachments: [
        {
          view: texture_view,
          loadOp: 'clear',
          storeOp: 'store',
        }
      ],
    });
    pass.setPipeline(render_pipeline);
    pass.setBindGroup(0, camera_bind_group);
    pass.setBindGroup(1, gaussian_render_bind_group);
    pass.drawIndirect(indirect_render_buffer, 0);

    pass.end();
  };

  // ===============================================
  //    Return Render Object
  // ===============================================
  return {
    frame: (encoder: GPUCommandEncoder, texture_view: GPUTextureView) => {
      preprocess(encoder);
      sorter.sort(encoder);
      render(encoder, texture_view);
    },
    camera_buffer,
    settings_buffer,
  };
}
