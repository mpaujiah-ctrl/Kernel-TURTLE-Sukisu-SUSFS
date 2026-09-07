#!/bin/bash
# Shell author (original): JackA1ltman <cs2dtzq@163.com>
# Fixed version: replaces the old regex-based stripper (which could jump
# across unrelated #ifdef/#else/#endif blocks and corrupt files like
# fs/statfs.c) with a nesting-aware stripper. See strip_conditional
# section below for details.
# Tested kernel versions: 5.4, 4.19, 4.14, 4.9, 4.4, 3.18 (source layout)

KSU_FOLDER=("drivers/kernelsu" "KernelSU" "KernelSU-Next")

KSU_CLEAN_FILES=("fs/exec.c" "fs/read_write.c" "fs/open.c" "fs/stat.c" "fs/devpts/inode.c" "fs/namei.c" "drivers/input/input.c" "drivers/tty/pty.c" "security/selinux/hooks.c" "kernel/reboot.c" "kernel/sys.c")

SUSFS_CLEAN_FILES=("security/selinux/avc.c" "kernel/kallsyms.c" "kernel/sys.c" "kernel/reboot.c" "fs/dcache.c" "fs/statfs.c" "fs/namespace.c" "fs/proc_namespace.c" "fs/stat.c" "fs/namei.c" "fs/readdir.c" "fs/exec.c" "fs/proc/task_mmu.c" "fs/proc/base.c" "fs/proc/fd.c" "fs/proc/cmdline.c" "fs/overlayfs/super.c" "fs/overlayfs/overlayfs.h" "fs/overlayfs/inode.c" "fs/notify/fdinfo.c" "fs/devpts/inode.c" "include/linux/sched.h" "include/linux/mount.h")

SUSFS_REMAIN_CLEAN_FILES=("fs/susfs.c" "fs/sus_su.c" "include/linux/susfs.h" "include/linux/susfs_def.h")

# --- nesting-aware stripper (embedded) -------------------------------------
# Writes itself to a temp file once, then is invoked per target file.
# Handles:
#   #ifdef  TARGET ... [#else VANILLA] #endif  -> keep VANILLA if present,
#                                                  else drop whole block
#   #ifndef TARGET ... [#else HOOK]    #endif  -> keep the ifndef (vanilla)
#                                                  branch, drop the hook
#   #if defined(TARGET...) ...          #endif -> same as #ifdef
# Nested directives unrelated to CONFIG_KSU / CONFIG_KSU_SUSFS* are passed
# through untouched, in whichever branch they live in. This fixes the old
# script's bug of using a text-distance regex that could pair an #ifdef
# with an unrelated #else/#endif belonging to a totally different block.
STRIPPER="$(mktemp /tmp/strip_conditional.XXXXXX.py)"
cat > "$STRIPPER" << 'PYEOF'
import re, sys

TARGET_RE = re.compile(r'\bCONFIG_KSU\b|CONFIG_KSU_SUSFS')
DIRECTIVE_RE = re.compile(r'^\s*#\s*(ifdef|ifndef|if)\b(.*)$')
ELSE_RE = re.compile(r'^\s*#\s*else\b')
ELIF_RE = re.compile(r'^\s*#\s*elif\b')
ENDIF_RE = re.compile(r'^\s*#\s*endif\b')


class Frame:
    __slots__ = ("is_target", "keep_branch")

    def __init__(self, is_target, keep_branch):
        self.is_target = is_target
        self.keep_branch = keep_branch


def strip(text: str) -> str:
    lines = text.split("\n")
    out = []
    stack = []

    def suppressed():
        for f in stack:
            if f.is_target and not f.keep_branch:
                return True
        return False

    for line in lines:
        m = DIRECTIVE_RE.match(line)
        if m:
            kind, cond = m.group(1), m.group(2)
            is_target = bool(TARGET_RE.search(cond))
            keep_branch = True if kind == "ifndef" else False
            stack.append(Frame(is_target, keep_branch))
            if is_target:
                continue
            if suppressed():
                continue
            out.append(line)
            continue

        if ELSE_RE.match(line) and stack:
            f = stack[-1]
            if f.is_target:
                f.keep_branch = not f.keep_branch
                continue
            if suppressed():
                continue
            out.append(line)
            continue

        if ELIF_RE.match(line) and stack:
            f = stack[-1]
            if f.is_target:
                continue
            if suppressed():
                continue
            out.append(line)
            continue

        if ENDIF_RE.match(line) and stack:
            f = stack.pop()
            if f.is_target:
                continue
            if suppressed():
                continue
            out.append(line)
            continue

        if stack:
            top = stack[-1]
            if top.is_target:
                if top.keep_branch and not suppressed():
                    out.append(line)
                continue
            if suppressed():
                continue
            out.append(line)
        else:
            out.append(line)

    return "\n".join(out)


if __name__ == "__main__":
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
        content = fh.read()
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(strip(content))
PYEOF

strip_file() {
    local file="$1"
    [ -f "$file" ] || return 0
    python3 "$STRIPPER" "$file"
    # belt-and-suspenders: remove any bare susfs #include left outside an
    # ifdef (e.g. fs/stat.c's top-of-file "#include <linux/susfs_def.h>"),
    # since fs/susfs.h / susfs_def.h get deleted a few steps down.
    sed -i '/#include\s*[<"]linux\/susfs/d' "$file"
}

# Removal of KernelSU folders/symlinks
for file in "${KSU_FOLDER[@]}"; do
    rm -rf "${file}"
    if [ -f "${file}" ] || [ -d "${file}" ]; then
        echo "[-] Could not remove ${file}."
    else
        echo "[+] Cleaned for ${file}."
    fi
done

# Removal of KernelSU hooks
for file in "${KSU_CLEAN_FILES[@]}"; do
    [ -f "$file" ] || continue
    strip_file "${file}"
done

# Removal of SUSFS hooks
for file in "${SUSFS_CLEAN_FILES[@]}"; do
    [ -f "$file" ] || continue
    strip_file "${file}"
    if grep -q "CONFIG_KSU_SUSFS" "${file}" 2>/dev/null; then
        echo "[-] Could not remove SuSFS hook from ${file}."
    else
        echo "[+] Cleaned SuSFS Hook for ${file}."
    fi
done

# Final check across both lists combined (single accurate pass, avoids the
# old script's false-alarm ordering issue where KSU_CLEAN_FILES were
# checked for a bare "CONFIG_KSU" substring before their SUSFS hooks -
# which also contain that substring - had been stripped yet)
for file in "${KSU_CLEAN_FILES[@]}" "${SUSFS_CLEAN_FILES[@]}"; do
    [ -f "$file" ] || continue
    if grep -q "CONFIG_KSU" "${file}" 2>/dev/null; then
        echo "[-] ${file} still has CONFIG_KSU references, check manually."
    fi
done

rm -f "$STRIPPER"

for file in "${SUSFS_REMAIN_CLEAN_FILES[@]}"; do
    rm -f "${file}"
    if [ -f "${file}" ]; then
        echo "[-] Could not remove file ${file}."
    else
        echo "[+] Removed file ${file}."
    fi
done

if grep -q "CONFIG_KSU_SUSFS" "fs/Makefile" 2>/dev/null; then
    sed -i '/CONFIG_KSU_SUSFS/d' fs/Makefile
    if grep -q "CONFIG_KSU_SUSFS" "fs/Makefile"; then
        echo "[-] Could not remove code from fs/Makefile."
    else
        echo "[+] Removed code for fs/Makefile."
    fi
else
    echo "[-] Have no CONFIG_KSU_SUSFS in fs/Makefile"
fi
