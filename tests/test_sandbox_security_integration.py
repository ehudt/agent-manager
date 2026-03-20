import json
import os
import pathlib
import shutil
import subprocess
import uuid

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB_DIR = REPO_ROOT / "lib"


def _run(cmd, *, env=None, check=True, timeout=240):
    result = subprocess.run(
        cmd,
        text=True,
        capture_output=True,
        env=env,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        raise AssertionError(
            f"Command failed ({result.returncode}): {' '.join(cmd)}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    return result


@pytest.fixture(scope="session", autouse=True)
def require_docker():
    if not shutil.which("docker"):
        pytest.skip("docker unavailable", allow_module_level=True)
    if _run(["docker", "info"], check=False, timeout=30).returncode != 0:
        pytest.skip("docker daemon unavailable", allow_module_level=True)


@pytest.fixture
def sandbox_env(tmp_path):
    am_dir = tmp_path / "am"
    am_dir.mkdir()
    (am_dir / "sessions.json").write_text('{"sessions":{}}\n')
    env = os.environ.copy()
    env["AM_SCRIPT_DIR"] = str(REPO_ROOT)
    env["AM_DIR"] = str(am_dir)
    env["AM_CONFIG"] = str(am_dir / "config.json")
    env["SB_STATE_VOLUME"] = f"am-test-state-{uuid.uuid4().hex[:8]}"
    env["SB_UNSAFE_ROOT"] = "0"
    env["SB_PIDS_LIMIT"] = "128"
    env["SB_MEMORY_LIMIT"] = "1g"
    env["SB_CPUS_LIMIT"] = "1.0"
    try:
        yield env
    finally:
        _run(
            ["docker", "rm", "-f", "am-test-sb"],
            env=env, check=False,
        )
        _run(
            ["docker", "volume", "rm", "-f", env["SB_STATE_VOLUME"]],
            env=env, check=False,
        )


def _shell(command, env, check=True):
    prelude = (
        f"export AM_SCRIPT_DIR='{REPO_ROOT}'; "
        f"export AM_DIR='{env['AM_DIR']}'; "
        f"export AM_CONFIG='{env['AM_CONFIG']}'; "
        f"export SB_STATE_VOLUME='{env['SB_STATE_VOLUME']}'; "
        f"export HOME='{env['HOME']}'; "
        f"source '{LIB_DIR / 'utils.sh'}'; "
        f"source '{LIB_DIR / 'config.sh'}'; "
        f"source '{LIB_DIR / 'tmux.sh'}'; "
        f"source '{LIB_DIR / 'sb_volume.sh'}'; "
        f"source '{LIB_DIR / 'sandbox.sh'}'; "
        f"am_config_init; "
    )
    return _run(["bash", "-c", prelude + command], env=env, check=check)


def _inspect(name):
    payload = json.loads(_run(["docker", "inspect", name]).stdout)
    return payload[0]


@pytest.mark.functional
def test_mapping_lifecycle_and_sync(sandbox_env, tmp_path):
    host_file = tmp_path / "host.txt"
    host_file.write_text("v1\n")

    _shell(f"sb_map '{host_file}' --to ~/.demo-file", sandbox_env)
    manifest = json.loads(_shell("sb_vol_read mappings.json", sandbox_env).stdout)
    assert manifest["mappings"][0]["name"] == "demo-file"
    assert "demo-file" in _shell("sb_maps", sandbox_env).stdout

    host_file.write_text("v2\n")
    _shell("sb_sync demo-file", sandbox_env)
    copied = _shell("sb_vol_read data/demo-file", sandbox_env).stdout
    assert copied == "v2\n"

    _shell("sb_unmap demo-file", sandbox_env)
    manifest = json.loads(_shell("sb_vol_read mappings.json", sandbox_env).stdout)
    assert manifest["mappings"] == []
    missing = _shell("sb_vol_exists data/demo-file", sandbox_env, check=False)
    assert missing.returncode != 0


@pytest.mark.functional
def test_presets_merge_and_skip_missing_entries(sandbox_env, tmp_path):
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    (fake_home / ".ssh").mkdir()
    (fake_home / ".ssh" / "config").write_text("Host *\n")
    (fake_home / ".gitconfig").write_text("[user]\n\tname = Test\n")
    sandbox_env["HOME"] = str(fake_home)
    pathlib.Path(sandbox_env["AM_DIR"]).joinpath("presets.json").write_text(
        json.dumps(
            {
                "custom": [
                    {
                        "host": "~/.gitconfig",
                        "target": "~/.gitconfig",
                        "name": "custom-git",
                    }
                ]
            }
        )
    )

    listed = _shell("sb_map --list-presets", sandbox_env).stdout
    assert "PRESET\tssh" in listed
    assert "PRESET\tcustom" in listed

    _shell("sb_map --preset ssh", sandbox_env)
    manifest = json.loads(_shell("sb_vol_read mappings.json", sandbox_env).stdout)
    assert any(item["name"] == "ssh" for item in manifest["mappings"])

    _shell("sb_map --preset custom", sandbox_env)
    manifest = json.loads(_shell("sb_vol_read mappings.json", sandbox_env).stdout)
    assert any(item["name"] == "custom-git" for item in manifest["mappings"])


@pytest.mark.security
def test_sandbox_start_uses_state_volume_and_project_mount_only_by_default(
    sandbox_env, tmp_path,
):
    project_dir = tmp_path / "project"
    project_dir.mkdir()

    _shell(f"sandbox_start am-test-sb '{project_dir}'", sandbox_env)
    inspect = _inspect("am-test-sb")
    mounts = {mount["Destination"]: mount for mount in inspect["Mounts"]}

    assert str(project_dir) in mounts
    assert mounts[str(project_dir)]["RW"] is True
    state_dest = "/home/ubuntu/.am-state"
    assert state_dest in mounts
    assert mounts[state_dest]["Type"] == "volume"
    assert len(mounts) == 2

    caps = {
        cap.removeprefix("CAP_") for cap in (inspect["HostConfig"].get("CapAdd") or [])
    }
    assert caps == {"CHOWN", "DAC_OVERRIDE", "FOWNER"}
    assert inspect["HostConfig"]["SecurityOpt"] == ["no-new-privileges:true"]


@pytest.mark.ux
def test_entrypoint_hydration_and_share_mounts(sandbox_env, tmp_path):
    project_dir = tmp_path / "project"
    project_dir.mkdir()
    mapped = tmp_path / "mapped.txt"
    mapped.write_text("mapped-data\n")
    shared = tmp_path / "shared.txt"
    shared.write_text("shared-data\n")

    _shell(f"sb_map '{mapped}' --to ~/.mapped-file", sandbox_env)
    _shell(
        f"sandbox_start am-test-sb '{project_dir}'"
        f" '{shared}:~/.shared-file:rw'",
        sandbox_env,
    )

    container_home = "/home/ubuntu"
    hydrated_path = _run([
        "docker",
        "exec",
        "am-test-sb",
        "sh",
        "-lc",
        f"readlink -f {container_home}/.mapped-file && "
        f"cat {container_home}/.mapped-file && "
        f"cat {container_home}/.shared-file",
    ]).stdout.splitlines()

    assert hydrated_path[0] == f"{container_home}/.am-state/data/mapped-file"
    assert hydrated_path[1] == "mapped-data"
    assert hydrated_path[2] == "shared-data"

    inspect = _inspect("am-test-sb")
    mounts = {mount["Destination"]: mount for mount in inspect["Mounts"]}
    assert f"{container_home}/.shared-file" in mounts
    assert mounts[f"{container_home}/.shared-file"]["RW"] is True
