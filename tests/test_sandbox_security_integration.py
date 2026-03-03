import json
import os
import pathlib
import shutil
import socket
import subprocess
import time
import uuid

import pytest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
AM_PATH = REPO_ROOT / "am"
LIB_DIR = REPO_ROOT / "lib"


def _run(cmd, *, env=None, timeout=240, check=True):
    result = subprocess.run(
        cmd,
        env=env,
        text=True,
        capture_output=True,
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


def _assert_command_failed(result, *expected_fragments):
    assert result.returncode != 0, "Command unexpectedly succeeded"
    combined = f"{result.stdout}\n{result.stderr}"
    for fragment in expected_fragments:
        assert fragment in combined, f"Expected {fragment!r} in output:\n{combined}"


def _docker_available():
    if not shutil.which("docker"):
        return False
    result = _run(["docker", "info"], check=False, timeout=30)
    return result.returncode == 0


def _base_env():
    env = os.environ.copy()
    env.setdefault("SB_ENABLE_TAILSCALE", "0")
    env.setdefault("TS_ENABLE_SSH", "0")
    env.setdefault("ENABLE_SSH", "0")
    env.setdefault("SB_UNSAFE_ROOT", "0")
    env.setdefault("SB_PIDS_LIMIT", "512")
    env.setdefault("SB_MEMORY_LIMIT", "4g")
    env.setdefault("SB_CPUS_LIMIT", "2.0")
    return env


def _shell_prelude(am_dir):
    return (
        f"export AM_SCRIPT_DIR='{REPO_ROOT}'; "
        f"export AM_DIR='{am_dir}'; "
        f"source '{LIB_DIR / 'utils.sh'}'; "
        f"source '{LIB_DIR / 'sandbox.sh'}'; "
    )


def _run_sandbox_function(function_call, *, env=None, timeout=240, check=True):
    am_dir = pathlib.Path(env["AM_DIR"])
    command = _shell_prelude(am_dir) + function_call
    return _run(["bash", "-lc", command], env=env, timeout=timeout, check=check)


def _find_container(container_name):
    result = _run(
        ["docker", "ps", "-a", "--filter", f"name=^{container_name}$", "--format", "{{.Names}}"],
        check=True,
    )
    names = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    assert names, f"No container found named {container_name}"
    return names[0]


def _inspect(container_name):
    result = _run(["docker", "inspect", container_name], check=True)
    payload = json.loads(result.stdout)
    assert payload and isinstance(payload, list), "docker inspect returned empty payload"
    return payload[0]


def _normalize_caps(caps):
    normalized = set()
    for cap in caps or []:
        normalized.add(cap[4:] if cap.startswith("CAP_") else cap)
    return normalized


def _container_state(container_name):
    result = _run(
        ["docker", "inspect", "-f", "{{.State.Status}}", container_name],
        check=True,
    )
    return result.stdout.strip()


def _container_logs(container_name, tail=120):
    result = _run(["docker", "logs", "--tail", str(tail), container_name], check=False)
    return (result.stdout or "") + (result.stderr or "")


def _container_mount(inspect_payload, destination):
    for mount in inspect_payload.get("Mounts", []):
        if mount.get("Destination") == destination:
            return mount
    raise AssertionError(f"Mount for destination {destination} not found")


def _wait_for_running(container_name, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        state = _container_state(container_name)
        if state == "running":
            return
        if state in {"exited", "dead"}:
            logs = _container_logs(container_name)
            raise AssertionError(
                f"Container did not stay up (state={state}). Recent logs:\n{logs}"
            )
        time.sleep(1)
    state = _container_state(container_name)
    logs = _container_logs(container_name)
    raise AssertionError(
        f"Timed out waiting for running state (state={state}). Recent logs:\n{logs}"
    )


def _prepare_fake_home(home_dir):
    home_dir.mkdir(parents=True, exist_ok=True)
    (home_dir / ".claude").mkdir(parents=True, exist_ok=True)
    (home_dir / ".codex").mkdir(parents=True, exist_ok=True)
    (home_dir / ".ssh").mkdir(parents=True, exist_ok=True)
    (home_dir / ".claude.json").write_text('{"test": true}\n')
    (home_dir / ".codex" / "config.toml").write_text("[default]\nmodel = 'test'\n")
    (home_dir / ".codex" / "auth.json").write_text('{"token": "test"}\n')
    (home_dir / ".ssh" / "config").write_text("Host *\n  StrictHostKeyChecking no\n")
    (home_dir / ".gitconfig").write_text("[user]\n\tname = Test User\n")
    (home_dir / ".zshrc").write_text("export TEST_ZSHRC=1\n")
    (home_dir / ".vimrc").write_text("set number\n")
    (home_dir / ".tmux.conf").write_text("set -g mouse on\n")
    return home_dir


def _prepare_fake_native_claude_install(home_dir, version="2.1.63"):
    versions_dir = home_dir / ".local" / "share" / "claude" / "versions"
    versions_dir.mkdir(parents=True, exist_ok=True)
    binary_path = versions_dir / version
    binary_path.write_text("#!/bin/sh\nexit 0\n")
    binary_path.chmod(0o755)

    bin_dir = home_dir / ".local" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    claude_link = bin_dir / "claude"
    if claude_link.exists() or claude_link.is_symlink():
        claude_link.unlink()
    claude_link.symlink_to(binary_path)
    return claude_link, versions_dir


@pytest.fixture
def isolated_am_dir(tmp_path):
    am_dir = tmp_path / "agent-manager"
    am_dir.mkdir()
    (am_dir / "sessions.json").write_text('{"sessions":{}}\n')
    return am_dir


@pytest.fixture
def fake_home(tmp_path):
    return _prepare_fake_home(tmp_path / "home")


@pytest.fixture
def fake_ssh_agent_socket(tmp_path):
    sock_path = tmp_path / "ssh-agent.sock"
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(sock_path))
    server.listen(1)
    try:
        yield sock_path
    finally:
        server.close()


@pytest.fixture(scope="session", autouse=True)
def require_docker():
    if not AM_PATH.exists():
        pytest.skip(f"am script not found at {AM_PATH}")
    if not _docker_available():
        pytest.skip("Docker daemon unavailable or not accessible")


@pytest.fixture
def sandbox_context(tmp_path, isolated_am_dir):
    session_name = f"am-test-{uuid.uuid4().hex[:8]}"
    target_dir = tmp_path / f"sandbox-dir-{uuid.uuid4().hex[:8]}"
    target_dir.mkdir(parents=True, exist_ok=True)
    env = _base_env()
    env["AM_DIR"] = str(isolated_am_dir)
    yield {
        "session_name": session_name,
        "target_dir": target_dir,
        "env": env,
    }
    _run_sandbox_function(
        f"sandbox_remove '{session_name}'",
        env=env,
        check=False,
        timeout=120,
    )


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.security
def test_s001_hardened_defaults_present(sandbox_context):
    env = sandbox_context["env"]
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    container_name = _find_container(session_name)
    inspect = _inspect(container_name)
    host_config = inspect["HostConfig"]

    security_opt = host_config.get("SecurityOpt") or []
    assert "no-new-privileges:true" in security_opt

    cap_drop = host_config.get("CapDrop") or []
    assert "ALL" in cap_drop

    cap_add = _normalize_caps(host_config.get("CapAdd") or [])
    assert {"CHOWN", "DAC_OVERRIDE", "FOWNER"}.issubset(cap_add)

    assert host_config.get("PidsLimit") == 512
    assert host_config.get("Memory") == 4 * 1024 * 1024 * 1024
    assert host_config.get("NanoCpus") == 2_000_000_000


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.security
def test_s002_tailscale_privilege_gating(sandbox_context):
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    env_disabled = sandbox_context["env"].copy()
    env_disabled["SB_ENABLE_TAILSCALE"] = "0"
    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env_disabled,
        check=True,
    )

    container_name = _find_container(session_name)
    inspect_disabled = _inspect(container_name)["HostConfig"]
    cap_add_disabled = _normalize_caps(inspect_disabled.get("CapAdd") or [])
    devices_disabled = inspect_disabled.get("Devices") or []

    assert "NET_ADMIN" not in cap_add_disabled
    assert all(d.get("PathOnHost") != "/dev/net/tun" for d in devices_disabled)

    _run_sandbox_function(
        f"sandbox_remove '{session_name}'",
        env=env_disabled,
        check=False,
        timeout=120,
    )

    tun_path = pathlib.Path("/dev/net/tun")
    if not tun_path.exists():
        pytest.skip("/dev/net/tun is not available on this host")

    env_enabled = sandbox_context["env"].copy()
    env_enabled["SB_ENABLE_TAILSCALE"] = "1"
    env_enabled["TS_ENABLE_SSH"] = "0"
    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env_enabled,
        check=True,
    )

    container_name = _find_container(session_name)
    inspect_enabled = _inspect(container_name)["HostConfig"]
    cap_add_enabled = _normalize_caps(inspect_enabled.get("CapAdd") or [])
    devices_enabled = inspect_enabled.get("Devices") or []

    assert "NET_ADMIN" in cap_add_enabled
    assert any(d.get("PathOnHost") == "/dev/net/tun" for d in devices_enabled)


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.security
def test_s003_unsafe_mode_downgrade_is_explicit(sandbox_context):
    env = sandbox_context["env"].copy()
    env["SB_UNSAFE_ROOT"] = "1"
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    result = _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    combined = f"{result.stdout}\n{result.stderr}"
    assert "SB_UNSAFE_ROOT=1 disables hardened sudo/privilege restrictions." in combined

    container_name = _find_container(session_name)
    _wait_for_running(container_name, timeout=45)
    inspect = _inspect(container_name)
    host_config = inspect["HostConfig"]

    security_opt = host_config.get("SecurityOpt") or []
    assert "no-new-privileges:true" not in security_opt

