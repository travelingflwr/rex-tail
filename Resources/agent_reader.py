# Rex's Tail remote agent reader.
#
# Rex's Tail runs this on another machine over SSH (`ssh HOST python3 -u -c ...`).
# It only reads: Claude Code and Codex session logs under the user's home.
# Each request is one JSON line on stdin:
#   {"agents": [{"id": "...", "kind": "claude"|"codex", "pid": 123, "cwd": "/path"}]}
# and each reply is one JSON line on stdout, keyed by id. It remembers how far
# it has read each log, so later requests only parse new lines.
import glob
import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")


class Log:
    def __init__(self, path):
        self.path = path
        self.offset = 0
        self.partial = b""
        self.reset()

    def update(self):
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return
        if size < self.offset:
            self.offset, self.partial = 0, b""
            self.reset()
        if size == self.offset:
            return
        with open(self.path, "rb") as f:
            f.seek(self.offset)
            data = f.read()
        self.offset += len(data)
        lines = (self.partial + data).split(b"\n")
        self.partial = lines.pop()
        for line in lines:
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                self.consume(entry)


class ClaudeLog(Log):
    def reset(self):
        self.messages, self.turns, self.context, self.model = {}, 0, 0, None

    def consume(self, e):
        side = e.get("isSidechain") is True
        kind = e.get("type")
        if kind == "assistant":
            m = e.get("message") or {}
            u = m.get("usage")
            if not isinstance(u, dict):
                return
            usage = [u.get("input_tokens") or 0, u.get("cache_read_input_tokens") or 0,
                     u.get("cache_creation_input_tokens") or 0, u.get("output_tokens") or 0]
            self.messages[m.get("id") or "_%d" % len(self.messages)] = usage
            if not side:
                self.context = sum(usage)
                if m.get("model") and m["model"] != "<synthetic>":
                    self.model = m["model"]
        elif kind == "user" and not side and e.get("isMeta") is not True:
            c = (e.get("message") or {}).get("content")
            if isinstance(c, str) or (isinstance(c, list) and not any(
                    isinstance(p, dict) and p.get("type") == "tool_result" for p in c)):
                self.turns += 1

    def stats(self):
        usage = [sum(m[i] for m in self.messages.values()) for i in range(4)]
        return {"turns": self.turns, "context": self.context, "usage": usage, "model": self.model}


class CodexLog(Log):
    def reset(self):
        self.usage, self.turns, self.tasks, self.context = [0, 0, 0, 0], 0, 0, 0
        self.window = self.model = self.started = None
        self.busy = False

    def consume(self, e):
        p, kind = e.get("payload"), e.get("type")
        if not isinstance(p, dict):
            return
        if kind == "session_meta":
            self.started = self.started or p.get("timestamp")
        elif kind == "turn_context":
            self.model = p.get("model") or self.model
        elif kind == "event_msg":
            t = p.get("type")
            if t == "user_message":
                self.turns += 1
            elif t == "task_started":
                self.busy = True
                self.tasks += 1
            elif t in ("task_complete", "turn_aborted"):
                self.busy = False
            elif t == "token_count":
                info = p.get("info") or {}
                tu = info.get("total_token_usage") or {}
                inp, cached = tu.get("input_tokens") or 0, tu.get("cached_input_tokens") or 0
                self.usage = [max(inp - cached, 0), cached,
                              tu.get("cache_write_input_tokens") or 0, tu.get("output_tokens") or 0]
                if sum(self.usage) == 0 and tu.get("total_tokens"):
                    self.usage[0] = tu["total_tokens"]
                last = info.get("last_token_usage") or {}
                self.context = last.get("total_tokens") or self.context
                self.window = info.get("model_context_window") or self.window

    def stats(self):
        return {"turns": max(self.turns, self.tasks), "context": self.context, "window": self.window,
                "usage": self.usage, "model": self.model, "startedISO": self.started, "busy": self.busy}


logs = {}
codex_paths = {}
touched = set()


def get_log(cls, path):
    log = logs.get(path)
    if log is None:
        log = logs[path] = cls(path)
    touched.add(path)
    log.update()
    return log


def process_start(pid):
    try:
        stat = open("/proc/%d/stat" % pid).read()
        fields = stat[stat.rfind(")") + 2:].split()
        ticks = int(fields[19])
        btime = next(int(l.split()[1]) for l in open("/proc/stat") if l.startswith("btime"))
        return btime + ticks / os.sysconf("SC_CLK_TCK")
    except Exception:
        try:
            out = subprocess.run(["ps", "-o", "etimes=", "-p", str(pid)], capture_output=True, text=True).stdout
            return time.time() - int(out.strip())
        except Exception:
            return None


def child_pids(pid):
    out = []
    for f in glob.glob("/proc/%d/task/*/children" % pid):
        try:
            out += [int(x) for x in open(f).read().split()]
        except Exception:
            pass
    return out


def codex_rollout(pid, cwd):
    for p in [pid] + child_pids(pid):
        for fd in glob.glob("/proc/%d/fd/*" % p):
            try:
                target = os.readlink(fd)
            except OSError:
                continue
            if "/rollout-" in target and target.endswith(".jsonl"):
                return target
    # Fallback: newest rollout for this folder written since the process started.
    since = (process_start(pid) or time.time() - 86400) - 5
    best = None
    for path in glob.glob(os.path.join(HOME, ".codex/sessions/*/*/*/rollout-*.jsonl")):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if mtime < since or (best and mtime <= best[1]):
            continue
        try:
            with open(path, "rb") as f:
                meta = json.loads(f.readline())
        except Exception:
            continue
        if (meta.get("payload") or {}).get("cwd") == cwd:
            best = (path, mtime)
    return best and best[0]


def claude_transcript(session_id, cwd):
    slug = "".join(ch if ch.isalnum() else "-" for ch in cwd)
    direct = os.path.join(HOME, ".claude/projects", slug, session_id + ".jsonl")
    if os.path.exists(direct):
        return direct
    found = glob.glob(os.path.join(HOME, ".claude/projects/*", session_id + ".jsonl"))
    return found[0] if found else None


def handle(agent):
    pid, cwd = int(agent["pid"]), agent.get("cwd") or ""
    if agent["kind"] == "claude":
        try:
            info = json.load(open(os.path.join(HOME, ".claude/sessions/%d.json" % pid)))
        except Exception:
            return {}
        result = {"status": info.get("status")}
        if info.get("startedAt"):
            result["started"] = info["startedAt"] / 1000.0
        path = claude_transcript(info.get("sessionId", ""), info.get("cwd") or cwd)
        if path:
            result.update(get_log(ClaudeLog, path).stats())
        return result
    result = {"started": process_start(pid)}
    path = codex_paths.get(pid) or codex_rollout(pid, cwd)
    if path:
        codex_paths[pid] = path
        result.update(get_log(CodexLog, path).stats())
    return result


def main():
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except ValueError:
            continue
        reply = {}
        touched.clear()
        for agent in request.get("agents", []):
            try:
                reply[agent["id"]] = handle(agent)
            except Exception as ex:
                reply[agent["id"]] = {"error": str(ex)}
        for path in list(logs):
            if path not in touched:
                del logs[path]
        live_pids = {int(a["pid"]) for a in request.get("agents", [])}
        for pid in list(codex_paths):
            if pid not in live_pids:
                del codex_paths[pid]
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


main()
