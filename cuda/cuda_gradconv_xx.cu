/*
*	This cuda routine allows one to compute the derivative wrt the point cloud 'x' of the derivative
*	wrt 'x' of the expression
*		K(x_i,y_j) @ b_j =  sum_j f( |x_i-y_j|^2 ) b_j
*	
*	
*	We're looking for the gradient with respect to x of
*	
*	< e, K(s,a,x,y,b) >  =  \sum_{i,j} f_s'( |x_i-y_j|^2 ) * < a_i, b_j > * 2 < e_i, x_i-y_j>,
*	
*	which is an N-by-D array g_i (i from 1 to N), where each line is equal to
*	
*	g_i  =  2* \sum_j < a_i, b_j > * [                       f_s'(  |x_i-y_j|^2 ) * e_i
*                                    + 2* < x_i-y_j, e_i > * f_s''( |x_i-y_j|^2 ) * (x_i-y_j) ]
* 
*	We will compute this sum over the index 'j' on the GPU, with 'one thread' = 'one index i'.
*	Data will be stored as follow:
*	  - e_i in the thread memory
* 	  - a_i in the thread memory
*	  - x_i in the thread memory
*	  - y_j in the SharedData
*	  - b_j in the SharedData (beta_j, really)
* 
* 
* Author : Jean Feydy, heavily based on the work of Joan Glaunès and Benjamin Charlier.
* 
*/

#include <stdio.h>
#include <assert.h>
#include <cuda.h>
#include "radial_kernels.cx"


#define UseCudaOnDoubles USE_DOUBLE_PRECISION

///////////////////////////////////////
/////////// CUDA KERNEL ///////////////
///////////////////////////////////////


