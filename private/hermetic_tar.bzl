"""The deterministic bsdtar pipeline, shared by every rule here that writes a
tar archive and by //tar_repro:tar_repro_test.

Why is this here? The Elixir tarball has to hash the same on every worker,
and it has to be built on a Mac. The old command was a bare `tar -czhf`,
which copies the wall clock, the builder's uid and the output filename into
the archive, so it did neither. bsdtar answers `--sort=name` and
`--hard-dereference` with "Option ... is not supported", and the bsdtar Apple
ships (libarchive 3.7.4) has no `--mtime` either, so the GNU flag set that
would fix that has no bsdtar spelling at all. Driving bsdtar from an mtree
manifest does have one, and it gives the same bytes as the GNU flags: a
fixture with a symlink, a hard-link pair and three mode values hashes the
same either way.

This is a copy of the same file in rules_erlang. The two rulesets share no
Starlark library, and a new module to hold twelve lines would cost more than
the copy does.

The test regenerates its script from these same strings, so it cannot pass
while the rules drift away from it.
"""

# tar.bzl does not re-export this from a public .bzl file. The definition is
# TAR_TOOLCHAIN_TYPE at @tar.bzl//tar/private:tar.bzl.
TAR_TOOLCHAIN_TYPE = "@tar.bzl//tar/toolchain:type"

# The keywords we keep. "!all" drops everything else -- uname, gname, flags,
# nlink and the digests -- so bsdtar cannot copy any of it out of the
# filesystem and into a header.
_MTREE_KEYWORDS = "!all,type,mode,size,link,time,uid,gid"

_SETUP = """\
BSDTAR="$PWD/%s"
# tar.bzl pairs its bsdtar with a UTF-8 locale, and libarchive reads only
# LC_ALL (@tar.bzl//tar/toolchain:utf8_environment.bzl). We set it per call
# rather than as the action's env, so that the rest of the action -- the
# Elixir build itself, above all -- keeps the locale it was given.
bsdtar() { env %s "$BSDTAR" "$@"; }\
"""

# Pass 1 lists the tree, awk normalises the three unstable keywords, sort
# fixes the order. Each substitution replaces one GNU flag we lost:
#   time=0          <- --mtime=@0
#   uid=0 gid=0     <- --owner=0 --group=0
#   nlink=1         <- --hard-dereference. Without it bsdtar re-stats the file
#                      in pass 2, sees st_nlink > 1 and writes a hard link
#                      member for the second name instead of a second copy.
#   LC_ALL=C sort   <- --sort=name. Both compare raw bytes, but GNU sorts each
#                      directory and descends, while this sorts whole paths.
#                      They disagree only when a sibling name sorts below '/'
#                      (0x2F) after a shared prefix, e.g. `lib/` against
#                      `lib-extra`. An OTP release tree holds no such pair.
# The `#mtree` header has to stay on line 1, so sort never sees it.
_MTREE_CMDS = """\
%s -cf - --format=mtree --options='%s' %s \\
  | awk 'NR==1 {print; next}
         {sub(/ time=[0-9.]+/, " time=0");
          sub(/ uid=[0-9]+/, " uid=0");
          sub(/ gid=[0-9]+/, " gid=0")}
         /type=file/ {sub(/ type=file/, " type=file nlink=1")}
         {print}' \\
  | { IFS= read -r hdr; printf '%%s\\n' "$hdr"; LC_ALL=C sort; } > "%s"\
"""

_ARCHIVE_CMDS = """%s --format=gnutar --numeric-owner -cf - "@%s\""""

def bsdtar_setup(tar_toolchain, bsdtar_path):
    """Shell that defines the `bsdtar` function the other helpers call.

    Run it while $PWD is still the execroot: it resolves the binary once, so
    that every later call survives a `cd`.

    Args:
        tar_toolchain: the resolved @tar.bzl//tar/toolchain:type toolchain.
        bsdtar_path: execroot-relative path of the bsdtar binary.

    Returns:
        Shell commands, ready to interpolate.
    """
    env = tar_toolchain.tarinfo.default_env
    assignments = " ".join(["%s=%s" % (k, v) for k, v in sorted(env.items())])
    return _SETUP % (bsdtar_path, assignments)

def mtree_cmds(list_args, mtree_path, bsdtar = "bsdtar"):
    """Shell that writes a normalised mtree manifest of the named tree.

    Args:
        list_args: the arguments that choose what to list, for example
            "-h --exclude='lib/*/src' .". Raw shell.
        mtree_path: where to write the manifest. A shell expression that is
            safe inside double quotes. It must sit outside the tree that
            list_args selects, or pass 2 archives the manifest as well.
        bsdtar: the command that runs bsdtar.

    Returns:
        Shell commands, ready to interpolate.
    """
    return _MTREE_CMDS % (bsdtar, _MTREE_KEYWORDS, list_args, mtree_path)

def archive_cmds(mtree_path, bsdtar = "bsdtar"):
    """Shell that writes the archive for a manifest to stdout.

    bsdtar re-reads every file to get its content, so the tree must not change
    between mtree_cmds and this. The manifest records `size`, and a mismatch
    is a hard error. Both passes run inside one action today, which is what
    keeps that safe.

    Args:
        mtree_path: the manifest that mtree_cmds wrote.
        bsdtar: the command that runs bsdtar.

    Returns:
        Shell commands, ready to interpolate. They write to stdout.
    """
    return _ARCHIVE_CMDS % (bsdtar, mtree_path)
