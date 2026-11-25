"""Exercise complete native server/player games and preserve all test artifacts."""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class FixtureServer(ThreadingHTTPServer):
    def __init__(self, address, handler, *, fail_turn=None, http_status=200):
        super().__init__(address, handler)
        self.fail_turn = fail_turn
        self.http_status = http_status
        self.calls_lock = threading.Lock()
        self.called_slots = []


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        user = body["messages"][0]["content"]
        turn = int(re.match(r"Turn (\d+) of", user).group(1))
        slot = self.headers["X-Coworld-Player-Slot"]
        with self.server.calls_lock:
            self.server.called_slots.append((turn, int(slot)))
        assert "PRIVATE_OPERATOR_" + slot in user
        assert all("PRIVATE_OPERATOR_" + str(i) not in user for i in range(6) if str(i) != slot)
        assert "SPECTATOR_POLICY_" not in user and "SPECTATOR_POLICY_" not in body["system"]
        failed_call = turn == self.server.fail_turn and slot == "5"
        if failed_call or (turn == self.server.fail_turn and slot == "2" and self.server.http_status != 200):
            text = 'invalid fixture reply before {"action":"I wait."}'
        else:
            notes = "PRIVATE_CAPTURE_" + slot
            if turn == 3:
                notes = "é" * 5000
            action = {
                "action": "flibbertigibbet" if turn == 4 else "I wait by the well and listen.",
                "say": f"PUBLIC_TURN_{turn}_{slot}",
                "notes": notes,
            }
            # Omitted optional fields keep their native empty defaults.
            if turn == 6:
                action.pop("say")
                action.pop("notes")
            text = json.dumps(action)
            if turn in (2, 3):
                label = "json" if turn == 2 else ""
                text = f"```{label}\n{text}\n```"
        response = json.dumps(
            {
                "model": body["model"],
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": text}],
                "usage": None if turn == 5 else {"input_tokens": 100, "output_tokens": 20},
            }
        ).encode()
        self.send_response(self.server.http_status if failed_call else 200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid5(uuid.NAMESPACE_URL, raw.decode())))
        self.end_headers()
        self.wfile.write(response)