template < typename TYPE, int DIMPOINT, int DIMVECT > // Typically, float32, D, E
__global__ void GaussGpuGradConvXXOnDevice(TYPE ooSigma2, // 1/sigma^2
		TYPE *e,                                   // N-by-D array
		TYPE *alpha, TYPE *x, TYPE *y, TYPE *beta, // N-by-E, N-by-D, M-by-D, M-by-E arrays
		TYPE *gamma,                               // Output variable, N-by-D (same as x)
		int nx, int ny)
{
    // Thread kernel:
    // Computation of gamma_i = \partial_{x_i} < e_i, \partial_{x_i} < alpha_i, sum_j k(x_i,y_j)*beta_j > >
    //
    //                        = 2* \sum_j < a_i, b_j > * [                       f_s'(  |x_i-y_j|^2 ) * e_i
    //                                                   + 2* < x_i-y_j, e_i > * f_s''( |x_i-y_j|^2 ) * (x_i-y_j) ]
    // for index i given by thread id.
    
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    // the following line does not work with nvcc 3.0 (it is a bug; it works with anterior and posterior versions)
    // extern __shared__ TYPE SharedData[];  // shared data will contain x and alpha data for the block
    // here is the bug fix (see http://forums.nvidia.com/index.php?showtopic=166905)
    extern __shared__ char SharedData_char[];
    TYPE* const SharedData = reinterpret_cast<TYPE*>(SharedData_char);
    // end of bug fix
    
    // One thread = One line = One x_i + One a_i + One e_i + One gamma_i + a whole bunch of "y_j", "b_j".
    TYPE ei[DIMPOINT], alphai[DIMPOINT], xi[DIMPOINT], xmy[DIMPOINT], gammai[DIMPOINT];
    if(i<nx) { // we will compute gammai only if i is in the range
        for(int k=0; k<DIMPOINT; k++)
            ei[k]     =     e[i*DIMPOINT+k]; // load e_i from device global memory
        for(int k=0; k<DIMPOINT; k++)
            xi[k]     =     x[i*DIMPOINT+k]; // load x_i from device global memory
        for(int k=0; k<DIMVECT; k++)
            alphai[k] = alpha[i*DIMVECT+k];  // load a_i from device global memory
        for(int k=0; k<DIMPOINT; k++)    // output : N-by-D : DIMPOINT
            gammai[k] = 0.0f;            // Make sure to put to zero the output array 
    }

    // Here, we use a tiled matrix decomposition. See cuda_conv.cu for graphs and explanations.
    
    for(int jstart = 0, tile = 0; jstart < ny; jstart += blockDim.x, tile++) {

        // Load data in Shared memory -----------------------------------------------------------
        int j = tile * blockDim.x + threadIdx.x; // Current column
        // We load yj and betaj from device global memory...
        if(j<ny) { // ...only if j<ny (we may be in the last columns of the last tile...)
            // Pretty uneasy to read : we store yj and betaj interleaved, for better performance
            // SharedData = "[ y0, b0, y1, b1, y2, b2, ... ]"
            int inc = DIMPOINT + DIMVECT; // Size of a  [yj, bj] block
            for(int k=0; k<DIMPOINT; k++)
                SharedData[threadIdx.x*inc+k]          =    y[j*DIMPOINT+k];
            for(int k=0; k<DIMVECT; k++)
                SharedData[threadIdx.x*inc+DIMPOINT+k] = beta[j*DIMVECT+k];
        }
        __syncthreads();
        // At this point :
        // - e_i, a_i, x_i sit in the thread memory
        // - [y_N, ..., y_{N+blockDim.x}] and [b_N, ..., b_{N+blockDim.x}] sit
        //   in the SharedData, where [N : N+blockDim.x] is the tile span.
        // - the output line gamma_i is in the thread memory, and contains the result
        //   of the summation over the previous tiles.
      
        
        // Map-Reduction loop -------------------------------------------------------------------
        // We can now proceed to the "tiled" matrix product, where one line = one thread.
        if(i<nx) // we compute gammai only if i is in the range
        {
            TYPE *yj, *betaj;                  // As y_j and beta_j are interleaved...
            yj      = SharedData;              // We'll on some cute pointer arithmetics!
            betaj   = SharedData + DIMPOINT;
            int inc = DIMPOINT   + DIMVECT;    // The increment, size of a [y_j,b_j] block.
            
            for(int jrel = 0; jrel < blockDim.x && jrel<ny-jstart; jrel++, yj+=inc, betaj+=inc) {
                // Reduction loop over j : we're getting to the maths ***************************
                // Remember: we're computing 
                //    g_i  = 2* \sum_j < a_i, b_j > * [                       f_s'(  |x_i-y_j|^2 ) * e_i
                //                                    + 2* < e_i ,x_i-y_j > * f_s''( |x_i-y_j|^2 ) * (x_i-y_j) ]

                TYPE r2 = 0.0f, ei_s_xmy = 0.0f, ai_s_bj = 0.0f; // NEVER forget to initialize your accumulation variables
                // Compute x_i-y_j and its squared norm:
                for(int k=0; k<DIMPOINT; k++) {
                    xmy[k]  =  xi[k]-yj[k];
                    r2     += xmy[k]*xmy[k];
                }
                // Compute < e_i, x_i-y_j> :
                for(int k=0; k<DIMPOINT; k++) // Scalar product between POINTS.
                    ei_s_xmy += ei[k]*xmy[k];
                // Compute < a_i, b_j> :
                for(int k=0; k<DIMVECT; k++)  // Scalar product between VECTORS.
                    ai_s_bj  += alphai[k]* betaj[k];
                // Scalar factor for the first line,   "2* <a_i,b_j> * f_s'( |x_i-y_j|^2 )"
                TYPE s1 =  2.0f * ai_s_bj *            GaussFp(  r2 , ooSigma2 );
                // Scalar factor for the second line,  "4* <a_i,b_j> * < e_i, x_i-y_j > * f_s''( |x_i-y_j|^2 )"
                TYPE s2 =  4.0f * ai_s_bj * ei_s_xmy * GaussFpp( r2 , ooSigma2 );
                
                for(int k=0; k<DIMPOINT; k++)    // Output: N-by-D
                    gammai[k] += s1 * ei[k] + s2 * xmy[k];  // Final increment
                // ******************************************************************************
            }
        }
        // Once the loop is over, the current tiled matrix product has been reduced to gamma_i
        __syncthreads();  // So make sure that no one's left behind...
        // And move on to the next tile.
    }

    // Save the result in global memory.
    if(i<nx)
        for(int k=0; k<DIMPOINT; k++)        // Remember: the output, here, is N-by-D (-> DIMPOINT)
            gamma[i*DIMPOINT+k] = gammai[k];
}

