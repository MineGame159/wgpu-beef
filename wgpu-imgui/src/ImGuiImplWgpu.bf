using System;
using System.Diagnostics;

using ImGui;
using Wgpu;

// dear imgui: Renderer for WebGPU
// This needs to be used along with a Platform Binding (e.g. GLFW)
// (Please note that WebGPU is currently experimental, will not run on non-beta browsers, and may break.)

// Implemented features:
//  [X] Renderer: User texture binding. Use 'WGPUTextureView' as ImTextureID. Read the FAQ about ImTextureID!
//  [X] Renderer: Support for large meshes (64k+ vertices) with 16-bit indices.

// You can use unmodified imgui_impl_* files in your project. See examples/ folder for examples of using this.
// Prefer including the entire imgui/ repository into your project (either as a copy or as a submodule), and only build the backends you need.
// If you are new to Dear ImGui, read documentation from the docs/ folder + read the top of imgui.cpp.
// Read online: https://github.com/ocornut/imgui/tree/master/docs

// CHANGELOG
// (minor and older changes stripped away, please see git history for details)
//  2021-11-29: Passing explicit buffer sizes to wgpuRenderPassEncoderSetVertexBuffer()/wgpuRenderPassEncoderSetIndexBuffer().
//  2021-08-24: Fix for latest specs.
//  2021-05-24: Add support for draw_data->FramebufferScale.
//  2021-05-19: Replaced direct access to ImDrawCmd::TextureId with a call to ImDrawCmd::GetTexID(). (will become a requirement)
//  2021-05-16: Update to latest WebGPU specs (compatible with Emscripten 2.0.20 and Chrome Canary 92).
//  2021-02-18: Change blending equation to preserve alpha in output buffer.
//  2021-01-28: Initial version.

// Based on commit f7f30476d5c1fc4e8d155c8ea094778eed94d4f9

namespace ImGui {
	public static class ImGuiImplWgpu {
		private static Wgpu.Device               g_wgpuDevice = .Null;
		private static Wgpu.Queue                g_defaultQueue = .Null;
		private static Wgpu.TextureFormat        g_renderTargetFormat = .Undefined;
		private static Wgpu.RenderPipeline       g_pipelineState = .Null;

		private struct RenderResources
		{
		    public Wgpu.Texture         FontTexture;            // Font texture
		    public Wgpu.TextureView     FontTextureView;        // Texture view for font texture
		    public Wgpu.Sampler         Sampler;                // Sampler for the font texture
		    public Wgpu.Buffer          Uniforms;               // Shader uniforms
		    public Wgpu.BindGroup       CommonBindGroup;        // Resources bind-group to bind the common resources to pipeline
		    public ImGui.Storage        ImageBindGroups;        // Resources bind-group to bind the font/image resources to pipeline (this is a key->value map)
		    public Wgpu.BindGroup       ImageBindGroup;         // Default font-resource of Dear ImGui
		    public Wgpu.BindGroupLayout ImageBindGroupLayout;   // Cache layout used for the image bind group. Avoids allocating unnecessary JS objects when working with WebASM
		};
		private static RenderResources  g_resources;

		private struct FrameResources
		{
		    public Wgpu.Buffer  IndexBuffer;
		    public Wgpu.Buffer  VertexBuffer;
		    public ImGui.DrawIdx*  IndexBufferHost;
		    public ImGui.DrawVert* VertexBufferHost;
		    public int         IndexBufferSize;
		    public int         VertexBufferSize;
		};
		static FrameResources*  g_pFrameResources = null;
		static uint     g_numFramesInFlight = 0;
		static uint     g_frameIndex = uint.MaxValue;

		private struct Uniforms
		{
		    public float[4][4] MVP;
		};

