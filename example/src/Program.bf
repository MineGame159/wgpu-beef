using System;
using System.IO;
using System.Collections;

using GLFW;
using Wgpu;
using ImGui;
using stb_image;

namespace Example {
	[CRepr]
	struct Vertex : this(float[3] position, float[2] texCoords) {}

	class Program {
		public static int Main(String[] args) {
			// Create window
			Glfw.Init();

			Glfw.WindowHint(.ClientApi, Glfw.ClientApi.NoApi);
			GlfwWindow* window = Glfw.CreateWindow(1280, 720, "WGPU", null, null);

			// Wgpu log
			Wgpu.SetLogLevel(.Info);
			Wgpu.SetLogCallback((level, msg) => Console.WriteLine("{}: {}", level, StringView(msg)));

			// Create instance
			Wgpu.InstanceDescriptor instanceDesc = .() {};
			Wgpu.Instance instance = Wgpu.CreateInstance(&instanceDesc);

			// Create surface
			Wgpu.Surface surface = Wgpu.CreateSurfaceFromGlfw(instance, window);

			// Request adapter
			Wgpu.RequestAdapterOptions options = .() {
				//compatibleSurface = surface,
				powerPreference = .HighPerformance,
				forceFallbackAdapter = false
			};
			Wgpu.Adapter adapter = .Null;
			instance.RequestAdapter(&options, (status, adapter, message, userdata) => *(Wgpu.Adapter*) userdata = adapter, &adapter);

			// Request device
			Wgpu.RequiredLimits limits = .() { limits = .Default() };
			Wgpu.DeviceDescriptor deviceDesc = .() {
				requiredLimits = &limits,
				defaultQueue = .() {}
			};
			Wgpu.Device device = .Null;
			adapter.RequestDevice(&deviceDesc, (status, device, message, userdata) => *(Wgpu.Device*) userdata = device, &device);

			// Set error callbacks
			device.SetUncapturedErrorCallback((type, message, userdata) => Console.WriteLine("{}: {}", type, StringView(message)), null);

			// Get queue
			Wgpu.Queue queue = device.GetQueue();

			// SwapChain
			Wgpu.SwapChainDescriptor swapChainDesc = .() {
				usage = .RenderAttachment,
				format = .BGRA8Unorm,
				width = 1280,
				height = 720,
				presentMode = .Fifo
			};
			Wgpu.SwapChain swapChain = device.CreateSwapChain(surface, &swapChainDesc);

			Glfw.SetFramebufferSizeCallback(window, new [&](window, width, height) => {
				swapChainDesc.width = (.) width;
				swapChainDesc.height = (.) height;
				swapChain = device.CreateSwapChain(surface, &swapChainDesc);
			});

			// Texture
			List<uint8> rawData = scope .();
			File.ReadAll("assets/beef.png", rawData);
			int32 w = 0, h = 0, c;
			uint8* data = stbi.stbi_load_from_memory(rawData.Ptr, (.) rawData.Count, &w, &h, &c, 4);

			Wgpu.TextureDescriptor textureDesc = .() {
				usage = .TextureBinding,
				dimension = ._2D,
				size = .((.) w, (.) h, 1),
				format = .RGBA8Unorm,
				mipLevelCount = 1,
				sampleCount = 1
			};
			Wgpu.Texture texture = device.CreateTextureWithData(queue, &textureDesc, data);
			stbi.stbi_image_free(data);

			Wgpu.TextureViewDescriptor textureViewDesc = .();
			Wgpu.TextureView textureView = texture.CreateView(&textureViewDesc);

			// Sampler
			Wgpu.SamplerDescriptor samplerDesc = .() {
				addressModeU = .ClampToEdge,
				addressModeV = .ClampToEdge,
				addressModeW = .ClampToEdge,
				magFilter = .Linear,
				minFilter = .Linear,
				mipmapFilter = .Nearest
			};
			Wgpu.Sampler sampler = device.CreateSampler(&samplerDesc);

			// Bind group layout
			Wgpu.BindGroupLayoutEntry[?] bindGroupLayoutEntries = .(
				.() {
					binding = 0,
					visibility = .Fragment,
					texture = .() {
						sampleType = .Float,
						viewDimension = ._2D
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
			Wgpu.BindGroupLayoutDescriptor bindGroupLayoutDesc = .() {
				entryCount = bindGroupLayoutEntries.Count,
				entries = &bindGroupLayoutEntries
			};
			Wgpu.BindGroupLayout bindGroupLayout = device.CreateBindGroupLayout(&bindGroupLayoutDesc);

			// Bind group
			Wgpu.BindGroupEntry[?] bindGroupEntries = .(
				.() {
					binding = 0,
					textureView = textureView
				},
				.() {
					binding = 1,
					sampler = sampler
				}
			);
			Wgpu.BindGroupDescriptor bindGroupDesc = .() {
				layout = bindGroupLayout,
				entryCount = bindGroupEntries.Count,
				entries = &bindGroupEntries
			};
			Wgpu.BindGroup bindGroup = device.CreateBindGroup(&bindGroupDesc);

			// Pipeline
			String shaderBuffer = scope .();
			File.ReadAllText("assets/shader.wgsl", shaderBuffer);
			Wgpu.ShaderModuleWGSLDescriptor shaderWgslDesc = .() {
				chain = .() {
					sType = .ShaderModuleWGSLDescriptor
				},
				code = shaderBuffer.CStr()
			};
			Wgpu.ShaderModuleDescriptor shaderDesc = .() {
				nextInChain = (Wgpu.ChainedStruct*) &shaderWgslDesc,
			};
			Wgpu.ShaderModule shader = device.CreateShaderModule(&shaderDesc);

			// Vertex buffer
			Vertex[?] vertices = .(
				.(.(-0.5f, -0.5f, 0), .(0, 1)),
				.(.(-0.5f, 0.5f, 0.0f), .(0, 0)),
				.(.(0.5f, 0.5f, 0.0f), .(1, 0)),
				.(.(0.5f, -0.5f, 0.0f), .(1, 1))
			);

			Wgpu.BufferInitDescriptor vertexBufferDesc = .() {
				contents = .((uint8*) &vertices, vertices.Count * sizeof(Vertex)),
				usage = .Vertex
			};
			Wgpu.Buffer vertexBuffer = device.CreateBufferInit(&vertexBufferDesc);

			// Index buffer
			uint16[?] indices = .(
			    0, 1, 2,
				2, 3, 0
			);

			Wgpu.BufferInitDescriptor indexBufferDesc = .() {
				contents = .((uint8*) &indices, indices.Count * sizeof(uint16)),
				usage = .Index
			};
			Wgpu.Buffer indexBuffer = device.CreateBufferInit(&indexBufferDesc);

			// Pipeline layout
			Wgpu.PipelineLayoutDescriptor layoutDesc = .() {
				bindGroupLayoutCount = 1,
				bindGroupLayouts = &bindGroupLayout
			};
			Wgpu.PipelineLayout layout = device.CreatePipelineLayout(&layoutDesc);

			// Pipeline
			Wgpu.VertexAttribute[?] attributes = .(
				.() {
					format = .Float32x3,
					offset = 0,
					shaderLocation = 0
				},
				.() {
					format = .Float32x2,
					offset = sizeof(float[3]),
					shaderLocation = 1
				}
			);
			Wgpu.VertexBufferLayout vertexBufferLayout = .() {
				arrayStride = sizeof(Vertex),
				stepMode = .Vertex,
				attributeCount = attributes.Count,
				attributes = &attributes
			};

			Wgpu.BlendState blend = .() {
				color = .(.Add, .SrcAlpha, .OneMinusSrcAlpha),
				alpha = .(.Add, .One, .OneMinusSrcAlpha)
			};
			Wgpu.ColorTargetState colorTarget = .() {
				format = .BGRA8Unorm,
				blend = &blend,
				writeMask = .All
			};
			Wgpu.FragmentState fragment = .() {
				module = shader,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &colorTarget
			};

			Wgpu.RenderPipelineDescriptor pipelineDesc = .() {
				layout = layout,
				vertex = .() {
					module = shader,
					entryPoint = "vs_main",
					bufferCount = 1,
					buffers = &vertexBufferLayout
				},
				fragment = &fragment,
				primitive = .() {
					topology = .TriangleList,
					stripIndexFormat = .Undefined,
					frontFace = .CW,
					cullMode = .Back,
				},
				depthStencil = null,
				multisample = .() {
					count = 1,
					mask = ~0,
					alphaToCoverageEnabled = false
				}
			};
			Wgpu.RenderPipeline pipeline = device.CreateRenderPipeline(&pipelineDesc);

			// ImGui
			ImGui.CHECKVERSION();
			ImGui.Context* context = ImGui.CreateContext();
			ImGui.StyleColorsDark();
			ImGuiImplGlfw.InitForOther(window, true);
			ImGuiImplWgpu.Init(device, 3, .BGRA8Unorm);

			// Loop
			while (!Glfw.WindowShouldClose(window)) {
				Glfw.PollEvents();

				Wgpu.CommandEncoderDescriptor encoderDesc = .();

				Wgpu.TextureView view = swapChain.GetCurrentTextureView();
				Wgpu.CommandEncoder encoder = device.CreateCommandEncoder(&encoderDesc);

				{
					Wgpu.RenderPassColorAttachment colorDesc = .() {
						view = view,
						loadOp = .Clear,
						storeOp = .Store,
						clearValue = .(1, 1, 1, 1)
					};
					Wgpu.RenderPassDescriptor passDesc = .() {
						colorAttachmentCount = 1,
						colorAttachments = &colorDesc,
						depthStencilAttachment = null
					};
					Wgpu.RenderPassEncoder pass = encoder.BeginRenderPass(&passDesc);

					pass.SetPipeline(pipeline);
					pass.SetBindGroup(0, bindGroup, 0, null);
					pass.SetVertexBuffer(0, vertexBuffer, 0, 0);
					pass.SetIndexBuffer(indexBuffer, .Uint16, 0, 0);
					pass.DrawIndexed(indices.Count, 1, 0, 0, 0);

					// ImGui
					ImGuiImplWgpu.NewFrame();
					ImGuiImplGlfw.NewFrame();
					ImGui.NewFrame();

					ImGui.ShowDemoWindow();

					ImGui.Render();
					ImGuiImplWgpu.RenderDrawData(ImGui.GetDrawData(), pass);

					// End render pass
					pass.End();
				}

				// Submit
				Wgpu.CommandBufferDescriptor cbDesc = .();
				Wgpu.CommandBuffer cb = encoder.Finish(&cbDesc);
				queue.Submit(1, &cb);
				
				swapChain.Present();
				view.Drop();
			}

			// Destroy
			ImGuiImplWgpu.Shutdown();
			ImGuiImplGlfw.Shutdown();
			ImGui.Shutdown(context);

			Glfw.DestroyWindow(window);
			Glfw.Terminate();
			return 0;
		}
	}
}