def run(
    game,
    player,
    output,
    variant,
    capture,
    *,
    label,
    seat_modes,
    model_enabled=True,
    fail_turn=None,
    expect_failure=False,
    http_status=200,
):
    root = output / label
    root.mkdir(mode=0o700)
    config = dict(variant["game_config"])
    seats = 6
    config.update(
        seed=42,
        turnDelayMs=0,
        shutdownGraceSeconds=0,
        players=[{"name": f"SPECTATOR_POLICY_{i}"} for i in range(seats)],
        llmTimeoutSeconds=1,
        player_connect_timeout_seconds=5,
        episodeTimeoutSeconds=600,
        tokens=[f"fixture-{i}" for i in range(seats)],
    )
    (root / "config.json").write_text(json.dumps(config))
    with socket.socket() as candidate:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    env = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "COWORLD_LLM_MODEL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "AWS_BEARER_TOKEN_BEDROCK",
    ):
        env.pop(key, None)
    episode = f"cogmud-native-capture-fixture-{label}"
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(root / "config.json").as_uri(),
        COGAME_RESULTS_URI=(root / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(root / "replay.json").as_uri(),
        COGAME_PLAYER_FAILURE_URI=(root / "player_failure.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID=episode,
        COWORLD_GAME_VERSION="identity-fixture",
        COWORLD_SOURCE_REVISION="a" * 40,
    )
    if not capture:
        env.pop("COGAME_SAVE_TRAJECTORY_URI")
    provider = FixtureServer(("127.0.0.1", 0), Provider, fail_turn=fail_turn, http_status=http_status)
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    if model_enabled:
        env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{provider.server_port}"
        env["COWORLD_LLM_MODEL"] = "native-capture-fixture"
    children = []
    streams = []
    try:
        log = (root / "game.log").open("wb")
        streams.append(log)
        server = subprocess.Popen([str(game)], env=env, stdout=log, stderr=subprocess.STDOUT)
        children.append(server)
        for _ in range(100):
            assert server.poll() is None, "game exited before readiness; see retained game.log"
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
                    assert response.status == 200
                break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.05)
        else:
            raise TimeoutError("native game did not become ready")
        for seat in range(seats):
            log = (root / f"player-{seat}.log").open("wb")
            streams.append(log)
            player_env = dict(env, PLAYER_PROMPT=f"PRIVATE_OPERATOR_{seat}", COWORLD_TIMEOUT_SECONDS="600")
            if seat_modes[seat]:
                player_env["PLAYER_SCRIPTED"] = seat_modes[seat]
            else:
                player_env.pop("PLAYER_SCRIPTED", None)
            player_env["COWORLD_PLAYER_WS_URL"] = f"ws://127.0.0.1:{port}/player?slot={seat}&token=fixture-{seat}"
            children.append(subprocess.Popen([str(player)], env=player_env, stdout=log, stderr=subprocess.STDOUT))

        rc = server.wait(timeout=360)
        for child in children[1:]:
            assert child.wait(timeout=10) == 0

        model_seats = {seat for seat, mode in enumerate(seat_modes) if not mode}
        last_turn = (fail_turn or config["turns"]) if model_enabled else 0
        assert sorted(provider.called_slots) == [
            (turn, seat) for turn in range(1, last_turn + 1) for seat in sorted(model_seats)
        ]
        if expect_failure:
            assert rc != 0, f"expected explicit failure for {label}, got exit 0"
            assert not (root / "results.json").exists(), "failed episode must not write results.json"
            failure = json.loads((root / "player_failure.json").read_text())
            assert set(failure) == {"kind", "failed_policy_index", "message"}
            infrastructure = not model_enabled or http_status != 200
            assert failure["kind"] == ("episode_inconclusive" if infrastructure else "player_error")
            assert failure["failed_policy_index"] == (5 if model_enabled else 0)
            assert failure["message"] and "invalid fixture reply" not in failure["message"]
            for seat in range(seats):
                player_log = (root / f"player-{seat}.log").read_text()
                assert "final scores" not in player_log and "episode failed" in player_log
            if capture:
                trace = root / "trajectory.jsonl"
                rows = [json.loads(line) for line in trace.read_text().splitlines()]
                assert rows[-1]["status"] == "failed"
                assert rows[-1]["outcome"] == failure
                assert rows[-1]["participant_outcomes"] == {}
                failed_row = rows[-2]
                assert failed_row["selected_attempt_id"] is None
                assert failed_row["executed_action"] is None
                if fail_turn is not None:
                    assert failed_row["action_status"] == ("missing" if infrastructure else "rejected")
                    batch = [r for r in rows[:-1] if r["terminal"]]
                    assert {int(r["seat"]) for r in batch} == {0, 2, 5}
                    assert all(r["executed_action"] is None for r in batch)
                    assert all(len(r["attempts"]) == 1 for r in batch)
                    if infrastructure:
                        sibling = next(r for r in batch if int(r["seat"]) == 2)
                        assert sibling["action_status"] == "rejected"
                    assert all(not a["accepted"] for a in failed_row["attempts"])
                    assert "invalid fixture reply" in failed_row["attempts"][-1]["raw_response"]
                else:
                    assert failed_row["action_status"] == "missing"
            return failure

        assert rc == 0, f"expected exit 0 for {label}, got {rc}"
        assert not (root / "player_failure.json").exists()
        results = json.loads((root / "results.json").read_text())
        replay = json.loads((root / "replay.json").read_text())
        assert results["reason"] == "complete"
        assert results["turns"] == config["turns"] == 14

        events = [event for event in replay["events"] if event["kind"] == "act"]
        assert len(events) == 84
        for event in events:
            seat = event["seat"]
            turn = event["turn"] + 1
            if seat in model_seats:
                assert not event["scripted"]
                expected_sentence = "flibbertigibbet" if turn == 4 else "I wait by the well and listen."
                assert event["sentence"] == expected_sentence
            else:
                assert event["scripted"]

        if capture:
            trace = root / "trajectory.jsonl"
            rows = [json.loads(line) for line in trace.read_text().splitlines()]
            assert trace.stat().st_mode & 0o077 == 0
            assert rows[-1]["status"] == "completed" and rows[-1]["outcome"] == results
            assert rows[-1]["seed_family"] == "cogmud-42"
            assert len(events) == len(rows) - 1 == 84
            assert {row["decision_id"] for row in rows[:-1]} == {
                f"event-{i}" for i, event in enumerate(replay["events"]) if event["kind"] == "act"
            }
            for event, row in zip(events, rows[:-1], strict=True):
                seat = event["seat"]
                turn = event["turn"] + 1
                assert seat == int(row["seat"]) == row["observation"]["slot"]
                assert event["turn"] == row["observation"]["turn"]
                assert row["observation"]["turnsPlayed"] == event["turn"]
                assert not row["observation"]["done"]
                action = {
                    "action": event["sentence"],
                    "say": event.get("say", ""),
                    "notes": event.get("text", ""),
                }
                assert action == row["executed_action"]
                view = json.dumps(row["observation"], ensure_ascii=False)
                assert all(f"PRIVATE_CAPTURE_{i}" not in view for i in range(6) if i != seat)
                assert f"PUBLIC_TURN_{turn}_" not in json.dumps(row["observation"]["heard"])
                if seat not in model_seats:
                    assert row["action_status"] == "accepted"
                    assert len(row["attempts"]) == 1 and row["attempts"][0]["origin"] == "unknown"
                    assert row["attempts"][0]["platform_call_id"] is None
                    continue
                attempts = row["attempts"]
                assert len(attempts) == 1
                if turn == 3:
                    assert row["action_status"] == "rejected" and row["selected_attempt_id"] is None
                    assert not attempts[0]["accepted"]
                elif turn == 6:
                    # Empty notes retain the existing memory in the engine.
                    # Preserve the reply, but exclude this unequal action join.
                    assert row["action_status"] == "rejected" and row["selected_attempt_id"] is None
                    assert attempts[-1]["rejection_reason"] == "native engine normalized the proposal"
                else:
                    assert row["action_status"] == "accepted"
                    assert row["selected_attempt_id"] == attempts[-1]["attempt_id"]
                    if turn == 4:
                        assert event["reason"] == "no_verb"
                if turn == 5:
                    assert attempts[0]["input_tokens"] is None and attempts[0]["output_tokens"] is None
                for attempt in attempts:
                    assert attempt["prompt"][0]["content"] == attempt["request"]["system"]
                    assert attempt["platform_call_id"] is not None and attempt["behavior_logprobs"] is None
                    assert "SPECTATOR_POLICY_" not in json.dumps(attempt["prompt"])
                    assert "PRIVATE_OPERATOR_" + str(seat) in attempt["request"]["messages"][0]["content"]
        return results, replay
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=5)
        for child in children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        for stream in streams:
            stream.close()