		private static char8* shader_source = """
			struct VertexInput {
			    @location(0) position: vec2<f32>,
			    @location(1) uv: vec2<f32>,
				@location(2) color: vec4<f32>,
			};

			struct VertexOutput {
			    @builtin(position) clip_position: vec4<f32>,
				@location(0) uv: vec2<f32>,
			    @location(1) color: vec4<f32>,
			};

			struct Transform {
				mvp: mat4x4<f32>,
			};

			@group(0) @binding(0)
			var<uniform> transform: Transform;

			@group(0) @binding(1)
			var sam: sampler;

			@group(1) @binding(0)
			var tex: texture_2d<f32>;

			@vertex
			fn vs_main(in: VertexInput) -> VertexOutput {
				var out: VertexOutput;
	
				out.clip_position = transform.mvp * vec4<f32>(in.position, 0.0, 1.0);
				out.uv = in.uv;
				out.color = in.color;
	
				return out;
			}

			@fragment
			fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
				return in.color * textureSample(tex, sam, in.uv);
			}
			""";

		public static bool Init(Wgpu.Device device, int num_frames_in_flight, Wgpu.TextureFormat rt_format)
		{
			// Setup backend capabilities flags
			ImGui.IO* io = ImGui.GetIO();
			io.BackendRendererName = "imgui_impl_webgpu";
			io.BackendFlags |= .RendererHasVtxOffset;  // We can honor the ImDrawCmd::VtxOffset field, allowing for large meshes.

			g_wgpuDevice = device;
			g_defaultQueue = Wgpu.DeviceGetQueue(g_wgpuDevice);
			g_renderTargetFormat = rt_format;
			g_pFrameResources = new FrameResources[num_frames_in_flight]*;
			g_numFramesInFlight = (.) num_frames_in_flight;
			g_frameIndex = uint.MaxValue;

			g_resources.FontTexture = .Null;
			g_resources.FontTextureView = .Null;
			g_resources.Sampler = .Null;
			g_resources.Uniforms = .Null;
			g_resources.CommonBindGroup = .Null;
			//g_resources.ImageBindGroups.Data.Reserve(100);
			g_resources.ImageBindGroup = .Null;
			g_resources.ImageBindGroupLayout = .Null;

			// Create buffers with a default size (they will later be grown as needed)
			for (int i = 0; i < num_frames_in_flight; i++)
			{
			    FrameResources* fr = &g_pFrameResources[i];
			    fr.IndexBuffer = .Null;
			    fr.VertexBuffer = .Null;
			    fr.IndexBufferHost = null;
			    fr.VertexBufferHost = null;
			    fr.IndexBufferSize = 10000;
			    fr.VertexBufferSize = 5000;
			}

			return true;
		}

		public static void Shutdown()
		{
			InvalidateDeviceObjects();
			delete g_pFrameResources;
			g_pFrameResources = null;
			//wgpuQueueRelease(g_defaultQueue);
			g_wgpuDevice = .Null;
			g_numFramesInFlight = 0;
			g_frameIndex = uint.MaxValue;
		}

		public static void NewFrame()
		{
			if (g_pipelineState == .Null)
				CreateDeviceObjects();
		}

