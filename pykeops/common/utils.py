import fcntl
import functools
import importlib.util
import os
import shutil

import pykeops.config

c_type = dict(float16="half2", float32="float", float64="double")


def module_exists(dllname):
    spec = importlib.util.find_spec(dllname)
    return (spec is not None)


def axis2cat(axis):
    """
    Axis is the dimension to sum (the pythonic way). Cat is the dimension that
    remains at the end (the Keops way).
    :param axis: 0 or 1
    :return: cat: 1 or 0
    """
    if axis in [0, 1]:
        return (axis + 1) % 2
    else:
        raise ValueError("Axis should be 0 or 1.")


def cat2axis(cat):
    """
    Axis is the dimension to sum (the pythonic way). Cat is the dimension that
    remains at the end (the Keops way).
    :param cat: 0 or 1
    :return: axis: 1 or 0
    """
    if cat in [0, 1]:
        return (cat + 1) % 2
    else:
        raise ValueError("Category should be Vi or Vj.")


class FileLock:
    def __init__(self, fd, op=fcntl.LOCK_EX):
        self.fd = fd
        self.op = op

    def __enter__(self):
        fcntl.flock(self.fd, self.op)
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        fcntl.flock(self.fd, fcntl.LOCK_UN)


def create_and_lock_build_folder():
    """
    This function is used to create and lock the building dir (see cmake) too avoid two concurrency
    threads using the same cache files.
    """

    def wrapper(func):
        @functools.wraps(func)
        def wrapper_filelock(*args, **kwargs):
            # get build folder name
            bf = args[0].build_folder
            # create build folder
            os.makedirs(bf, exist_ok=True)

            # create a file lock to prevent multiple compilations at the same time
            with open(os.path.join(bf, 'pykeops_build2.lock'), 'w') as f:
                with FileLock(f):
                    func_res = func(*args, **kwargs)

            # clean
            if (module_exists(args[0].dll_name)) and (pykeops.config.build_type == 'Release'):
                shutil.rmtree(bf)

            return func_res

        return wrapper_filelock

    return wrapper


def get_tools(lang):
    """
    get_tools is used to simulate template as in Cpp code. Depending on the langage
    it import the right classes.
    
    :param lang: a string with the langage ('torch'/'pytorch' or 'numpy')
    :return: a class tools
    """

    if lang == "numpy":
        from pykeops.numpy.utils import numpytools
        tools = numpytools()
    elif lang == "torch" or lang == "pytorch":
        from pykeops.torch.utils import torchtools
        tools = torchtools()

    return tools


def WarmUpGpu(lang):
    tools = get_tools(lang)
    # dummy first calls for accurate timing in case of GPU use
    my_routine = tools.Genred("SqDist(x,y)", ["x = Vi(1)",  "y = Vj(1)"], reduction_op='Sum', axis=1, dtype=tools.dtype)
    dum = tools.rand(10, 1)
    my_routine(dum, dum)
    my_routine(dum, dum)


def clean_pykeops(path="", lang=""):
    if lang not in ["numpy", "torch", ""]:
        raise ValueError('[pyKeOps:] lang should be the empty string, "numpy" or "torch"')

    if path == "":
        path = pykeops.config.bin_folder

    print("Cleaning " + path)
    for f in os.listdir(path):
        if (f.endswith('so')) and (f.count("libKeOps" + lang)):
            os.remove(os.path.join(path, f))
            print(os.path.join(path, f) + " has been removed.")


def max_tuple(a, b):
    return tuple( max(a_i, b_i) for (a_i, b_i) in zip(a, b) )


def check_broadcasting(dims_1, dims_2):
    r"""
    Checks that the shapes **dims_1** and **dims_2** are compatible with each other.
    """
    if dims_1 is None:
        return dims_2
    if dims_2 is None:
        return dims_1
    
    padded_dims_1 = (1,) * (len(dims_2) - len(dims_1)) + dims_1
    padded_dims_2 = (1,) * (len(dims_1) - len(dims_2)) + dims_2
    
    for (dim_1, dim_2) in zip(padded_dims_1, padded_dims_2):
        if dim_1 != 1 and dim_2 != 1 and dim_1 != dim_2:
            raise ValueError("Incompatible batch dimensions: {} and {}.".format(dims_1, dims_2))
    
    return max_tuple(padded_dims_1, padded_dims_2)