//////////////////////////////////////////////////////
/////////// CPU -> GPU -> CPU routines ///////////////
//////////////////////////////////////////////////////


#if !(UseCudaOnDoubles) 
extern "C" int GaussGpuGradConvXX(float ooSigma2,               // 1 / sigma^2
								float* e_h,                     // N-by-D array (same as x)
								float* alpha_h, float* x_h,     // N-by-E, N-by-D arrays
								float* y_h,     float* beta_h,  // M-by-D, M-by-E arrays
								float* gamma_h,                 // Output: N-by-D (same as x)
								int dimPoint, int dimVect, int nx, int ny){ // D, E, N, M

	// Data on the device.
	float* e_d;
	float* alpha_d;
	float* x_d;
	float* y_d;
	float* beta_d;
	float* gamma_d;

	// Allocate arrays on device.
	cudaMalloc((void**)&e_d,     sizeof(float)*(nx*dimPoint));
	cudaMalloc((void**)&alpha_d, sizeof(float)*(nx*dimVect ));
	cudaMalloc((void**)&x_d,     sizeof(float)*(nx*dimPoint));
	cudaMalloc((void**)&y_d,     sizeof(float)*(ny*dimPoint));
	cudaMalloc((void**)&beta_d,  sizeof(float)*(ny*dimVect ));
	cudaMalloc((void**)&gamma_d, sizeof(float)*(nx*dimPoint)); // Output: N-by-D (same as x)

	// Send data from host to device.
	cudaMemcpy(e_d,     e_h,     sizeof(float)*(nx*dimPoint), cudaMemcpyHostToDevice);
	cudaMemcpy(alpha_d, alpha_h, sizeof(float)*(nx*dimVect ), cudaMemcpyHostToDevice);
	cudaMemcpy(x_d,     x_h,     sizeof(float)*(nx*dimPoint), cudaMemcpyHostToDevice);
	cudaMemcpy(y_d,     y_h,     sizeof(float)*(ny*dimPoint), cudaMemcpyHostToDevice);
	cudaMemcpy(beta_d,  beta_h,  sizeof(float)*(ny*dimVect ), cudaMemcpyHostToDevice);

	// compute on device.
	dim3 blockSize;
	blockSize.x = CUDA_BLOCK_SIZE; // number of threads in each block
	dim3 gridSize;
	gridSize.x =  nx / blockSize.x + (nx%blockSize.x==0 ? 0 : 1);

	// Copy-paste templating, allowing us to pass the DIMPOINT and DIMVECT at compilation time : 
	if(     dimPoint==1 && dimVect==1)
		GaussGpuGradConvXXOnDevice<float,1,1><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(float)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==2 && dimVect==1)
		GaussGpuGradConvXXOnDevice<float,2,1><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(float)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==3 && dimVect==1)
		GaussGpuGradConvXXOnDevice<float,3,1><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(float)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==4 && dimVect==1)
		GaussGpuGradConvXXOnDevice<float,4,1><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(float)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==2 && dimVect==2)
		GaussGpuGradConvXXOnDevice<float,2,2><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(float)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==3 && dimVect==3)
		GaussGpuGradConvXXOnDevice<float,3,3><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(float)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==4 && dimVect==4)
		GaussGpuGradConvXXOnDevice<float,4,4><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(float)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else
	{
		printf("GaussGpuGradConvXX error: dimensions of Gauss kernel not implemented in cuda\nYou probably just need a copy-paste in the conda_gradconv_xx.cu file !");
		cudaFree(e_d);
		cudaFree(alpha_d);
		cudaFree(x_d);
		cudaFree(y_d);
		cudaFree(beta_d);
		cudaFree(gamma_d);
		return(-1);
	}

	// block until the device has completed
	cudaThreadSynchronize();

	// Send data from device to host.
	cudaMemcpy(gamma_h, gamma_d, sizeof(float)*(nx*dimPoint),cudaMemcpyDeviceToHost); // Output: N-by-D (same as x)

	// Free memory.
	cudaFree(e_d);
	cudaFree(alpha_d);
	cudaFree(x_d);
	cudaFree(y_d);
	cudaFree(beta_d);
	cudaFree(gamma_d);

	return 0;
}