		public static void RenderDrawData(ImGui.DrawData* draw_data, Wgpu.RenderPassEncoder pass_encoder)
		{
			// Avoid rendering when minimized
			if (draw_data.DisplaySize.x <= 0.0f || draw_data.DisplaySize.y <= 0.0f)
			    return;

			// FIXME: Assuming that this only gets called once per frame!
			// If not, we can't just re-allocate the IB or VB, we'll have to do a proper allocator.
			g_frameIndex = g_frameIndex + 1;
			FrameResources* fr = &g_pFrameResources[g_frameIndex % g_numFramesInFlight];

			// Create and grow vertex/index buffers if needed
			if (fr.VertexBuffer == .Null || fr.VertexBufferSize < draw_data.TotalVtxCount)
			{
			    if (fr.VertexBuffer != .Null)
			    {
					Wgpu.BufferDestroy(fr.VertexBuffer);
					Wgpu.BufferDrop(fr.VertexBuffer);
			    }
			    SafeRelease(ref fr.VertexBufferHost);
			    fr.VertexBufferSize = draw_data.TotalVtxCount + 5000;

			    Wgpu.BufferDescriptor vb_desc = .()
			    {
			        nextInChain = null,
			        label = "Dear ImGui Vertex buffer",
			        usage = .CopyDst | .Vertex,
			        size = (.) Wgpu.AlignBufferSize!((uint64) fr.VertexBufferSize * sizeof(ImGui.DrawVert)),
			        mappedAtCreation = false
			    };
			    fr.VertexBuffer = Wgpu.DeviceCreateBuffer(g_wgpuDevice, &vb_desc);
			    if (fr.VertexBuffer == .Null)
			        return;

			    fr.VertexBufferHost = new ImGui.DrawVert[fr.VertexBufferSize]*;
			}
			if (fr.IndexBuffer == .Null || fr.IndexBufferSize < draw_data.TotalIdxCount)
			{
			    if (fr.IndexBuffer != .Null)
			    {
			        Wgpu.BufferDestroy(fr.IndexBuffer); // TODO: Maybe destroy
			        Wgpu.BufferDrop(fr.IndexBuffer);
			    }
			    SafeRelease(ref fr.IndexBufferHost);
			    fr.IndexBufferSize = draw_data.TotalIdxCount + 10000;

			    Wgpu.BufferDescriptor ib_desc = .()
			    {
			        nextInChain = null,
			        label = "Dear ImGui Index buffer",
			        usage = .CopyDst | .Index,
			        size = (.) Wgpu.AlignBufferSize!((uint64) fr.IndexBufferSize * sizeof(ImGui.DrawIdx)),
			        mappedAtCreation = false
			    };
			    fr.IndexBuffer = Wgpu.DeviceCreateBuffer(g_wgpuDevice, &ib_desc);
			    if (fr.IndexBuffer == .Null)
			        return;

			    fr.IndexBufferHost = new ImGui.DrawIdx[fr.IndexBufferSize]*;
			}

			// Upload vertex/index data into a single contiguous GPU buffer
			ImGui.DrawVert* vtx_dst = (ImGui.DrawVert*)fr.VertexBufferHost;
			ImGui.DrawIdx* idx_dst = (ImGui.DrawIdx*)fr.IndexBufferHost;
			for (int n = 0; n < draw_data.CmdListsCount; n++)
			{
			    ImGui.DrawList* cmd_list = draw_data.CmdLists[n];
			    Internal.MemCpy(vtx_dst, cmd_list.VtxBuffer.Data, cmd_list.VtxBuffer.Size * sizeof(ImGui.DrawVert));
			    Internal.MemCpy(idx_dst, cmd_list.IdxBuffer.Data, cmd_list.IdxBuffer.Size * sizeof(ImGui.DrawIdx));
			    vtx_dst += cmd_list.VtxBuffer.Size;
			    idx_dst += cmd_list.IdxBuffer.Size;
			}
			int64 vb_write_size = ((char8*)vtx_dst - (char8*)fr.VertexBufferHost + 3) & ~3;
			int64 ib_write_size = ((char8*)idx_dst - (char8*)fr.IndexBufferHost  + 3) & ~3;
			Wgpu.QueueWriteBuffer(g_defaultQueue, fr.VertexBuffer, 0, fr.VertexBufferHost, (.) vb_write_size);
			Wgpu.QueueWriteBuffer(g_defaultQueue, fr.IndexBuffer,  0, fr.IndexBufferHost,  (.) ib_write_size);

			// Setup desired render state
			ImGui_ImplWGPU_SetupRenderState(draw_data, pass_encoder, fr);

			// Render command lists
			// (Because we merged all buffers into a single one, we maintain our own offset into them)
			int global_vtx_offset = 0;
			int global_idx_offset = 0;
			ImGui.Vec2 clip_scale = draw_data.FramebufferScale;
			ImGui.Vec2 clip_off = draw_data.DisplayPos;
			for (int n = 0; n < draw_data.CmdListsCount; n++)
			{
			    ImGui.DrawList* cmd_list = draw_data.CmdLists[n];
			    for (int cmd_i = 0; cmd_i < cmd_list.CmdBuffer.Size; cmd_i++)
			    {
			        ImGui.DrawCmd* pcmd = &cmd_list.CmdBuffer.Data[cmd_i];
			        if (pcmd.UserCallback != null)
			        {
			            // User callback, registered via ImDrawList::AddCallback()
			            // (ImDrawCallback_ResetRenderState is a special callback value used by the user to request the renderer to reset render state.)
			            if (&pcmd.UserCallback == ImGui.DrawCallback_ResetRenderState)
			                ImGui_ImplWGPU_SetupRenderState(draw_data, pass_encoder, fr);
			            else
			                pcmd.UserCallback(cmd_list, pcmd);
			        }
			        else
			        {
			            // Bind custom texture
			            ImGui.TextureID tex_id = pcmd.GetTexID();
			            ImGui.ID tex_id_hash = ImGui.ImHashData(&tex_id, sizeof(ImGui.TextureID));
			            var bind_group = g_resources.ImageBindGroups.GetVoidPtr(tex_id_hash);
			            if (bind_group != null)
			            {
			                Wgpu.RenderPassEncoderSetBindGroup(pass_encoder, 1, .(bind_group), 0, null);
			            }
			            else
			            {
			                Wgpu.BindGroup image_bind_group = ImGui_ImplWGPU_CreateImageBindGroup(g_resources.ImageBindGroupLayout, .(tex_id));
			                g_resources.ImageBindGroups.SetVoidPtr(tex_id_hash, image_bind_group.Handle);
			                Wgpu.RenderPassEncoderSetBindGroup(pass_encoder, 1, image_bind_group, 0, null);
			            }

			            // Project scissor/clipping rectangles into framebuffer space
			            ImGui.Vec2 clip_min = .((pcmd.ClipRect.x - clip_off.x) * clip_scale.x, (pcmd.ClipRect.y - clip_off.y) * clip_scale.y);
			            ImGui.Vec2 clip_max = .((pcmd.ClipRect.z - clip_off.x) * clip_scale.x, (pcmd.ClipRect.w - clip_off.y) * clip_scale.y);
			            if (clip_max.x <= clip_min.x || clip_max.y <= clip_min.y)
			                continue;

			            // Apply scissor/clipping rectangle, Draw
			            Wgpu.RenderPassEncoderSetScissorRect(pass_encoder, (.)clip_min.x, (.)clip_min.y, (.)(clip_max.x - clip_min.x), (.)(clip_max.y - clip_min.y));
			            Wgpu.RenderPassEncoderDrawIndexed(pass_encoder, pcmd.ElemCount, 1, (.) (pcmd.IdxOffset + global_idx_offset), (.) (pcmd.VtxOffset + global_vtx_offset), 0);
			        }
			    }
			    global_idx_offset += cmd_list.IdxBuffer.Size;
			    global_vtx_offset += cmd_list.VtxBuffer.Size;
			}
		}

