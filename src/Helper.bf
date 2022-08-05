using System;
using System.Interop;

namespace Wgpu {
	extension Wgpu {
		public const uint64 COPY_BUFFER_ALIGNMENT = 4;

		public static mixin AlignBufferSize(var size) {
			uint64 alignMask = COPY_BUFFER_ALIGNMENT - 1;
			Math.Max((size + alignMask) & ~alignMask, COPY_BUFFER_ALIGNMENT)
		}

		public enum TextureFormatFeature {
			/// When used as a STORAGE texture, then a texture with this format can be bound with
			StorageReadWrite = 1 << 0,
			/// When used as a STORAGE texture, then a texture with this format can be written to with atomics.
			StorageAtomics = 1 << 1
		}

		public struct TextureFormatFeatures {
			public TextureUsage allowedUsages;
			public TextureFormatFeature flags;
			public bool filterable;
		}

		public struct TextureFormatInfo {
			public FeatureName requiredFeatures;
			public TextureSampleType sampleType;
			public uint8[2] blockDimensions;
			public uint8 blockSize;
			public uint8 components;
			public bool srgb;
			public TextureFormatFeatures guaranteedFormatFeatures;
		}

		public struct BufferInitDescriptor {
			public c_char* label;
			public Span<uint8> contents;
			public BufferUsage usage;
		}

		[CRepr]
		public struct IndirectCommand {
			public uint32 vertexCount;
			public uint32 instanceCount;
			public uint32 baseVertex;
			public uint32 baseInstance;
		}

		[CRepr]
		public struct IndexedIndirectCommand {
			public uint32 vertexCount;
			public uint32 instanceCount;
			public uint32 baseIndex;
			public uint32 vertexOffset;
			public uint32 baseInstance;
		}

		/// Creates a Buffer with data to initialize it.
		public static Buffer DeviceCreateBufferInit(Device device, BufferInitDescriptor* descriptor) {
			if (descriptor.contents.IsEmpty) {
				BufferDescriptor desc = .() {
					label = descriptor.label,
					size = 0,
					usage = descriptor.usage,
					mappedAtCreation = false
				};

				return device.CreateBuffer(&desc);
			}

			uint64 size = (.) descriptor.contents.Length;
			uint64 alignedSize = AlignBufferSize!(size);

			BufferDescriptor desc = .() {
				label = descriptor.label,
				size = alignedSize,
				usage = descriptor.usage,
				mappedAtCreation = true
			};
			Buffer buffer = device.CreateBuffer(&desc);

			void* data = buffer.GetMappedRange(0, alignedSize);
			Internal.MemCpy(data, descriptor.contents.Ptr, (.) size);
			buffer.Unmap();

			return buffer;
		}

		/// Upload an entire texture and its mipmaps from a source buffer.
		/// Expects all mipmaps to be tightly packed in the data buffer.
		/// If the texture is a 2DArray texture, uploads each layer in order, expecting each layer and its mips to be tightly packed.
		/// Example: Layer0Mip0 Layer0Mip1 Layer0Mip2 ... Layer1Mip0 Layer1Mip1 Layer1Mip2 ...
		/// Implicitly adds the COPY_DST usage if it is not present in the descriptor, as it is required to be able to upload the data to the gpu.
		public static Texture DeviceCreateTextureWithData(Device device, Queue queue, TextureDescriptor* descriptor, void* data) {
			// Implicitly add the COPY_DST usage
			descriptor.usage |= .CopyDst;
			Texture texture = device.CreateTexture(descriptor);

			TextureFormatInfo formatInfo = Describe(descriptor.format);
			uint32 layerIterations = descriptor.GetArrayLayerCount();

			uint binaryOffset = 0;
			for (uint32 layer < layerIterations) {
				for (uint32 mip < descriptor.mipLevelCount) {
					Extent3D mipSize = descriptor.GetMipLevelSize(mip);

					// copying layers separately
					if (descriptor.dimension != ._3D) mipSize.depthOrArrayLayers = 1;

					// When uploading mips of compressed textures and the mip is supposed to be
					// a size that isn't a multiple of the block size, the mip needs to be uploaded
					// as its "physical size" which is the size rounded up to the nearest block size.
					Extent3D mipPhysical = mipSize.GetPhysicalSize(descriptor.format);

					// All these calculations are performed on the physical size as that's the
					// data that exists in the buffer.
					uint32 widthBlocks = mipPhysical.width / formatInfo.blockDimensions[0];
					uint32 heightBlocks = mipPhysical.height / formatInfo.blockDimensions[1];

					uint32 bytesPerRow = widthBlocks * formatInfo.blockSize;
					uint32 dataSize = bytesPerRow * heightBlocks * mipSize.depthOrArrayLayers;

					uint endOffset = binaryOffset + dataSize;

					ImageCopyTexture destination = .() {
						texture = texture,
						mipLevel = mip,
						origin = .(0, 0, layer),
						aspect = .All
					};
					TextureDataLayout dataLayout = .() {
						offset = 0,
						bytesPerRow = bytesPerRow,
						rowsPerImage = heightBlocks
					};
					queue.WriteTexture(&destination, &((uint8*) data)[binaryOffset], endOffset - binaryOffset, &dataLayout, &mipPhysical);

					binaryOffset = endOffset;
				}
			}

			return texture;
		}

