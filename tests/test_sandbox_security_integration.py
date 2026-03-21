import json
import os
import pathlib
import shutil
import subprocess

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB_DIR = REPO_ROOT / "lib"

_counter = 0


def _unique_name():
    global _counter  # noqa: PLW0603
    _counter += 1
    return f"test-am-sb-{os.getpid()}-{_counter}"


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
    sb_home = tmp_path / "sandbox-home"
    sb_home.mkdir()
    container_name = _unique_name()
    env = os.environ.copy()
    env["AM_SCRIPT_DIR"] = str(REPO_ROOT)
    env["AM_DIR"] = str(am_dir)
    env["AM_CONFIG"] = str(am_dir / "config.json")
    env["SB_HOME_DIR"] = str(sb_home)
    env["SB_UNSAFE_ROOT"] = "0"
    env["SB_PIDS_LIMIT"] = "128"
    env["SB_MEMORY_LIMIT"] = "1g"
    env["SB_CPUS_LIMIT"] = "1.0"
    env["_TEST_CONTAINER"] = container_name
    try:
        yield env
    finally:
        proxy_name = f"{container_name}-proxy"
        net_name = f"{container_name}-net"
        _run(["docker", "rm", "-f", container_name], env=env, check=False)
        _run(["docker", "rm", "-f", proxy_name], env=env, check=False)
        _run(["docker", "network", "rm", net_name], env=env, check=False)


def _shell(command, env, check=True):
    prelude = (
        f"export AM_SCRIPT_DIR='{REPO_ROOT}'; "
        f"export AM_DIR='{env['AM_DIR']}'; "
        f"export AM_CONFIG='{env['AM_CONFIG']}'; "
        f"export SB_HOME_DIR='{env['SB_HOME_DIR']}'; "
        f"export HOME='{env['HOME']}'; "
        f"source '{LIB_DIR / 'utils.sh'}'; "
        f"source '{LIB_DIR / 'config.sh'}'; "
        f"source '{LIB_DIR / 'tmux.sh'}'; "
        f"source '{LIB_DIR / 'sandbox.sh'}'; "
        f"am_config_init; "
    )
    return _run(["bash", "-c", prelude + command], env=env, check=check)


def _inspect(name):
    payload = json.loads(_run(["docker", "inspect", name]).stdout)
    return payload[0]


@pytest.mark.security
def test_sandbox_start_uses_home_bind_mount_and_project_mount_only_by_default(
    sandbox_env, tmp_path,
):
    project_dir = tmp_path / "project"
    project_dir.mkdir()
    name = sandbox_env["_TEST_CONTAINER"]

    _shell(f"sandbox_start {name} '{project_dir}'", sandbox_env)
    inspect = _inspect(name)
    mounts = {mount["Destination"]: mount for mount in inspect["Mounts"]}

    assert str(project_dir) in mounts
    assert mounts[str(project_dir)]["RW"] is True
    home_dest = "/home/ubuntu"
    assert home_dest in mounts
    assert mounts[home_dest]["Type"] == "bind"
    assert mounts[home_dest]["Source"] == sandbox_env["SB_HOME_DIR"]
    assert len(mounts) == 2

    caps = {
        cap.removeprefix("CAP_") for cap in (inspect["HostConfig"].get("CapAdd") or [])
    }
    assert caps == {"CHOWN", "DAC_OVERRIDE", "FOWNER"}
    assert inspect["HostConfig"]["SecurityOpt"] == ["no-new-privileges:true"]