		public static void InvalidateDeviceObjects()
		{
			if (g_wgpuDevice == .Null)
			    return;

			SafeRelease(ref g_pipelineState);
			SafeRelease(ref g_resources);

			ImGui.IO* io = ImGui.GetIO();
			io.Fonts.SetTexID(null); // We copied g_pFontTextureView to io.Fonts->TexID so let's clear that as well.

			for (uint i = 0; i < g_numFramesInFlight; i++)
			    SafeRelease(ref g_pFrameResources[i]);
		}

		public static bool CreateDeviceObjects()
		{
		    if (g_wgpuDevice == .Null)
		        return false;
		    if (g_pipelineState != .Null)
		        InvalidateDeviceObjects();

			// Create bind group 0 layout
			Wgpu.BindGroupLayoutEntry[?] bind_group0_entries = .(
				.() {
					binding = 0,
					visibility = .Vertex,
					buffer = .() {
						type = .Uniform,
					}
				},
				.() {
					binding = 1,
					visibility = .Fragment,
					sampler = .() {
						type = .Filtering
					}
				}
			);
			Wgpu.BindGroupLayoutDescriptor bind_group0_layout_desc = .() {
				entryCount = bind_group0_entries.Count,
				entries = &bind_group0_entries
			};
			Wgpu.BindGroupLayout bind_group0_layout = Wgpu.DeviceCreateBindGroupLayout(g_wgpuDevice, &bind_group0_layout_desc);

			// Create bind group 1 layout
			Wgpu.BindGroupLayoutEntry[?] bind_group1_entries = .(
				.() {
					binding = 0,
					visibility = .Fragment,
					texture = .() {
						sampleType = .Float,
						viewDimension = ._2D
					}
				}
			);
			Wgpu.BindGroupLayoutDescriptor bind_group1_layout_desc = .() {
				entryCount = bind_group1_entries.Count,
				entries = &bind_group1_entries
			};
			Wgpu.BindGroupLayout bind_group1_layout = Wgpu.DeviceCreateBindGroupLayout(g_wgpuDevice, &bind_group1_layout_desc);

			// Create render pipeline layout
			Wgpu.BindGroupLayout[?] bind_group_layouts = .(bind_group0_layout, bind_group1_layout);
			Wgpu.PipelineLayoutDescriptor pipeline_layout_desc = .() {
				bindGroupLayoutCount = bind_group_layouts.Count,
				bindGroupLayouts = &bind_group_layouts
			};
			Wgpu.PipelineLayout pipeline_layout = Wgpu.DeviceCreatePipelineLayout(g_wgpuDevice, &pipeline_layout_desc);
		
		    // Create render pipeline
		    Wgpu.RenderPipelineDescriptor graphics_pipeline_desc = .();
		    graphics_pipeline_desc.primitive.topology = .TriangleList;
		    graphics_pipeline_desc.primitive.stripIndexFormat = .Undefined;
		    graphics_pipeline_desc.primitive.frontFace = .CW;
		    graphics_pipeline_desc.primitive.cullMode = .None;
		    graphics_pipeline_desc.multisample.count = 1;
		    graphics_pipeline_desc.multisample.mask = uint32.MaxValue;
		    graphics_pipeline_desc.multisample.alphaToCoverageEnabled = false;
		    graphics_pipeline_desc.layout = pipeline_layout; // Use automatic layout generation

			// Create shader module
			Wgpu.ShaderModule shaderModule = ImGui_ImplWGPU_CreateShaderModule();

		    // Create the vertex shader
		    graphics_pipeline_desc.vertex.module = shaderModule;
		    graphics_pipeline_desc.vertex.entryPoint = "vs_main";
		
		    // Vertex input configuration
		    Wgpu.VertexAttribute[?] attribute_desc =
		    .(
		        .() { format = .Float32x2, offset = offsetof(ImGui.DrawVert, pos), shaderLocation = 0 },
		        .() { format = .Float32x2, offset = offsetof(ImGui.DrawVert, uv),  shaderLocation = 1 },
		        .() { format = .Unorm8x4,  offset = offsetof(ImGui.DrawVert, col), shaderLocation = 2 },
		    );
		
		    Wgpu.VertexBufferLayout[1] buffer_layouts;
		    buffer_layouts[0].arrayStride = sizeof(ImGui.DrawVert);
		    buffer_layouts[0].stepMode = .Vertex;
		    buffer_layouts[0].attributeCount = 3;
		    buffer_layouts[0].attributes = &attribute_desc;
		
		    graphics_pipeline_desc.vertex.bufferCount = 1;
		    graphics_pipeline_desc.vertex.buffers = &buffer_layouts;
	
		
		    // Create the blending setup
		    Wgpu.BlendState blend_state = .();
		    blend_state.alpha.operation = .Add;
		    blend_state.alpha.srcFactor = .One;
		    blend_state.alpha.dstFactor = .OneMinusSrcAlpha;
		    blend_state.color.operation = .Add;
		    blend_state.color.srcFactor = .SrcAlpha;
		    blend_state.color.dstFactor = .OneMinusSrcAlpha;
		
		    Wgpu.ColorTargetState color_state = .();
		    color_state.format = g_renderTargetFormat;
		    color_state.blend = &blend_state;
		    color_state.writeMask = .All;
		
		    Wgpu.FragmentState fragment_state = .();
		    fragment_state.module = shaderModule;
		    fragment_state.entryPoint = "fs_main";
		    fragment_state.targetCount = 1;
		    fragment_state.targets = &color_state;
		
		    graphics_pipeline_desc.fragment = &fragment_state;
		
		    // Create depth-stencil State
		    Wgpu.DepthStencilState depth_stencil_state = .();
		    depth_stencil_state.depthBias = 0;
		    depth_stencil_state.depthBiasClamp = 0;
		    depth_stencil_state.depthBiasSlopeScale = 0;
		
		    // Configure disabled depth-stencil state
		    graphics_pipeline_desc.depthStencil = null;
		
		    g_pipelineState = Wgpu.DeviceCreateRenderPipeline(g_wgpuDevice, &graphics_pipeline_desc);
		
		    ImGui_ImplWGPU_CreateFontsTexture();
		    ImGui_ImplWGPU_CreateUniformBuffer();
		
		    // Create resource bind group
		    Wgpu.BindGroupLayout[2] bg_layouts;
		    //bg_layouts[0] = Wgpu.RenderPipelineGetBindGroupLayout(g_pipelineState, 0);
		    //bg_layouts[1] = Wgpu.RenderPipelineGetBindGroupLayout(g_pipelineState, 1);
			bg_layouts[0] = bind_group0_layout;
			bg_layouts[1] = bind_group1_layout;
		
		    Wgpu.BindGroupEntry[?] common_bg_entries =
		    .(
		        .() { nextInChain = null, binding = 0, buffer = g_resources.Uniforms, offset = 0, size = sizeof(Uniforms), sampler = .Null, textureView = .Null },
		        .() { nextInChain = null, binding = 1, buffer = .Null,                offset = 0, size = 0, sampler = g_resources.Sampler,  textureView = .Null },
		    );
		
		    Wgpu.BindGroupDescriptor common_bg_descriptor = .();
		    common_bg_descriptor.layout = bg_layouts[0];
		    common_bg_descriptor.entryCount = common_bg_entries.Count;
		    common_bg_descriptor.entries = &common_bg_entries;
		    g_resources.CommonBindGroup = Wgpu.DeviceCreateBindGroup(g_wgpuDevice, &common_bg_descriptor);
		
		    Wgpu.BindGroup image_bind_group = ImGui_ImplWGPU_CreateImageBindGroup(bg_layouts[1], g_resources.FontTextureView);
		    g_resources.ImageBindGroup = image_bind_group;
		    g_resources.ImageBindGroupLayout = bg_layouts[1];
		    g_resources.ImageBindGroups.SetVoidPtr(ImGui.ImHashData(&g_resources.FontTextureView, sizeof(ImGui.TextureID)), image_bind_group.Handle);
		
		    SafeRelease(ref shaderModule);
		    SafeRelease(ref bg_layouts[0]);
		
		    return true;
		}