		extension Device {
			/// Creates a Buffer with data to initialize it.
			public Buffer CreateBufferInit(BufferInitDescriptor* descriptor) => DeviceCreateBufferInit(this, descriptor);

			/// Upload an entire texture and its mipmaps from a source buffer.
			/// Expects all mipmaps to be tightly packed in the data buffer.
			/// If the texture is a 2DArray texture, uploads each layer in order, expecting each layer and its mips to be tightly packed.
			/// Example: Layer0Mip0 Layer0Mip1 Layer0Mip2 ... Layer1Mip0 Layer1Mip1 Layer1Mip2 ...
			/// Implicitly adds the COPY_DST usage if it is not present in the descriptor, as it is required to be able to upload the data to the gpu.
			public Texture CreateTextureWithData(Queue queue, TextureDescriptor* descriptor, void* data) => DeviceCreateTextureWithData(this, queue, descriptor, data);
		}

		extension TextureDescriptor {
			/// Returns the number of array layers.
			public uint32 GetArrayLayerCount() => dimension == ._3D ? 1 : size.depthOrArrayLayers;

			/// Calculates the extent at a given mip level. If the given mip level is larger than possible, returns 0.
			public Extent3D GetMipLevelSize(uint32 level) {
				if (level >= mipLevelCount) return .();
				return size.GetMipLevelSize(level, dimension == ._3D);
			}
		}

		extension Extent3D {
			/// Calculates the extent at a given mip level. Does not account for memory size being a multiple of block size.
			public Self GetMipLevelSize(uint32 level, bool is3dTexture) => .() {
				width = Math.Max(1, width >> level),
				height = Math.Max(1, height >> level),
				depthOrArrayLayers = is3dTexture ? Math.Max(1, depthOrArrayLayers >> level) : depthOrArrayLayers
			};

			/// Calculates the physical size is backing an texture of the given format and extent. This includes padding to the block width and height of the format.
			/// This is the texture extent that you must upload at when uploading to mipmaps of compressed textures.
			public Self GetPhysicalSize(TextureFormat format) {
				uint8[2] blockSize = Describe(format).blockDimensions;
				uint32 blockWidth = blockSize[0];
				uint32 blockHeight = blockSize[1];

				uint32 width = ((width + blockWidth - 1) / blockWidth) * blockWidth;
				uint32 height = ((height + blockHeight - 1) / blockHeight) * blockHeight;

				return .(width, height, depthOrArrayLayers);
			}
		}

		extension Origin3D {
			public static Self Zero => .();
		}