#else
//////////////////////////////////////////////////////////////
extern "C" int GaussGpuGradConvXX(double ooSigma2,               // 1 / sigma^2
								double* e_h,                     // N-by-D array (same as x)
								double* alpha_h, double* x_h,    // N-by-E, N-by-D arrays
								double* y_h,     double* beta_h, // M-by-D, M-by-E arrays
								double* gamma_h,                 // Output: N-by-D (same as x)
								int dimPoint, int dimVect, int nx, int ny){ // D, E, N, M

	// Data on the device.
	double* e_d;
	double* alpha_d;
	double* x_d;
	double* y_d;
	double* beta_d;
	double* gamma_d;

	// Allocate arrays on device.
	cudaMalloc((void**)&e_d,     sizeof(double)*(nx*dimPoint));
	cudaMalloc((void**)&alpha_d, sizeof(double)*(nx*dimVect ));
	cudaMalloc((void**)&x_d,     sizeof(double)*(nx*dimPoint));
	cudaMalloc((void**)&y_d,     sizeof(double)*(ny*dimPoint));
	cudaMalloc((void**)&beta_d,  sizeof(double)*(ny*dimVect ));
	cudaMalloc((void**)&gamma_d, sizeof(double)*(nx*dimPoint)); // Output: N-by-D (same as x)

	// Send data from host to device.
	cudaMemcpy(e_d,     e_h,     sizeof(double)*(nx*dimPoint), cudaMemcpyHostToDevice);
	cudaMemcpy(alpha_d, alpha_h, sizeof(double)*(nx*dimVect ), cudaMemcpyHostToDevice);
	cudaMemcpy(x_d,     x_h,     sizeof(double)*(nx*dimPoint), cudaMemcpyHostToDevice);
	cudaMemcpy(y_d,     y_h,     sizeof(double)*(ny*dimPoint), cudaMemcpyHostToDevice);
	cudaMemcpy(beta_d,  beta_h,  sizeof(double)*(ny*dimVect ), cudaMemcpyHostToDevice);

	// compute on device.
	dim3 blockSize;
	blockSize.x = CUDA_BLOCK_SIZE; // number of threads in each block
	dim3 gridSize;
	gridSize.x =  nx / blockSize.x + (nx%blockSize.x==0 ? 0 : 1);

	// Copy-paste templating, allowing us to pass the DIMPOINT and DIMVECT at compilation time : 
	if(     dimPoint==1 && dimVect==1)
		GaussGpuGradConvXXOnDevice<double,1,1><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(double)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==2 && dimVect==1)
		GaussGpuGradConvXXOnDevice<double,2,1><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(double)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==3 && dimVect==1)
		GaussGpuGradConvXXOnDevice<double,3,1><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(double)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==4 && dimVect==1)
		GaussGpuGradConvXXOnDevice<double,4,1><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(double)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==2 && dimVect==2)
		GaussGpuGradConvXXOnDevice<double,2,2><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(double)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==3 && dimVect==3)
		GaussGpuGradConvXXOnDevice<double,3,3><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(double)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else if(dimPoint==4 && dimVect==4)
		GaussGpuGradConvXXOnDevice<double,4,4><<<gridSize,blockSize,blockSize.x*(dimPoint+dimVect)*sizeof(double)>>>
			(ooSigma2, e_d, alpha_d, x_d, y_d, beta_d, gamma_d, nx, ny);
	else
	{
		printf("GaussGpuGradConvXX error: dimensions of Gauss kernel not implemented in cuda\nYou probably just need a copy-paste in the conda_gradconv_xx.cu file !");
		cudaFree(e_d);
		cudaFree(alpha_d);
		cudaFree(x_d);
		cudaFree(y_d);
		cudaFree(beta_d);
		cudaFree(gamma_d);
		return(-1);
	}

	// block until the device has completed
	cudaThreadSynchronize();

	// Send data from device to host.
	cudaMemcpy(gamma_h, gamma_d, sizeof(double)*(nx*dimPoint),cudaMemcpyDeviceToHost); // Output: N-by-D (same as x)

	// Free memory.
	cudaFree(e_d);
	cudaFree(alpha_d);
	cudaFree(x_d);
	cudaFree(y_d);
	cudaFree(beta_d);
	cudaFree(gamma_d);

	return 0;
}
#endif

void ExitFcn(void)
{
    cudaDeviceReset();
}