@pytest.mark.functional
def test_home_persistence_across_containers(sandbox_env, tmp_path):
    project_dir = tmp_path / "project"
    project_dir.mkdir()
    name = sandbox_env["_TEST_CONTAINER"]

    _shell(f"sandbox_start {name} '{project_dir}'", sandbox_env)

    # Write a file inside the container's home
    _run([
        "docker", "exec", name,
        "sh", "-c", "echo hello > /home/ubuntu/testfile.txt",
    ])

    # Verify it appears on the host
    sb_home = pathlib.Path(sandbox_env["SB_HOME_DIR"])
    assert (sb_home / "testfile.txt").read_text() == "hello\n"

    # Kill container, start new one — file should persist
    _run(["docker", "rm", "-f", name])
    _shell(f"sandbox_start {name} '{project_dir}'", sandbox_env)

    result = _run([
        "docker", "exec", name,
        "sh", "-c", "cat /home/ubuntu/testfile.txt",
    ])
    assert result.stdout.strip() == "hello"


@pytest.mark.ux
def test_share_mounts(sandbox_env, tmp_path):
    project_dir = tmp_path / "project"
    project_dir.mkdir()
    shared = tmp_path / "shared.txt"
    shared.write_text("shared-data\n")
    name = sandbox_env["_TEST_CONTAINER"]

    _shell(
        f"sandbox_start {name} '{project_dir}'"
        f" '{shared}:~/.shared-file:rw'",
        sandbox_env,
    )

    container_home = "/home/ubuntu"
    result = _run([
        "docker",
        "exec",
        name,
        "sh",
        "-lc",
        f"cat {container_home}/.shared-file",
    ])
    assert result.stdout.strip() == "shared-data"

    inspect = _inspect(name)
    mounts = {mount["Destination"]: mount for mount in inspect["Mounts"]}
    assert f"{container_home}/.shared-file" in mounts
    assert mounts[f"{container_home}/.shared-file"]["RW"] is True


@pytest.mark.ux
def test_system_tools_available(sandbox_env, tmp_path):
    """Tools installed to system paths survive the home dir bind mount."""
    project_dir = tmp_path / "project"
    project_dir.mkdir()
    name = sandbox_env["_TEST_CONTAINER"]

    _shell(f"sandbox_start {name} '{project_dir}'", sandbox_env)

    result = _run([
        "docker", "exec", name,
        "bash", "-c",
        "which uv && which cargo && which claude && which ipython && which rustfmt",
    ])
    paths = result.stdout.strip().splitlines()
    assert len(paths) == 5
    # All should be in system paths, not under /home/ubuntu
    for p in paths:
        assert not p.startswith("/home/ubuntu"), f"Tool at user path: {p}"


@pytest.mark.ux
def test_skeleton_files_seeded(sandbox_env, tmp_path):
    """Entrypoint seeds /etc/skel files into an empty home dir."""
    project_dir = tmp_path / "project"
    project_dir.mkdir()
    name = sandbox_env["_TEST_CONTAINER"]

    _shell(f"sandbox_start {name} '{project_dir}'", sandbox_env)

    result = _run([
        "docker", "exec", name,
        "test", "-f", "/home/ubuntu/.vimrc",
    ])
    assert result.returncode == 0


@pytest.mark.functional
def test_sb_reset_clears_home(sandbox_env):
    """sb_reset removes all files from the sandbox home directory."""
    sb_home = pathlib.Path(sandbox_env["SB_HOME_DIR"])
    (sb_home / "somefile.txt").write_text("data\n")

    _shell("sb_reset 1", sandbox_env)

    remaining = [p.name for p in sb_home.iterdir()]
    assert remaining == [], f"Home dir not empty after reset: {remaining}"
    assert sb_home.is_dir(), "Home dir should still exist after reset"


@pytest.mark.functional
def test_sb_export_import_roundtrip(sandbox_env, tmp_path):
    """sb_export + sb_import preserves home directory contents."""
    sb_home = pathlib.Path(sandbox_env["SB_HOME_DIR"])
    (sb_home / "roundtrip.txt").write_text("exported\n")
    archive = tmp_path / "export.tar.gz"

    _shell(f"sb_export '{archive}'", sandbox_env)
    assert archive.is_file()

    # Clear and re-import
    (sb_home / "roundtrip.txt").unlink()
    _shell(f"sb_import '{archive}' 1", sandbox_env)

    assert (sb_home / "roundtrip.txt").read_text() == "exported\n"
