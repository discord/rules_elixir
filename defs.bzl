load("//private:mix_library.bzl", _mix_library = "mix_library")
load("//private:mix_binary.bzl", _mix_binary = "mix_binary")

def mix_library(*args, **kwargs):
    _mix_library(*args, **kwargs)

def mix_binary(*args, **kwargs):
    _mix_binary(*args, **kwargs)