		private static void ImGui_ImplWGPU_SetupRenderState(ImGui.DrawData* draw_data, Wgpu.RenderPassEncoder ctx, FrameResources* fr)
		{
		    // Setup orthographic projection matrix into our constant buffer
		    // Our visible imgui space lies from draw_data->DisplayPos (top left) to draw_data->DisplayPos+data_data->DisplaySize (bottom right).
		    {
		        float L = draw_data.DisplayPos.x;
		        float R = draw_data.DisplayPos.x + draw_data.DisplaySize.x;
		        float T = draw_data.DisplayPos.y;
		        float B = draw_data.DisplayPos.y + draw_data.DisplaySize.y;
		        float[4][4] mvp =
		        .(
		            .( 2.0f/(R-L),   0.0f,           0.0f,       0.0f ),
		            .( 0.0f,         2.0f/(T-B),     0.0f,       0.0f ),
		            .( 0.0f,         0.0f,           0.5f,       0.0f ),
		            .( (R+L)/(L-R),  (T+B)/(B-T),    0.5f,       1.0f ),
		        );
		        Wgpu.QueueWriteBuffer(g_defaultQueue, g_resources.Uniforms, 0, &mvp, sizeof(float[4][4]));
		    }
		
			// Setup viewport
			Wgpu.RenderPassEncoderSetViewport(ctx, 0, 0, draw_data.FramebufferScale.x * draw_data.DisplaySize.x, draw_data.FramebufferScale.y * draw_data.DisplaySize.y, 0, 1);
		
		    // Bind shader and vertex buffers
		    Wgpu.RenderPassEncoderSetVertexBuffer(ctx, 0, fr.VertexBuffer, 0, (.) (fr.VertexBufferSize * sizeof(ImGui.DrawVert)));
		    Wgpu.RenderPassEncoderSetIndexBuffer(ctx, fr.IndexBuffer, sizeof(ImGui.DrawIdx) == 2 ? .Uint16 : .Uint32, 0, (.) (fr.IndexBufferSize * sizeof(ImGui.DrawIdx)));
		    Wgpu.RenderPassEncoderSetPipeline(ctx, g_pipelineState);
		    Wgpu.RenderPassEncoderSetBindGroup(ctx, 0, g_resources.CommonBindGroup, 0, null);
		
		    // Setup blend factor
		    Wgpu.Color blend_color = .() { r = 0.f, g = 0.f, b = 0.f, a = 0.f };
		    Wgpu.RenderPassEncoderSetBlendConstant(ctx, &blend_color);
		}

