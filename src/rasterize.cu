/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya
 * @date      2012-2015
 * @copyright University of Pennsylvania & STUDENT
 */

#include "rasterize.h"

#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <thrust/random.h>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>

#include <util/checkCUDAError.h>
#include "rasterizeTools.h"
#include "sceneStructs.h"

/************************* Struct Definitions *********************************/

struct VertexIn {
    glm::vec3 pos;
    glm::vec3 nor;
    glm::vec3 col;
};
struct VertexOut {
    glm::vec3 pos;
    glm::vec3 nor;
    glm::vec3 col;
};
struct Triangle {
    glm::vec3 pos[3];
    glm::vec3 nor[3];
    glm::vec3 col[3];
};
struct Fragment {
    glm::vec3 color;
};

static int width = 0;
static int height = 0;
static int bufIdxSize = 0;
static int vertCount = 0;

static int       *dev_bufIdx       = NULL;
static VertexIn  *dev_bufVertexIn  = NULL;
static VertexOut *dev_bufVertexOut = NULL;
static Triangle  *dev_primitives   = NULL;
static Fragment  *dev_depthbuffer  = NULL;
static glm::vec3 *dev_framebuffer  = NULL;

__device__ void printVec3(glm::vec3 v) {
    printf("(%f, %f, %f)\n", v.x, v.y, v.z);
}

/************************* Output to Screen ***********************************/

/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__ void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        glm::vec3 color;
        color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

/**
 * Writes fragment colors to the framebuffer
 */
__global__ void render(int w, int h, Fragment *depthbuffer,
        glm::vec3 *framebuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        framebuffer[index] = depthbuffer[index].color;
    }
}

/************************* Initialization *************************************/

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
    width = w;
    height = h;

    cudaFree(dev_depthbuffer);
    cudaMalloc(&dev_depthbuffer,    width * height * sizeof(Fragment));
    cudaMemset( dev_depthbuffer, 0, width * height * sizeof(Fragment));

    cudaFree(dev_bufVertexOut);
    cudaMalloc(&dev_bufVertexOut,    width * height * sizeof(VertexOut));
    cudaMemset( dev_bufVertexOut, 0, width * height * sizeof(VertexOut));

    cudaFree(dev_framebuffer);
    cudaMalloc(&dev_framebuffer,    width * height * sizeof(glm::vec3));
    cudaMemset( dev_framebuffer, 0, width * height * sizeof(glm::vec3));
    checkCUDAError("rasterizeInit");
}

/**
 * Set all of the buffers necessary for rasterization.
 */
void rasterizeSetBuffers(
        int _bufIdxSize, int *bufIdx,
        int _vertCount, float *bufPos, float *bufNor, float *bufCol) {
    bufIdxSize = _bufIdxSize;
    vertCount = _vertCount;

    cudaFree(dev_bufIdx);
    cudaMalloc(&dev_bufIdx, bufIdxSize * sizeof(int));
    cudaMemcpy(dev_bufIdx, bufIdx, bufIdxSize * sizeof(int), cudaMemcpyHostToDevice);

    VertexIn *bufVertexIn = new VertexIn[_vertCount];
    for (int i = 0; i < vertCount; i++) {
        int j = i * 3;
        bufVertexIn[i].pos = glm::vec3(bufPos[j + 0], bufPos[j + 1], bufPos[j + 2]);
        bufVertexIn[i].nor = glm::vec3(bufNor[j + 0], bufNor[j + 1], bufNor[j + 2]);
        bufVertexIn[i].col = glm::vec3(bufCol[j + 0], bufCol[j + 1], bufCol[j + 2]);
    }
    cudaFree(dev_bufVertexIn);
    cudaMalloc(&dev_bufVertexIn, vertCount * sizeof(VertexIn));
    cudaMemcpy( dev_bufVertexIn, bufVertexIn, vertCount * sizeof(VertexIn), cudaMemcpyHostToDevice);

    cudaFree(dev_primitives);
    cudaMalloc(&dev_primitives, vertCount / 3 * sizeof(Triangle));
    cudaMemset(dev_primitives, 0, vertCount / 3 * sizeof(Triangle));

    checkCUDAError("rasterizeSetBuffers");
}

/************************* Rasterization Pipeline *****************************/

__global__ void clearDepthBuffer(int width, int height, Fragment *depthbuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < width && y < height) {
        int index = x + (y * width);

        depthbuffer[index] = (Fragment) { glm::vec3(.1, .1, .1) };
    }
}

// Applies vertex transformations (from given model-view-projection matrix)
__global__ void vertexShader(int vertcount, VertexIn *verticesIn,
        VertexOut *verticesOut, glm::mat4 mvp) {
    int k = (blockIdx.x * blockDim.x) + threadIdx.x;

    if (k < vertcount) {
        VertexIn vin = verticesIn[k];

        VertexOut vo;
        vo.pos = multiplyMV(mvp, glm::vec4(vin.pos, 1));
        vo.nor = vin.nor;
        vo.col = vin.col;
        verticesOut[k] = vo;
    }
}