@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.security
def test_s004_sensitive_mount_modes_enforced(sandbox_context, fake_home):
    env = sandbox_context["env"].copy()
    env["HOME"] = str(fake_home)
    env["SB_HOME"] = str(fake_home / ".sb")
    fake_home.joinpath(".claude.json").write_text('{"installMethod": "native"}\n')
    _prepare_fake_native_claude_install(fake_home)

    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]
    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )

    container_name = _find_container(session_name)
    _wait_for_running(container_name, timeout=45)
    inspect = _inspect(container_name)

    ro_destinations = [
        f"{fake_home}/.codex/auth.json",
        f"{fake_home}/.ssh",
        f"{fake_home}/.gitconfig",
        f"{fake_home}/.zshrc",
        f"{fake_home}/.vimrc",
        f"{fake_home}/.tmux.conf",
    ]
    for destination in ro_destinations:
        assert _container_mount(inspect, destination)["RW"] is False

    assert _container_mount(inspect, f"{fake_home}/.claude.json")["RW"] is True
    assert _container_mount(inspect, f"{fake_home}/.claude")["RW"] is True
    assert _container_mount(inspect, f"{fake_home}/.local/bin/claude")["RW"] is False
    assert (
        _container_mount(inspect, f"{fake_home}/.local/share/claude/versions")["RW"] is False
    )
    assert _container_mount(inspect, f"{fake_home}/.codex/config.toml")["RW"] is True

    ro_write_attempts = {
        "codex_auth": f"echo nope >> '{fake_home}/.codex/auth.json'",
        "ssh_dir": f"touch '{fake_home}/.ssh/blocked'",
        "gitconfig": f"echo nope >> '{fake_home}/.gitconfig'",
        "native_claude_bin": f"echo nope >> '{fake_home}/.local/bin/claude'",
    }
    for label, shell_cmd in ro_write_attempts.items():
        result = _run(
            ["docker", "exec", container_name, "sh", "-lc", shell_cmd],
            check=False,
            timeout=60,
        )
        assert result.returncode != 0, f"{label} unexpectedly allowed writes"

    rw_write_attempts = {
        "claude_json": f"echo '{{\"test\": false}}' > '{fake_home}/.claude.json'",
        "claude_dir": f"touch '{fake_home}/.claude/allowed'",
        "codex_config": f"echo '# test' >> '{fake_home}/.codex/config.toml'",
    }
    for label, shell_cmd in rw_write_attempts.items():
        result = _run(
            ["docker", "exec", container_name, "sh", "-lc", shell_cmd],
            check=False,
            timeout=60,
        )
        assert result.returncode == 0, f"{label} unexpectedly rejected writes"


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.security
def test_s005_read_only_rootfs_mode_enforced(sandbox_context):
    env = sandbox_context["env"].copy()
    env["SB_READ_ONLY_ROOTFS"] = "1"
    env["SB_ENABLE_TAILSCALE"] = "0"
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    container_name = _find_container(session_name)
    _wait_for_running(container_name, timeout=45)

    inspect = _inspect(container_name)
    assert inspect["HostConfig"].get("ReadonlyRootfs") is True

    write_attempt = _run(
        ["docker", "exec", container_name, "sh", "-lc", "echo test > /sb-rootfs-write-check"],
        check=False,
        timeout=60,
    )
    assert write_attempt.returncode != 0, "Unexpectedly wrote to read-only rootfs"

    tmp_write = _run(
        ["docker", "exec", container_name, "sh", "-lc", "echo ok > /tmp/sb-tmp-write-check"],
        check=False,
        timeout=60,
    )
    assert tmp_write.returncode == 0, tmp_write.stderr


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.security
def test_s006_stale_runtime_settings_trigger_recreate(sandbox_context, fake_home):
    env = sandbox_context["env"].copy()
    env["HOME"] = str(fake_home)
    env["SB_HOME"] = str(fake_home / ".sb")
    fake_home.joinpath(".claude.json").write_text('{"installMethod": "native"}\n')
    _prepare_fake_native_claude_install(fake_home)

    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]
    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    _run_sandbox_function(
        f"sandbox_remove '{session_name}'",
        env=env,
        check=False,
        timeout=120,
    )

    host_user = subprocess.run(
        ["id", "-un"], text=True, capture_output=True, check=True
    ).stdout.strip()
    host_uid = subprocess.run(
        ["id", "-u"], text=True, capture_output=True, check=True
    ).stdout.strip()
    host_gid = subprocess.run(
        ["id", "-g"], text=True, capture_output=True, check=True
    ).stdout.strip()

    _run(
        [
            "docker",
            "run",
            "-d",
            "--name",
            session_name,
            "--hostname",
            session_name,
            "--label",
            "agent-sandbox=true",
            "--label",
            f"agent-sandbox.session={session_name}",
            "--label",
            f"agent-sandbox.dir={target_dir}",
            "--restart",
            "unless-stopped",
            "-v",
            f"{target_dir}:{target_dir}",
            "-v",
            f"{fake_home}/.claude.json:{fake_home}/.claude.json:ro",
            "-v",
            f"{fake_home}/.claude:{fake_home}/.claude:ro",
            "-v",
            f"{fake_home}/.codex/config.toml:{fake_home}/.codex/config.toml",
            "-v",
            f"{fake_home}/.codex/auth.json:{fake_home}/.codex/auth.json:ro",
            "-e",
            f"HOST_USER={host_user}",
            "-e",
            f"HOST_UID={host_uid}",
            "-e",
            f"HOST_GID={host_gid}",
            "-e",
            f"HOST_HOME={fake_home}",
            "-e",
            f"TARGET_DIR={target_dir}",
            "-e",
            "SB_ENABLE_TAILSCALE=0",
            "-e",
            "ENABLE_SSH=0",
            "-e",
            "TS_ENABLE_SSH=0",
            "-e",
            "SB_UNSAFE_ROOT=0",
            "-e",
            "SB_READ_ONLY_ROOTFS=0",
            "agent-sandbox:persistent",
        ],
        check=True,
        timeout=120,
    )
    _wait_for_running(session_name, timeout=45)

    result = _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    output = f"{result.stdout}\n{result.stderr}"
    assert "Recreating sandbox" in output

    inspect = _inspect(session_name)
    assert _container_mount(inspect, f"{fake_home}/.claude.json")["RW"] is True
    assert _container_mount(inspect, f"{fake_home}/.claude")["RW"] is True
    assert _container_mount(inspect, f"{fake_home}/.local/bin/claude")["RW"] is False
    assert (
        _container_mount(inspect, f"{fake_home}/.local/share/claude/versions")["RW"] is False
    )

    cap_add = _normalize_caps(inspect["HostConfig"].get("CapAdd") or [])
    assert {"CHOWN", "DAC_OVERRIDE", "FOWNER"}.issubset(cap_add)


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.security
def test_s007_ssh_agent_forwarding_gated_by_socket_presence(
    sandbox_context, fake_home, fake_ssh_agent_socket
):
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    env_missing = sandbox_context["env"].copy()
    env_missing["HOME"] = str(fake_home)
    env_missing["SB_HOME"] = str(fake_home / ".sb")
    env_missing["SB_FORWARD_SSH_AGENT"] = "1"
    env_missing["SSH_AUTH_SOCK"] = str(fake_home / "missing-agent.sock")

    missing_result = _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env_missing,
        check=True,
    )
    missing_output = f"{missing_result.stdout}\n{missing_result.stderr}"
    assert "SB_FORWARD_SSH_AGENT=1 but SSH_AUTH_SOCK is not available." in missing_output

    inspect_missing = _inspect(session_name)
    assert not any(m.get("Destination") == "/ssh-agent" for m in inspect_missing.get("Mounts", []))

    _run_sandbox_function(
        f"sandbox_remove '{session_name}'",
        env=env_missing,
        check=False,
        timeout=120,
    )

    env_present = sandbox_context["env"].copy()
    env_present["HOME"] = str(fake_home)
    env_present["SB_HOME"] = str(fake_home / ".sb")
    env_present["SB_FORWARD_SSH_AGENT"] = "1"
    env_present["SSH_AUTH_SOCK"] = str(fake_ssh_agent_socket)

    present_result = _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env_present,
        check=True,
    )
    present_output = f"{present_result.stdout}\n{present_result.stderr}"
    assert "SB_FORWARD_SSH_AGENT=1 but SSH_AUTH_SOCK is not available." not in present_output

    inspect_present = _inspect(session_name)
    ssh_agent_mount = _container_mount(inspect_present, "/ssh-agent")
    assert ssh_agent_mount["RW"] is True
    assert pathlib.Path(ssh_agent_mount["Source"]) == fake_ssh_agent_socket


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.ux
def test_u001_start_output_shows_host_global_identity_sources(sandbox_context, fake_home):
    env = sandbox_context["env"].copy()
    env["HOME"] = str(fake_home)
    env["SB_HOME"] = str(fake_home / ".sb")
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    result = _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    output = f"{result.stdout}\n{result.stderr}"

    assert f"Using host-global Claude JSON: {fake_home}/.claude.json" in output
    assert f"Using host-global Claude directory: {fake_home}/.claude" in output
    assert f"Using host-global Codex config: {fake_home}/.codex/config.toml" in output
    assert f"Using host-global Codex auth: {fake_home}/.codex/auth.json" in output
    assert f"Using host-global SSH identity: {fake_home}/.ssh" in output


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.ux
def test_u002_start_output_shows_sandbox_identity_sources(sandbox_context, fake_home):
    env = sandbox_context["env"].copy()
    env["HOME"] = str(fake_home)
    env["SB_HOME"] = str(fake_home / ".sb")
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function("sandbox_identity_init", env=env, check=True)
    result = _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    output = f"{result.stdout}\n{result.stderr}"

    assert f"Using sandbox Claude JSON: {fake_home}/.sb/claude.json" in output
    assert f"Using sandbox Claude directory: {fake_home}/.sb/claude" in output
    assert f"Using sandbox Codex config: {fake_home}/.sb/codex/config.toml" in output
    assert f"Using sandbox Codex auth: {fake_home}/.sb/codex/auth.json" in output
    assert f"Using sandbox SSH identity: {fake_home}/.sb/ssh" in output


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
@pytest.mark.ux
def test_f001_status_output_for_running_and_not_found_states(sandbox_context):
    env = sandbox_context["env"]
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    _wait_for_running(session_name, timeout=45)

    running = _run_sandbox_function(f"sandbox_status '{session_name}'", env=env, check=True)
    running_output = f"{running.stdout}\n{running.stderr}"
    assert f"Container: {session_name}" in running_output
    assert f"Directory: {target_dir}" in running_output
    assert "Status:    running" in running_output
    assert "Tailscale: n/a" in running_output

    missing_name = f"am-missing-{uuid.uuid4().hex[:8]}"
    not_found = _run_sandbox_function(f"sandbox_status '{missing_name}'", env=env, check=True)
    not_found_output = f"{not_found.stdout}\n{not_found.stderr}"
    assert f"Container: {missing_name}" in not_found_output
    assert "Status:    not found" in not_found_output


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
def test_f002_shell_runtime_checks_from_sb_suite(sandbox_context):
    env = sandbox_context["env"]
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    _wait_for_running(session_name, timeout=45)

    for script_name in (
        "test_claude_mount.sh",
        "test_codex_permissions.sh",
        "test_cap_chown.sh",
    ):
        script_path = REPO_ROOT / "tests" / script_name
        result = _run([str(script_path), session_name], check=True, timeout=60)
        assert "FAIL:" not in f"{result.stdout}\n{result.stderr}"