		public static TextureFormatInfo Describe(TextureFormat format) {
			// Features
			FeatureName native = .Undefined;
			FeatureName bc = .TextureCompressionBC;
			FeatureName etc2 = .TextureCompressionETC2;
			FeatureName astc_ldr = .TextureCompressionASTC; // LDR
			//FeatureName norm16bit = .Undefined; // 16BIT_NORM

			// Sample Types
			TextureSampleType uint = .Uint;
			TextureSampleType sint = .Sint;
			TextureSampleType nearest = .UnfilterableFloat;
			TextureSampleType float = .Float;
			TextureSampleType depth = .Depth;

			// Color spaces
			bool linear = false;
			bool srgb = true;

			// Flags
			TextureUsage basic = .CopySrc | .CopyDst | .TextureBinding;
			TextureUsage attachment = basic | .RenderAttachment;
			TextureUsage storage = basic | .StorageBinding;
			TextureUsage all_flags = .CopyDst | .CopySrc | .RenderAttachment | .StorageBinding | .TextureBinding;

			(FeatureName, TextureSampleType, bool, uint8[2], uint8, TextureUsage, uint8) final;
			switch (format) {
			// Normal 8 bit textures
			case .R8Unorm: final = (native, float, linear, .(1, 1), 1, attachment, 1);
			case .R8Snorm: final = (native, float, linear, .(1, 1), 1, basic, 1);
			case .R8Uint: final = (native, uint, linear, .(1, 1), 1, attachment, 1);
			case .R8Sint: final = (native, sint, linear, .(1, 1), 1, attachment, 1);

			// Normal 16 bit textures
			case .R16Uint: final = (native, uint, linear, .(1, 1), 2, attachment, 1);
			case .R16Sint: final = (native, sint, linear, .(1, 1), 2, attachment, 1);
			case .R16Float: final = (native, float, linear, .(1, 1), 2, attachment, 1);
			case .RG8Unorm: final = (native, float, linear, .(1, 1), 2, attachment, 2);
			case .RG8Snorm: final = (native, float, linear, .(1, 1), 2, attachment, 2);
			case .RG8Uint: final = (native, uint, linear, .(1, 1), 2, attachment, 2);
			case .RG8Sint: final = (native, sint, linear, .(1, 1), 2, basic, 2);

			// Normal 32 bit textures
			case .R32Uint: final = (native, uint, linear, .(1, 1), 4, all_flags, 1);
			case .R32Sint: final = (native, sint, linear, .(1, 1), 4, all_flags, 1);
			case .R32Float: final = (native, nearest, linear, .(1, 1), 4, all_flags, 1);
			case .RG16Uint: final = (native, uint, linear, .(1, 1), 4, attachment, 2);
			case .RG16Sint: final = (native, sint, linear, .(1, 1), 4, attachment, 2);
			case .RG16Float: final = (native, float, linear, .(1, 1), 4, attachment, 2);
			case .RGBA8Unorm: final = (native, float, linear, .(1, 1), 4, all_flags, 4);
			case .RGBA8UnormSrgb: final = (native, float, srgb, .(1, 1), 4, attachment, 4);
			case .RGBA8Snorm: final = (native, float, linear, .(1, 1), 4, storage, 4);
			case .RGBA8Uint: final = (native, uint, linear, .(1, 1), 4, all_flags, 4);
			case .RGBA8Sint: final = (native, sint, linear, .(1, 1), 4, all_flags, 4);
			case .BGRA8Unorm: final = (native, float, linear, .(1, 1), 4, attachment, 4);
			case .BGRA8UnormSrgb: final = (native, float, srgb, .(1, 1), 4, attachment, 4);

			// Packed 32 bit textures
			case .RGB10A2Unorm: final = (native, float, linear, .(1, 1), 4, attachment, 4);
			//case .RG11B10float: final = (native, float, linear, .(1, 1), 4, basic, 3);

			// Packed 32 bit textures
			case .RG32Uint: final = (native, uint, linear, .(1, 1), 8, all_flags, 2);
			case .RG32Sint: final = (native, sint, linear, .(1, 1), 8, all_flags, 2);
			case .RG32Float: final = (native, nearest, linear, .(1, 1), 8, all_flags, 2);
			case .RGBA16Uint: final = (native, uint, linear, .(1, 1), 8, all_flags, 4);
			case .RGBA16Sint: final = (native, sint, linear, .(1, 1), 8, all_flags, 4);
			case .RGBA16Float: final = (native, float, linear, .(1, 1), 8, all_flags, 4);

			// Packed 32 bit textures
			case .RGBA32Uint: final = (native, uint, linear, .(1, 1), 16, all_flags, 4);
			case .RGBA32Sint: final = (native, sint, linear, .(1, 1), 16, all_flags, 4);
			case .RGBA32Float: final = (native, nearest, linear, .(1, 1), 16, all_flags, 4);

			// Depth-stencil textures
			case .Depth32Float: final = (native, depth, linear, .(1, 1), 4, attachment, 1);
			case .Depth24Plus: final = (native, depth, linear, .(1, 1), 4, attachment, 1);
			case .Depth24PlusStencil8: final = (native, depth, linear, .(1, 1), 4, attachment, 2);

			// Packed uncompressed
			case .RGB9E5Ufloat: final = (native, float, linear, .(1, 1), 4, basic, 3);

			// BCn compressed textures
			case .BC1RGBAUnorm: final = (bc, float, linear, .(4, 4), 8, basic, 4);
			case .BC1RGBAUnormSrgb: final = (bc, float, srgb, .(4, 4), 8, basic, 4);
			case .BC2RGBAUnorm: final = (bc, float, linear, .(4, 4), 16, basic, 4);
			case .BC2RGBAUnormSrgb: final = (bc, float, srgb, .(4, 4), 16, basic, 4);
			case .BC3RGBAUnorm: final = (bc, float, linear, .(4, 4), 16, basic, 4);
			case .BC3RGBAUnormSrgb: final = (bc, float, srgb, .(4, 4), 16, basic, 4);
			case .BC4RUnorm: final = (bc, float, linear, .(4, 4), 8, basic, 1);
			case .BC4RSnorm: final = (bc, float, linear, .(4, 4), 8, basic, 1);
			case .BC5RGUnorm: final = (bc, float, linear, .(4, 4), 16, basic, 2);
			case .BC5RGSnorm: final = (bc, float, linear, .(4, 4), 16, basic, 2);
			case .BC6HRGBUfloat: final = (bc, float, linear, .(4, 4), 16, basic, 3);
			//case .BC6HRGBSFloat: final = (bc, float, linear, .(4, 4), 16, basic, 3);
			case .BC7RGBAUnorm: final = (bc, float, linear, .(4, 4), 16, basic, 4);
			case .BC7RGBAUnormSrgb: final = (bc, float, srgb, .(4, 4), 16, basic, 4);

			// ETC compressed textures
			case .ETC2RGB8Unorm: final = (etc2, float, linear, .(4, 4), 8, basic, 3);
			case .ETC2RGB8UnormSrgb: final = (etc2, float, srgb, .(4, 4), 8, basic, 3);
			case .ETC2RGB8A1Unorm: final = (etc2, float, linear, .(4, 4), 8, basic, 4);
			case .ETC2RGB8A1UnormSrgb: final = (etc2, float, srgb, .(4, 4), 8, basic, 4);
			case .ETC2RGBA8Unorm: final = (etc2, float, linear, .(4, 4), 16, basic, 4);
			case .ETC2RGBA8UnormSrgb: final = (etc2, float, srgb, .(4, 4), 16, basic, 4);
			case .EACR11Unorm: final = (etc2, float, linear, .(4, 4), 8, basic, 1);
			case .EACR11Snorm: final = (etc2, float, linear, .(4, 4), 8, basic, 1);
			case .EACRG11Unorm: final = (etc2, float, linear, .(4, 4), 16, basic, 2);
			case .EACRG11Snorm: final = (etc2, float, linear, .(4, 4), 16, basic, 2);

			// ASTC compressed textures
			case .ASTC4x4Unorm: final = (astc_ldr, float, linear, .(4, 4), 16, basic, 4);
			case .ASTC4x4UnormSrgb: final = (astc_ldr, float, srgb, .(4, 4), 16, basic, 4);
			case .ASTC5x4Unorm: final = (astc_ldr, float, linear, .(5, 4), 16, basic, 4);
			case .ASTC5x4UnormSrgb: final = (astc_ldr, float, srgb, .(5, 4), 16, basic, 4);
			case .ASTC5x5Unorm: final = (astc_ldr, float, linear, .(5, 5), 16, basic, 4);
			case .ASTC5x5UnormSrgb: final = (astc_ldr, float, srgb, .(5, 5), 16, basic, 4);
			case .ASTC6x5Unorm: final = (astc_ldr, float, linear, .(6, 5), 16, basic, 4);
			case .ASTC6x5UnormSrgb: final = (astc_ldr, float, srgb, .(6, 5), 16, basic, 4);
			case .ASTC6x6Unorm: final = (astc_ldr, float, linear, .(6, 6), 16, basic, 4);
			case .ASTC6x6UnormSrgb: final = (astc_ldr, float, srgb, .(6, 6), 16, basic, 4);
			case .ASTC8x5Unorm: final = (astc_ldr, float, linear, .(8, 5), 16, basic, 4);
			case .ASTC8x5UnormSrgb: final = (astc_ldr, float, srgb, .(8, 5), 16, basic, 4);
			case .ASTC8x6Unorm: final = (astc_ldr, float, linear, .(8, 6), 16, basic, 4);
			case .ASTC8x6UnormSrgb: final = (astc_ldr, float, srgb, .(8, 6), 16, basic, 4);
			case .ASTC10x5Unorm: final = (astc_ldr, float, linear, .(10, 5), 16, basic, 4);
			case .ASTC10x5UnormSrgb: final = (astc_ldr, float, srgb, .(10, 5), 16, basic, 4);
			case .ASTC10x6Unorm: final = (astc_ldr, float, linear, .(10, 6), 16, basic, 4);
			case .ASTC10x6UnormSrgb: final = (astc_ldr, float, srgb, .(10, 6), 16, basic, 4);
			case .ASTC8x8Unorm: final = (astc_ldr, float, linear, .(8, 8), 16, basic, 4);
			case .ASTC8x8UnormSrgb: final = (astc_ldr, float, srgb, .(8, 8), 16, basic, 4);
			case .ASTC10x8Unorm: final = (astc_ldr, float, linear, .(10, 8), 16, basic, 4);
			case .ASTC10x8UnormSrgb: final = (astc_ldr, float, srgb, .(10, 8), 16, basic, 4);
			case .ASTC10x10Unorm: final = (astc_ldr, float, linear, .(10, 10), 16, basic, 4);
			case .ASTC10x10UnormSrgb: final = (astc_ldr, float, srgb, .(10, 10), 16, basic, 4);
			case .ASTC12x10Unorm: final = (astc_ldr, float, linear, .(12, 10), 16, basic, 4);
			case .ASTC12x10UnormSrgb: final = (astc_ldr, float, srgb, .(12, 10), 16, basic, 4);
			case .ASTC12x12Unorm: final = (astc_ldr, float, linear, .(12, 12), 16, basic, 4);
			case .ASTC12x12UnormSrgb: final = (astc_ldr, float, srgb, .(12, 12), 16, basic, 4);

			// Optional normalized 16-bit-per-channel formats
			/*case .R16Unorm: final = (norm16bit, float, linear, .(1, 1), 2, storage, 1);
			case .R16Snorm: final = (norm16bit, float, linear, .(1, 1), 2, storage, 1);
			case .Rg16Unorm: final = (norm16bit, float, linear, .(1, 1), 4, storage, 2);
			case .Rg16Snorm: final = (norm16bit, float, linear, .(1, 1), 4, storage, 2);
			case .Rgba16Unorm: final = (norm16bit, float, linear, .(1, 1), 8, storage, 4);
			case .Rgba16Snorm: final = (norm16bit, float, linear, .(1, 1), 8, storage, 4);*/

			default: final = default; // God help whoever uses this format
			}

			return .() {
				requiredFeatures = final.0,
				sampleType = final.1,
				blockDimensions = final.3,
				blockSize = final.4,
				components = final.6,
				srgb = final.2,
				guaranteedFormatFeatures = .() {
					allowedUsages = final.5,
					filterable = final.1 == .Float
				}
			};
		}

