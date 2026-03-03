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


# ---------------------------------------------------------------------------
# F-001: First-run create + start
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
def test_f001_first_run_create_and_start(sandbox_context):
    env = sandbox_context["env"]
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
    labels = inspect["Config"]["Labels"]
    assert labels.get("agent-sandbox") == "true"
    assert labels.get("agent-sandbox.session") == session_name
    assert labels.get("agent-sandbox.dir") == str(target_dir)


# ---------------------------------------------------------------------------
# F-002: Reuse existing running sandbox
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
def test_f002_reuse_existing_running_sandbox(sandbox_context):
    env = sandbox_context["env"]
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    _wait_for_running(session_name, timeout=45)

    first_id = _inspect(session_name)["Id"]

    result = _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    output = f"{result.stdout}\n{result.stderr}"
    assert "already running" in output

    second_id = _inspect(session_name)["Id"]
    assert first_id == second_id

    # Verify no duplicate containers
    ps_result = _run(
        ["docker", "ps", "-a", "--filter", f"name={session_name}", "--format", "{{.Names}}"],
        check=True,
    )
    names = [n.strip() for n in ps_result.stdout.splitlines() if n.strip()]
    assert len(names) == 1


# ---------------------------------------------------------------------------
# F-003: Label-based session mapping
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
def test_f003_label_based_session_mapping(sandbox_context):
    env = sandbox_context["env"]
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    _wait_for_running(session_name, timeout=45)

    inspect = _inspect(session_name)
    labels = inspect["Config"]["Labels"]
    assert labels["agent-sandbox"] == "true"
    assert labels["agent-sandbox.session"] == session_name
    assert labels["agent-sandbox.dir"] == str(target_dir)
    assert str(target_dir) == os.path.abspath(str(target_dir))


# ---------------------------------------------------------------------------
# F-004: sandbox_start idempotency
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
def test_f004_sandbox_start_idempotency(sandbox_context):
    env = sandbox_context["env"]
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    _wait_for_running(session_name, timeout=45)
    first_id = _inspect(session_name)["Id"]

    result = _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    assert result.returncode == 0

    second_id = _inspect(session_name)["Id"]
    assert first_id == second_id


