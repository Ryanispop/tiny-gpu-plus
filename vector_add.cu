#include <stdio.h>


__global__ void vectorAdd(const float* A, const float* B, float* C, int N){
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx < N){
        C[idx] = A[idx] + B[idx];
    }
}

int main(){
    int N = 1024;

    size_t bytes = N * sizeof(float);

    float *hA, *hB, *hC;

    hA = (float*)malloc(bytes);
    hB = (float*)malloc(bytes);
    hC = (float*)malloc(bytes);

    for (int i = 0; i < N; i++){
        hA[i] = i;
        hB[i] = 2*i;

    }

    float *dA, *dB, *dC;

    cudaMalloc(&dA, bytes);
    cudaMalloc(&dB, bytes);
    cudaMalloc(&dC, bytes);

    cudaMemcpy(dA, hA, bytes, cudaMemcpyHostToDevice);
    cudaMemcpy(dB, hB, bytes, cudaMemcpyHostToDevice);
    int blockSize = 256;
    int gridSize = (N + blockSize - 1) / blockSize;

    vectorAdd<<<gridSize, blockSize>>>(dA, dB, dC, N);

    cudaMemcpy(hC, dC, bytes, cudaMemcpyDeviceToHost);

    printf("C[10] = %f\n", hC[10]);

    cudaFree(dA);
    cudaFree(dB);
    cudaFree(dC);


}