		private static Wgpu.ShaderModule ImGui_ImplWGPU_CreateShaderModule()
		{
		    Wgpu.ShaderModuleWGSLDescriptor wgsl_desc = .();
		    wgsl_desc.chain.sType = .ShaderModuleWGSLDescriptor;
		    wgsl_desc.code = shader_source;

		    Wgpu.ShaderModuleDescriptor desc = .();
		    desc.nextInChain = (Wgpu.ChainedStruct*) (&wgsl_desc);

		    return Wgpu.DeviceCreateShaderModule(g_wgpuDevice, &desc);
		}

		private static Wgpu.BindGroup ImGui_ImplWGPU_CreateImageBindGroup(Wgpu.BindGroupLayout layout, Wgpu.TextureView texture)
		{
		    Wgpu.BindGroupEntry[?] image_bg_entries = .( .() { nextInChain = null, binding = 0, buffer = .Null, offset = 0, size = 0, sampler = .Null, textureView = texture } );

		    Wgpu.BindGroupDescriptor image_bg_descriptor = .();
		    image_bg_descriptor.layout = layout;
		    image_bg_descriptor.entryCount = image_bg_entries.Count;
		    image_bg_descriptor.entries = &image_bg_entries;
		    return Wgpu.DeviceCreateBindGroup(g_wgpuDevice, &image_bg_descriptor);
		}