# ---------------------------------------------------------------------------
# F-005: Attach failure when not running (restore lost test)
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
def test_f005_attach_failure_when_not_running(sandbox_context):
    env = sandbox_context["env"]
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    _wait_for_running(session_name, timeout=45)

    _run_sandbox_function(
        f"sandbox_stop '{session_name}'",
        env=env,
        check=True,
    )
    # Wait for container to stop
    for _ in range(15):
        state = _container_state(session_name)
        if state != "running":
            break
        time.sleep(1)

    # Attempt docker exec on the stopped container — should fail
    attach_cmd = _run_sandbox_function(
        f"sandbox_attach_cmd '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    exec_cmd = attach_cmd.stdout.strip()
    # Run the generated exec command (without -it since we're non-interactive)
    exec_result = _run(
        ["docker", "exec", session_name, "echo", "hello"],
        check=False,
        timeout=30,
    )
    assert exec_result.returncode != 0


# ---------------------------------------------------------------------------
# F-007: sandbox_stop + resume
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
def test_f007_stop_and_resume(sandbox_context):
    env = sandbox_context["env"]
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    _wait_for_running(session_name, timeout=45)

    _run_sandbox_function(
        f"sandbox_stop '{session_name}'",
        env=env,
        check=True,
    )
    for _ in range(15):
        state = _container_state(session_name)
        if state != "running":
            break
        time.sleep(1)
    assert _container_state(session_name) != "running"

    # Resume via sandbox_start
    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    _wait_for_running(session_name, timeout=45)
    assert _container_state(session_name) == "running"


# ---------------------------------------------------------------------------
# F-008: sandbox_remove cleanup
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
def test_f008_sandbox_remove_cleanup(sandbox_context):
    env = sandbox_context["env"]
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    _wait_for_running(session_name, timeout=45)

    _run_sandbox_function(
        f"sandbox_remove '{session_name}'",
        env=env,
        check=True,
    )

    ps_result = _run(
        ["docker", "ps", "-a", "--filter", f"name=^{session_name}$", "--format", "{{.Names}}"],
        check=True,
    )
    names = [n.strip() for n in ps_result.stdout.splitlines() if n.strip()]
    assert len(names) == 0, f"Container still exists after remove: {names}"


# ---------------------------------------------------------------------------
# F-009: sandbox_list and sandbox_prune
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
def test_f009_sandbox_list_and_prune(tmp_path, isolated_am_dir):
    env = _base_env()
    env["AM_DIR"] = str(isolated_am_dir)

    running_session = f"am-test-run-{uuid.uuid4().hex[:8]}"
    stopped_session = f"am-test-stp-{uuid.uuid4().hex[:8]}"
    running_dir = tmp_path / "running-dir"
    stopped_dir = tmp_path / "stopped-dir"
    running_dir.mkdir()
    stopped_dir.mkdir()

    try:
        # Create running sandbox
        _run_sandbox_function(
            f"sandbox_start '{running_session}' '{running_dir}'",
            env=env,
            check=True,
        )
        _wait_for_running(running_session, timeout=45)

        # Create stopped sandbox
        _run_sandbox_function(
            f"sandbox_start '{stopped_session}' '{stopped_dir}'",
            env=env,
            check=True,
        )
        _wait_for_running(stopped_session, timeout=45)
        _run_sandbox_function(
            f"sandbox_stop '{stopped_session}'",
            env=env,
            check=True,
        )
        for _ in range(15):
            if _container_state(stopped_session) != "running":
                break
            time.sleep(1)

        # sandbox_list should show both
        list_result = _run_sandbox_function("sandbox_list", env=env, check=True)
        list_output = f"{list_result.stdout}\n{list_result.stderr}"
        assert running_session in list_output
        assert stopped_session in list_output

        # sandbox_prune should remove stopped, keep running
        _run_sandbox_function("sandbox_prune", env=env, check=True)

        # Running should survive
        assert _container_state(running_session) == "running"

        # Stopped should be gone
        ps_result = _run(
            ["docker", "ps", "-a", "--filter", f"name=^{stopped_session}$", "--format", "{{.Names}}"],
            check=True,
        )
        assert stopped_session not in ps_result.stdout

    finally:
        for s in (running_session, stopped_session):
            _run(["docker", "rm", "-f", s], check=False, timeout=30)


# ---------------------------------------------------------------------------
# S-007: Environment secret leakage
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.security
def test_s007_environment_secret_leakage(sandbox_context):
    env = sandbox_context["env"].copy()
    # Inject a host-only secret that should NOT appear in the container
    env["MY_SECRET_TOKEN"] = "super-secret-value-12345"
    env["AWS_SECRET_ACCESS_KEY"] = "fake-aws-key-67890"
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env,
        check=True,
    )
    _wait_for_running(session_name, timeout=45)

    result = _run(
        ["docker", "exec", session_name, "env"],
        check=True,
        timeout=30,
    )
    container_env = result.stdout

    # Intended vars should be present
    intended_prefixes = ("HOST_USER=", "HOST_UID=", "HOST_GID=", "HOST_HOME=", "TARGET_DIR=",
                         "SB_ENABLE_TAILSCALE=", "ENABLE_SSH=", "TS_ENABLE_SSH=",
                         "SB_UNSAFE_ROOT=", "SB_READ_ONLY_ROOTFS=", "SANDBOX_NAME=", "TERM=")
    for prefix in intended_prefixes:
        assert any(line.startswith(prefix) for line in container_env.splitlines()), \
            f"Expected env var starting with {prefix!r} not found"

    # Host-only secrets must NOT leak
    assert "MY_SECRET_TOKEN" not in container_env
    assert "super-secret-value-12345" not in container_env
    assert "AWS_SECRET_ACCESS_KEY" not in container_env
    assert "fake-aws-key-67890" not in container_env


