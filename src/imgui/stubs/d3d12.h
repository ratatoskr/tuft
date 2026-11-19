// Stand-in for <d3d12.h>, only for translate-c on ImGui's DX12 header.
#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct ID3D12Device ID3D12Device;
typedef struct ID3D12CommandQueue ID3D12CommandQueue;
typedef struct ID3D12DescriptorHeap ID3D12DescriptorHeap;
typedef struct ID3D12GraphicsCommandList ID3D12GraphicsCommandList;
typedef struct D3D12_CPU_DESCRIPTOR_HANDLE { size_t ptr; } D3D12_CPU_DESCRIPTOR_HANDLE;
typedef struct D3D12_GPU_DESCRIPTOR_HANDLE { uint64_t ptr; } D3D12_GPU_DESCRIPTOR_HANDLE;