		private static void ImGui_ImplWGPU_CreateFontsTexture()
		{
		    // Build texture atlas
		    ImGui.IO* io = ImGui.GetIO();
		    uint8* pixels;
		    int32 width, height, size_pp = 0;
		    io.Fonts.GetTexDataAsRGBA32(out pixels, out width, out height, &size_pp);

		    // Upload texture to graphics system
		    {
		        Wgpu.TextureDescriptor tex_desc = .();
		        tex_desc.label = "Dear ImGui Font Texture";
		        tex_desc.dimension = ._2D;
		        tex_desc.size.width = (.) width;
		        tex_desc.size.height = (.) height;
		        tex_desc.size.depthOrArrayLayers = 1;
		        tex_desc.sampleCount = 1;
		        tex_desc.format = .RGBA8Unorm;
		        tex_desc.mipLevelCount = 1;
		        tex_desc.usage = .CopyDst | .TextureBinding;
		        g_resources.FontTexture = Wgpu.DeviceCreateTexture(g_wgpuDevice, &tex_desc);

		        Wgpu.TextureViewDescriptor tex_view_desc = .();
		        tex_view_desc.format = .RGBA8Unorm;
		        tex_view_desc.dimension = ._2D;
		        tex_view_desc.baseMipLevel = 0;
		        tex_view_desc.mipLevelCount = 1;
		        tex_view_desc.baseArrayLayer = 0;
		        tex_view_desc.arrayLayerCount = 1;
		        tex_view_desc.aspect = .All;
		        g_resources.FontTextureView = Wgpu.TextureCreateView(g_resources.FontTexture, &tex_view_desc);
		    }

		    // Upload texture data
		    {
		        Wgpu.ImageCopyTexture dst_view = .();
		        dst_view.texture = g_resources.FontTexture;
		        dst_view.mipLevel = 0;
		        dst_view.origin = .() { x = 0, y = 0, z = 0 };
		        dst_view.aspect = .All;
		        Wgpu.TextureDataLayout layout = .();
		        layout.offset = 0;
		        layout.bytesPerRow = (.) (width * size_pp);
		        layout.rowsPerImage = (.) height;
		        Wgpu.Extent3D size = .() { width = (.) width, height = (.) height, depthOrArrayLayers = 1 };
		        Wgpu.QueueWriteTexture(g_defaultQueue, &dst_view, pixels, (.) (width * size_pp * height), &layout, &size);
		    }

		    // Create the associated sampler
		    // (Bilinear sampling is required by default. Set 'io.Fonts->Flags |= ImFontAtlasFlags_NoBakedLines' or 'style.AntiAliasedLinesUseTex = false' to allow point/nearest sampling)
		    {
		        Wgpu.SamplerDescriptor sampler_desc = .();
		        sampler_desc.minFilter = .Linear;
		        sampler_desc.magFilter = .Linear;
		        sampler_desc.mipmapFilter = .Linear;
		        sampler_desc.addressModeU = .Repeat;
		        sampler_desc.addressModeV = .Repeat;
		        sampler_desc.addressModeW = .Repeat;
		        sampler_desc.maxAnisotropy = 1;
		        g_resources.Sampler = Wgpu.DeviceCreateSampler(g_wgpuDevice, &sampler_desc);
		    }

		    // Store our identifier
		    Debug.Assert(sizeof(ImGui.TextureID) >= sizeof(Wgpu.Texture), "Can't pack descriptor handle into TexID, 32-bit not supported yet.");
		    io.Fonts.SetTexID((ImGui.TextureID) g_resources.FontTextureView.Handle);
		}