# ---------------------------------------------------------------------------
# U-002: Invalid directory error (restore lost test)
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.ux
def test_u002_invalid_directory_error(sandbox_context):
    env = sandbox_context["env"]
    session_name = sandbox_context["session_name"]

    # Docker run with a nonexistent bind-mount source will fail
    result = _run_sandbox_function(
        f"sandbox_start '{session_name}' '/nonexistent/path/does/not/exist'",
        env=env,
        check=False,
        timeout=120,
    )
    assert result.returncode != 0, "sandbox_start should fail for nonexistent directory"


# ---------------------------------------------------------------------------
# U-003: Warning usefulness (restore lost test)
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.ux
def test_u003_warning_usefulness_conflicting_envs(sandbox_context):
    session_name = sandbox_context["session_name"]
    target_dir = sandbox_context["target_dir"]

    # Case 1: SB_ENABLE_TAILSCALE=0 + TS_ENABLE_SSH=1 → warning about conflict
    env_conflict = sandbox_context["env"].copy()
    env_conflict["SB_ENABLE_TAILSCALE"] = "0"
    env_conflict["TS_ENABLE_SSH"] = "1"
    result1 = _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env_conflict,
        check=True,
    )
    output1 = f"{result1.stdout}\n{result1.stderr}"
    assert "TS_ENABLE_SSH=1 ignored because SB_ENABLE_TAILSCALE=0" in output1

    _run_sandbox_function(
        f"sandbox_remove '{session_name}'",
        env=env_conflict,
        check=False,
        timeout=120,
    )

    # Case 2: SB_ENABLE_TAILSCALE=1 + no TS_AUTHKEY → warning about missing key
    tun_path = pathlib.Path("/dev/net/tun")
    if not tun_path.exists():
        pytest.skip("/dev/net/tun not available for tailscale test")

    env_no_key = sandbox_context["env"].copy()
    env_no_key["SB_ENABLE_TAILSCALE"] = "1"
    env_no_key.pop("TS_AUTHKEY", None)
    result2 = _run_sandbox_function(
        f"sandbox_start '{session_name}' '{target_dir}'",
        env=env_no_key,
        check=True,
    )
    output2 = f"{result2.stdout}\n{result2.stderr}"
    assert "TS_AUTHKEY" in output2 and "unset" in output2


# ---------------------------------------------------------------------------
# F-011: sandbox_identity_init quality
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
def test_f011_sandbox_identity_init_quality(tmp_path, isolated_am_dir, fake_home):
    env = _base_env()
    env["AM_DIR"] = str(isolated_am_dir)
    env["HOME"] = str(fake_home)
    sb_home = tmp_path / "clean_sb"
    env["SB_HOME"] = str(sb_home)

    _run_sandbox_function("sandbox_identity_init", env=env, check=True)

    # SSH directory and key
    ssh_dir = sb_home / "ssh"
    assert ssh_dir.is_dir()
    assert oct(ssh_dir.stat().st_mode & 0o777) == oct(0o700)

    private_key = ssh_dir / "id_ed25519"
    assert private_key.is_file()
    assert oct(private_key.stat().st_mode & 0o777) == oct(0o600)

    public_key = ssh_dir / "id_ed25519.pub"
    assert public_key.is_file()
    assert oct(public_key.stat().st_mode & 0o777) == oct(0o644)

    ssh_config = ssh_dir / "config"
    assert ssh_config.is_file()

    # Claude directory and JSON
    assert (sb_home / "claude").is_dir()
    assert (sb_home / "claude.json").is_file()

    # Codex directory
    codex_dir = sb_home / "codex"
    assert codex_dir.is_dir()
    assert (codex_dir / "config.toml").is_file()
    assert (codex_dir / "auth.json").is_file()


