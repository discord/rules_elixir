load("//private:mix_library.bzl", _mix_library = "mix_library")
load("//private:mix_release.bzl", _mix_release = "mix_release")

def mix_library(*args, **kwargs):
    deps = kwargs.get("deps", [])
    if kwargs.get("app_name") != "hex":
        deps.append(Label("@hex_pm//:lib"))
    kwargs["deps"] = deps
    _mix_library(*args, **kwargs)

def mix_release(*args, **kwargs):
    _mix_release(*args, **kwargs)