		static void ImGui_ImplWGPU_CreateUniformBuffer()
		{
		    Wgpu.BufferDescriptor ub_desc = .()
		    {
		        nextInChain = null,
		        label = "Dear ImGui Uniform buffer",
		        usage = .CopyDst | .Uniform,
		        size = sizeof(Uniforms),
		        mappedAtCreation = false
		    };
		    g_resources.Uniforms = Wgpu.DeviceCreateBuffer(g_wgpuDevice, &ub_desc);
		}

		private static void SafeRelease(ref ImGui.DrawIdx* res)
		{
		    if (res != null)
		        delete res;
		    res = null;
		}
		private static void SafeRelease(ref ImGui.DrawVert* res)
		{
		    if (res != null)
		        delete res;
		    res = null;
		}
		private static void SafeRelease(ref Wgpu.BindGroupLayout res)
		{
		    if (res != .Null)
		        Wgpu.BindGroupLayoutDrop(res);
		    res = .Null;
		}
		private static void SafeRelease(ref Wgpu.BindGroup res)
		{
		    if (res != .Null)
		        Wgpu.BindGroupDrop(res);
		    res = .Null;
		}
		private static void SafeRelease(ref Wgpu.Buffer res)
		{
		    if (res != .Null)
		        Wgpu.BufferDrop(res); // TODO: Maybe destroy
		    res = .Null;
		}
		private static void SafeRelease(ref Wgpu.RenderPipeline res)
		{
		    if (res != .Null)
		        Wgpu.RenderPipelineDrop(res);
		    res = .Null;
		}
		private static void SafeRelease(ref Wgpu.Sampler res)
		{
		    if (res != .Null)
		        Wgpu.SamplerDrop(res);
		    res = .Null;
		}
		private static void SafeRelease(ref Wgpu.ShaderModule res)
		{
		    if (res != .Null)
		        Wgpu.ShaderModuleDrop(res);
		    res = .Null;
		}
		private static void SafeRelease(ref Wgpu.TextureView res)
		{
		    if (res != .Null)
		        Wgpu.TextureViewDrop(res);
		    res = .Null;
		}
		private static void SafeRelease(ref Wgpu.Texture res)
		{
		    if (res != .Null)
		        Wgpu.TextureDrop(res); // TODO: Maybe destroy
		    res = .Null;
		}

		private static void SafeRelease(ref RenderResources res)
		{
		    SafeRelease(ref res.FontTexture);
		    SafeRelease(ref res.FontTextureView);
		    SafeRelease(ref res.Sampler);
		    SafeRelease(ref res.Uniforms);
		    SafeRelease(ref res.CommonBindGroup);
		    SafeRelease(ref res.ImageBindGroup);
		    SafeRelease(ref res.ImageBindGroupLayout);
		};

		private static void SafeRelease(ref FrameResources res)
		{
		    SafeRelease(ref res.IndexBuffer);
		    SafeRelease(ref res.VertexBuffer);
		    SafeRelease(ref res.IndexBufferHost);
		    SafeRelease(ref res.VertexBufferHost);
		}
	}
}