/**
* 
* Matrix Multiplication - CUDA for GPUs
*
* CS3210
*
**/
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <sys/time.h>
#include <assert.h>

#define BLOCK_SIZE 16

int size;

typedef struct
{
int width;
int height;
int stride;
float ** element;
} matrix;


long long wall_clock_time()
{
#ifdef __linux__
    struct timespec tp;
    clock_gettime(CLOCK_REALTIME, &tp);
    return (long long)(tp.tv_nsec + (long long)tp.tv_sec * 1000000000ll);
#else
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long long)(tv.tv_usec * 1000 + (long long)tv.tv_sec * 1000000000ll);
#endif
}

/**
* Allocates memory for a matrix of size SIZE
* The memory is allocated row-major order, i.e. 
*  elements from the same row are allocated at contiguous 
*  memory addresses.
**/
void allocate_matrix(matrix* m)
{
    int i;
    cudaError_t rc;
    
    m->width = size;
    m->height = size;
    m->stride = size;

    // allocate array for all the rows
    rc = cudaMallocManaged((void**)&(m->element), sizeof(float*) * size);
    if (rc != cudaSuccess) {
        fprintf(stderr, "CUDA error: %s\n", cudaGetErrorString(rc));
        exit(1);
    }
    
    // allocate all matrix elements in one array of continuous addresses
    float* array;
    rc = cudaMallocManaged((void**)&array, sizeof(float) * size * size);
    if (rc != cudaSuccess) {
        fprintf(stderr, "CUDA error: %s\n", cudaGetErrorString(rc));
        exit(1);
    }

    // allocate an array for each row of the matrix
    for (i = 0; i < size; i++) {
        m->element[i] = &(array[i * size]);
    }
}

/**
* Free the memory allocated for a matrix.
**/
void free_matrix(matrix* m) {
    cudaFree(m->element[0]);
    cudaFree(m->element);
}

/**
* Initializes the elements of the matrix with
* random values between 0 and 9
**/
void init_matrix(matrix m)
{
    int i, j;
    
    for (i = 0; i < size; i++)
        for (j = 0; j < size; j++)
        {
            m.element[i][j] = rand() % 10;
        }
}

/**
* Initializes the elements of the matrix with
* element 0.
**/
void init_matrix_zero(matrix m)
{
    int i, j;
    
    for (i = 0; i < size; i++)
        for (j = 0; j < size; j++)
        {
            m.element[i][j] = 0.0;
        }
}

/**
* Get element  at row, col of sub matrix
*/
__device__ float get_element(const matrix a, int row, int col) {
    return a->element[0][row * a.stride + col];
}

/**
* Set element at row, col of sub matrix
*/
__device__ void set_element(const matrix a, int row, int col, float value) {
    a->element[0][row * a.stride + col] = value;
}

__device__ matrix get_sub_matrix(matrix a, int row, int col) {
    matrix a_sub;
    a_sub.width = size;
    a_sub.width = size;
    a_sub.stride = a.stride;
    a_sub.element = &a.element[a.stride * BLOCK_SIZE * row][BLOCK_SIZE * col];
}

/**
* Multiplies matrix @a with matrix @b storing
* the result in matrix @result
* 
* The multiplication algorithm is the O(n^3) 
* algorithm
*/
void mm(matrix a, matrix b, matrix result)
{
    int i, j, k;
    
    // Do the multiplication
    for (i = 0; i < size; i++)
        for (j = 0; j < size; j++)
            for(k = 0; k < size; k++)
                result.element[i][j] += a.element[i][k] * b.element[k][j];
}

