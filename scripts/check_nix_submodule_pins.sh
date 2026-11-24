#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Check that the submodule sources pinned in flake.nix match the submodule
# gitlinks in the git index. After moving a submodule, update the matching
# input URL in flake.nix and run `nix flake lock`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

status=0
check() {
    local path=$1 repo=$2
    local gitlink pinned
    gitlink=$(git ls-files --stage -- "$path" | awk '$1 == "160000" { print $2 }')
    pinned=$(sed -n "s|.*\"github:${repo}/\\([0-9a-f]\\{40\\}\\)\".*|\\1|p" flake.nix)
    if [[ -z "$gitlink" ]]; then
        echo "error: $path is not a submodule" >&2
        status=1
    elif [[ "$gitlink" != "$pinned" ]]; then
        echo "error: flake.nix pins ${repo} at ${pinned:-nothing}, but the $path submodule is at $gitlink" >&2
        status=1
    fi
}

check llama.cpp ggml-org/llama.cpp
check third_party/cpp-httplib yhirose/cpp-httplib
exit "$status"
