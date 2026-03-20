# shellcheck shell=bash
# sb_volume.sh - Docker volume helpers for sandbox state

[[ -z "$AM_DIR" ]] && source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

SB_STATE_VOLUME="${SB_STATE_VOLUME:-am-state}"
SB_STATE_MOUNT="/state"

_sb_vol_run() {
    docker run --rm -i -v "${SB_STATE_VOLUME}:${SB_STATE_MOUNT}" alpine "$@"
}

sb_vol_exists() {
    local path="$1"
    _sb_vol_run test -e "${SB_STATE_MOUNT}/${path}"
}

sb_vol_read() {
    local path="$1"
    _sb_vol_run cat "${SB_STATE_MOUNT}/${path}"
}

sb_vol_write() {
    local path="$1"
    local content="${2-}"
    if [[ $# -ge 2 ]]; then
        printf '%s' "$content" | docker run --rm -i -v "${SB_STATE_VOLUME}:${SB_STATE_MOUNT}" alpine sh -lc "mkdir -p \"$(dirname "${SB_STATE_MOUNT}/${path}")\" && cat > \"${SB_STATE_MOUNT}/${path}\""
    else
        docker run --rm -i -v "${SB_STATE_VOLUME}:${SB_STATE_MOUNT}" alpine sh -lc "mkdir -p \"$(dirname "${SB_STATE_MOUNT}/${path}")\" && cat > \"${SB_STATE_MOUNT}/${path}\""
    fi
}

sb_vol_rm() {
    local path="$1"
    _sb_vol_run rm -rf "${SB_STATE_MOUNT}/${path}"
}

sb_vol_ls() {
    local path="${1:-.}"
    _sb_vol_run ls -la "${SB_STATE_MOUNT}/${path}"
}

sb_vol_mkdir() {
    local path="$1"
    _sb_vol_run mkdir -p "${SB_STATE_MOUNT}/${path}"
}

sb_vol_copy_in() {
    local host_path="$1"
    local vol_path="$2"
    docker run --rm \
        -v "${SB_STATE_VOLUME}:${SB_STATE_MOUNT}" \
        -v "${host_path}:/_src" \
        alpine sh -lc "mkdir -p \"$(dirname "${SB_STATE_MOUNT}/${vol_path}")\" && rm -rf \"${SB_STATE_MOUNT}/${vol_path}\" && cp -a /_src \"${SB_STATE_MOUNT}/${vol_path}\""
}

sb_vol_copy_out() {
    local vol_path="$1"
    local host_path="$2"
    docker run --rm \
        -v "${SB_STATE_VOLUME}:${SB_STATE_MOUNT}" \
        -v "${host_path}:/_dst" \
        alpine sh -lc "rm -rf /_dst && cp -a \"${SB_STATE_MOUNT}/${vol_path}\" /_dst"
}

sb_vol_ensure() {
    docker volume inspect "$SB_STATE_VOLUME" >/dev/null 2>&1 || docker volume create "$SB_STATE_VOLUME" >/dev/null
    sb_vol_mkdir data

    if ! sb_vol_exists meta.json; then
        printf '{\n  "version": 1,\n  "created_at": "%s"\n}\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" | sb_vol_write meta.json
    fi

    if ! sb_vol_exists mappings.json; then
        printf '{\n  "version": 1,\n  "mappings": []\n}\n' | sb_vol_write mappings.json
    fi
}