# ---------------------------------------------------------------------------
# F-014: sandbox_gc_orphans
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.functional
def test_f014_sandbox_gc_orphans(tmp_path, isolated_am_dir):
    env = _base_env()
    env["AM_DIR"] = str(isolated_am_dir)

    # Create a container with agent-sandbox labels but no matching tmux session
    orphan_name = f"am-test-orphan-{uuid.uuid4().hex[:8]}"
    orphan_dir = tmp_path / "orphan-dir"
    orphan_dir.mkdir()

    try:
        _run_sandbox_function(
            f"sandbox_start '{orphan_name}' '{orphan_dir}'",
            env=env,
            check=True,
        )
        _wait_for_running(orphan_name, timeout=45)

        # sandbox_gc_orphans needs tmux_session_exists — source tmux.sh too
        am_dir = pathlib.Path(env["AM_DIR"])
        gc_command = (
            f"export AM_SCRIPT_DIR='{REPO_ROOT}'; "
            f"export AM_DIR='{am_dir}'; "
            f"source '{LIB_DIR / 'utils.sh'}'; "
            f"source '{LIB_DIR / 'tmux.sh'}'; "
            f"source '{LIB_DIR / 'sandbox.sh'}'; "
            f"sandbox_gc_orphans"
        )
        result = _run(["bash", "-lc", gc_command], env=env, check=True, timeout=120)
        removed_count = int(result.stdout.strip())
        assert removed_count >= 1, f"Expected at least 1 orphan removed, got {removed_count}"

        # Verify container is gone
        ps_result = _run(
            ["docker", "ps", "-a", "--filter", f"name=^{orphan_name}$", "--format", "{{.Names}}"],
            check=True,
        )
        assert orphan_name not in ps_result.stdout

    finally:
        _run(["docker", "rm", "-f", orphan_name], check=False, timeout=30)


# ---------------------------------------------------------------------------
# S-008: Multi-tenant separation
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.docker
@pytest.mark.security
def test_s008_multi_tenant_separation(tmp_path, isolated_am_dir):
    env = _base_env()
    env["AM_DIR"] = str(isolated_am_dir)

    session_a = f"am-test-tena-{uuid.uuid4().hex[:8]}"
    session_b = f"am-test-tenb-{uuid.uuid4().hex[:8]}"
    dir_a = tmp_path / "project-a"
    dir_b = tmp_path / "project-b"
    dir_a.mkdir()
    dir_b.mkdir()
    (dir_a / "secret_a.txt").write_text("secret-from-project-a\n")
    (dir_b / "secret_b.txt").write_text("secret-from-project-b\n")

    try:
        _run_sandbox_function(
            f"sandbox_start '{session_a}' '{dir_a}'",
            env=env,
            check=True,
        )
        _run_sandbox_function(
            f"sandbox_start '{session_b}' '{dir_b}'",
            env=env,
            check=True,
        )
        _wait_for_running(session_a, timeout=45)
        _wait_for_running(session_b, timeout=45)

        # Container A should NOT see project B's directory
        result_a = _run(
            ["docker", "exec", session_a, "ls", str(dir_b)],
            check=False,
            timeout=30,
        )
        assert result_a.returncode != 0 or "secret_b.txt" not in result_a.stdout

        # Container B should NOT see project A's directory
        result_b = _run(
            ["docker", "exec", session_b, "ls", str(dir_a)],
            check=False,
            timeout=30,
        )
        assert result_b.returncode != 0 or "secret_a.txt" not in result_b.stdout

        # Each sees only its own directory
        inspect_a = _inspect(session_a)
        inspect_b = _inspect(session_b)
        labels_a = inspect_a["Config"]["Labels"]
        labels_b = inspect_b["Config"]["Labels"]
        assert labels_a["agent-sandbox.dir"] == str(dir_a)
        assert labels_b["agent-sandbox.dir"] == str(dir_b)

    finally:
        for s in (session_a, session_b):
            _run(["docker", "rm", "-f", s], check=False, timeout=30)