// Assembles sets of 3 vertices into Triangles.
__global__ void assemblePrimitives(int primitivecount, VertexOut *vertices,
        int *indices, Triangle *primitives) {
    int k = (blockIdx.x * blockDim.x) + threadIdx.x;

    if (k < primitivecount) {
        VertexOut v[3];
        v[0] = vertices[indices[k*3  ]];
        v[1] = vertices[indices[k*3+1]];
        v[2] = vertices[indices[k*3+2]];

        Triangle tri;
        tri.pos[0] = v[0].pos;
        tri.pos[1] = v[1].pos;
        tri.pos[2] = v[2].pos;

        tri.nor[0] = v[0].nor;
        tri.nor[1] = v[1].nor;
        tri.nor[2] = v[2].nor;

        tri.col[0] = v[0].col;
        tri.col[1] = v[1].col;
        tri.col[2] = v[2].col;
        primitives[k] = tri;
    }
}

__device__ void shadeFragment(float x, float y, float width, float height,
        Triangle tri, glm::vec3 light,
        Fragment *fragments) {

    glm::vec3 bary = calculateBarycentricCoordinate(tri.pos, glm::vec2(x, y));

    if (isBarycentricCoordInBounds(bary)) {
        glm::vec3 pos = glm::vec3(fromNDC(x, y, width, height), getZAtCoordinate(bary, tri.pos));
        int pixelIndex = pos.x + (pos.y * width);

        glm::vec3 norm = barycentricInterpolate(tri.nor, bary);
        fragments[pixelIndex] = (Fragment) { norm };
    }
}

// Scans across triangles to generate primitives (pixels).
__global__ void scanline(int width, int height, int tricount,
        Triangle *primitives, Fragment *fragments, glm::vec3 light) {
    int k = (blockIdx.x * blockDim.x) + threadIdx.x;

    if (k < tricount) {
        Triangle tri = primitives[k];

        float ystep = 2.f / height;
        float xstep = 2.f / width;

        AABB bb = getAABBForTriangle(tri.pos);

        float ymin = (int) (bb.min.y / ystep) * ystep;
        float xmin = (int) (bb.min.x / xstep) * xstep;
        for (float y = ymin; y < bb.max.y; y += ystep) {
            for (float x = xmin; x < bb.max.x; x += xstep) {
                shadeFragment(x, y, width, height, tri, light, fragments);
            }
        }
    }
}

/**
 * Perform rasterization.
 */
void rasterize(uchar4 *pbo) {
    int sideLength2d = 8;
    dim3 blockSize2d(sideLength2d, sideLength2d);
    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1,
                      (height - 1) / blockSize2d.y + 1);

    int tricount = bufIdxSize / 3;

    int sideLength1d = 16;
    dim3 blockSize1d(sideLength1d);
    dim3 vertBlockCount((vertCount + sideLength1d - 1) / sideLength1d);
    dim3 triBlockCount((tricount + sideLength1d - 1) / sideLength1d);

    Camera c;
    c.position = glm::vec3(0, 3, -10);
    c.view = glm::vec3(0, 0, 1);
    c.up = glm::vec3(0, -1, 0);
    c.light = glm::vec3(0, 4, 0);
    c.fovy = glm::radians(45);

    glm::mat4 model = glm::mat4(1.f);
    glm::mat4 view = glm::lookAt(c.position, c.view, c.up);
    glm::mat4 persp = glm::perspective(45.f, 1.f, .1f, 100.f);
    glm::mat4 mvp = persp * view * model;

    clearDepthBuffer<<<blockCount2d, blockSize2d>>>(width, height, dev_depthbuffer);
    checkCUDAError("scan");

    vertexShader<<<vertBlockCount, blockSize1d>>>( vertCount,
            dev_bufVertexIn, dev_bufVertexOut, mvp);
    checkCUDAError("scan");

    // VertexOut -> Triangle
    assemblePrimitives<<<triBlockCount, blockSize1d>>>(tricount,
            dev_bufVertexOut, dev_bufIdx, dev_primitives);
    checkCUDAError("rasterize");

    // Triangle -> Fragment
    scanline<<<triBlockCount, blockSize1d>>>(width, height, tricount,
            dev_primitives, dev_depthbuffer, c.light);
    checkCUDAError("rasterize");

    // Copy depthbuffer colors into framebuffer
    render<<<blockCount2d, blockSize2d>>>(width, height, dev_depthbuffer, dev_framebuffer);
    // Copy framebuffer into OpenGL buffer for OpenGL previewing
    sendImageToPBO<<<blockCount2d, blockSize2d>>>(pbo, width, height, dev_framebuffer);
    checkCUDAError("rasterize");
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {
    cudaFree(dev_bufIdx);
    dev_bufIdx = NULL;

    cudaFree(dev_bufVertexOut);
    dev_bufVertexOut = NULL;

    cudaFree(dev_bufVertexIn);
    dev_bufVertexIn = NULL;

    cudaFree(dev_primitives);
    dev_primitives = NULL;

    cudaFree(dev_depthbuffer);
    dev_depthbuffer = NULL;

    cudaFree(dev_framebuffer);
    dev_framebuffer = NULL;

    checkCUDAError("rasterizeFree");
}