		extension Limits {
			public static Self Default() => .() {
				maxTextureDimension1D = 8192,
				maxTextureDimension2D = 8192,
				maxTextureDimension3D = 2048,
				maxTextureArrayLayers = 256,
				maxBindGroups = 4,
				maxDynamicUniformBuffersPerPipelineLayout = 8,
				maxDynamicStorageBuffersPerPipelineLayout = 4,
				maxSampledTexturesPerShaderStage = 16,
				maxSamplersPerShaderStage = 16,
				maxStorageBuffersPerShaderStage = 8,
				maxStorageTexturesPerShaderStage = 8,
				maxUniformBuffersPerShaderStage = 12,
				maxUniformBufferBindingSize = 64 << 10,
				maxStorageBufferBindingSize = 128 << 20,
				maxVertexBuffers = 8,
				maxVertexAttributes = 16,
				maxVertexBufferArrayStride = 2048,
				minUniformBufferOffsetAlignment = 256,
				minStorageBufferOffsetAlignment = 256,
				maxInterStageShaderComponents = 60,
				maxComputeWorkgroupStorageSize = 16352,
				maxComputeInvocationsPerWorkgroup = 256,
				maxComputeWorkgroupSizeX = 256,
				maxComputeWorkgroupSizeY = 256,
				maxComputeWorkgroupSizeZ = 64,
				maxComputeWorkgroupsPerDimension = 65535,
			};
		}
	}
}