#include "core/reductions/reduction.h"

using namespace keops;

/////////////////////////
// Convolutions on Cpu //
/////////////////////////

#include "core/CpuConv.cpp"

extern "C" int CpuReduc(int nx, int ny, __TYPE__* gamma, __TYPE__** args) {
    return Eval<F,CpuConv>::Run(nx, ny, gamma, args);
}


//////////////////////////////////////
// Convolutions on Cpu, with ranges //
//////////////////////////////////////

#include "core/CpuConv_ranges.cpp"

extern "C" int CpuReduc_ranges(int nx, int ny, int nbatchdims, int *shapes, int nranges_x, int nranges_y, __INDEX__ **castedranges, __TYPE__* gamma, __TYPE__** args) {
    return Eval<F,CpuConv_ranges>::Run(nx, ny, nbatchdims, shapes, nranges_x, nranges_y, castedranges, gamma, args);
}