/**
* Each kernel computes the result element (i,j).
*/
__global__ void mm_kernel(matrix a, matrix b, matrix result, int size)
{
    // index in the original matric
    int g_row = blockIdx.x * blockDim.x + threadIdx.x; 
    int g_col = blockIdx.y * blockDim.y + threadIdx.y;
    int m, e;

    if (i >= size || j >= size)
        return;

    // block index
    int block_row = blockIdx.x;
    int block_col = blockIdx.y;

    float result_value = 0;
    // thread index
    int row = threadIdx.x;
    int col = threadIdx.y;

    int num_block = (a.width + BLOCK_SIZE - 1) / BLOCK_SIZE);
    for (m = 0; m < num_block; m++) {
        matrix a_sub = get_sub_matrix(a, block_row, m);
        matrix b_sub = get_sub_matrix(b, m, block_col);

        // Shared memory to store a_sub and b_sub
        __shared__ float a_s[BLOCK_SIZE][BLOCK_SIZE];
        __shared__ float b_s[BLOCK_SIZE][BLOCK_SIZE];

        a_s[row][col] = get_element(a_sub, row, col);
        b_s[row][col] = get_element(a_sub, row, col);
        // Synchronize to make sure the sub-matrices are loaded
        // before starting the computation
        __syncthreads();

        // Multiply a_sub and b_sub together
        for (e = 0; e < BLOCK_SIZE; ++e) {
            result_value += a_s[row][e] * b_s[e][col];
            // Synchronize to make sure that the preceding computation is done
            // before loading two new sub-matrices of A and B in the next iteration
            __syncthreads();
        }
    }

    result[g_row][g_col] = result_value;
}

void print_matrix(matrix m)
{
    int i, j;
    
    for (i = 0; i < size; i++)
    {
        printf("row %4d: ", i);
        for (j = 0; j < size; j++)
            printf("%6.2f  ", m.element[i][j]);
        printf("\n");
    }
}



void work()
{
    matrix a, b, result1, result2;
    long long before, after;
    int correct, i, j, dim;
    cudaError_t rc;

    // Allocate memory for matrices
    allocate_matrix(&a);
    allocate_matrix(&b);
    allocate_matrix(&result1);
    allocate_matrix(&result2);	

    // Initialize matrix elements
    init_matrix(a);
    init_matrix(b);

    // Perform sequential matrix multiplication
    before = wall_clock_time();
    mm(a, b, result1);
    after = wall_clock_time();
        fprintf(stderr, "Matrix multiplication on CPU took %1.2f seconds\n", ((float)(after - before))/1000000000);

    // Perform CUDA matrix  multiplication
    dim3 block(32, 32);			// a block of 32 x 32 CUDA threads
    dim = (size % 32 == 0) ? size / 32 : size / 32 + 1; 
    dim3 grid(dim, dim);	// a grid of CUDA thread blocks
    before = wall_clock_time();
    mm_kernel<<<grid, block>>>(a, b, result2, size);
    cudaDeviceSynchronize();
    after = wall_clock_time();
    fprintf(stderr, "Matrix multiplication on GPU took %1.2f seconds\n", ((float)(after - before))/1000000000);

    // was there any error?
        rc = cudaGetLastError();
        if (rc != cudaSuccess)
                printf("Last CUDA error %s\n", cudaGetErrorString(rc));

    // Compare the results
    correct = 1;
    for (i = 0; correct && i < size; i++)
        for (j = 0; j < size; j++)
            if (result1.element[i][j] != result2.element[i][j]) {
                correct = 0;
                break;
            }

    if (correct)
        printf("The result matrices are identical!\n");
    else
        printf("Difference in result matrices at element (%d, %d)!\n", i, j);

    free_matrix(&a);
    free_matrix(&b);
    free_matrix(&result1);
    free_matrix(&result2);
}


int main(int argc, char ** argv)
{
    srand(0); 

    printf("Usage: %s <size>\n", argv[0]);
    
    if (argc >= 2)
        size = atoi(argv[1]);
    else
        size = 1024;
        
    fprintf(stderr,"Sequential matrix multiplication of size %d\n", size);
    
    // Multiply the matrices
    work();

    return 0;
}