def main():
    game, player, destination = map(lambda value: Path(value).resolve(), sys.argv[1:])
    destination.mkdir(mode=0o700, exist_ok=False)
    manifest = json.loads((Path(__file__).resolve().parents[1] / "coworld_manifest_template.json").read_text())
    mixed_modes = ["", "factor", "", "magpie", "factor", ""]
    baseline_modes = ["factor", "factor", "factor", "magpie", "factor", "factor"]
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [
            (
                pool.submit(
                    run, game, player, destination, variant, True,
                    label=f"{variant['id']}-mixed-captureTrue", seat_modes=mixed_modes,
                ),
                pool.submit(
                    run, game, player, destination, variant, False,
                    label=f"{variant['id']}-mixed-captureFalse", seat_modes=mixed_modes,
                ),
            )
            for variant in manifest["variants"]
        ]
        for captured, ordinary in futures:
            assert captured.result() == ordinary.result(), "capture changed the native outcome or replay"

    # Explicit baseline-only game completes offline with zero HTTP calls.
    captured = run(
        game, player, destination, manifest["variants"][0], True,
        label="standard-baselines-captureTrue", seat_modes=baseline_modes, model_enabled=False,
    )
    ordinary = run(
        game, player, destination, manifest["variants"][0], False,
        label="standard-baselines-captureFalse", seat_modes=baseline_modes, model_enabled=False,
    )
    assert captured == ordinary, "capture changed the baseline-only game"

    # Invalid model reply ends explicitly and preserves raw data.
    run(
        game, player, destination, manifest["variants"][0], True,
        label="standard-model-reply-failure", seat_modes=mixed_modes,
        model_enabled=True, fail_turn=2, expect_failure=True,
    )

    run(
        game, player, destination, manifest["variants"][0], True,
        label="standard-provider-failure", seat_modes=mixed_modes,
        fail_turn=2, http_status=503, expect_failure=True,
    )

    # Model seat with no credentials fails explicitly (no implicit fallback).
    run(
        game, player, destination, manifest["variants"][0], True,
        label="standard-missing-creds-failure", seat_modes=mixed_modes,
        model_enabled=False, expect_failure=True,
    )

    print(
        "nine native games: HTTP model vs explicit baselines, replay parity, single requests, "
        "markdown JSON fence, normalization, legal no-op, privacy, missing usage, "
        "offline baselines, and explicit failure without fallback pass"
    )


if __name__ == "__main__":
    main()
