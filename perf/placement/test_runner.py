"""Tests for runner.py (timed runs, scrubbed environment, ASLR, preflight) and
for the equal-length store paths of ab_store.py.

The ASLR test changes personality(2) only inside a child Python, so it does
not leak into the other tests.  Nothing runs these automatically:
  python3 -m unittest discover perf/placement
"""

import hashlib
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock

import ab_store as st
import runner

HERE = os.path.dirname(os.path.abspath(__file__))
LINUX = sys.platform.startswith("linux")


class EnvTest(unittest.TestCase):
    def test_env_is_fixed_and_padded(self):
        base = runner.base_env("/usr/bin:/bin", "/home/x", "/dev/shm/t")
        self.assertEqual(base, {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": "/home/x",
                                "TMPDIR": "/dev/shm/t"})
        for pad in (0, 16, 1440, 4080):
            env = runner.run_env(base, pad)
            self.assertEqual(env[runner.PAD_VAR], "x" * pad)
            self.assertEqual(list(env), ["PATH", "LC_ALL", "HOME", "TMPDIR", runner.PAD_VAR])
            self.assertEqual(env, runner.run_env(base, pad))
        self.assertNotIn(runner.PAD_VAR, base)

    def test_env_size_moves_by_the_pad_delta(self):
        base = runner.base_env("/p", "/h", "/t")
        size = lambda e: sum(len(k) + len(v) + 2 for k, v in e.items())
        self.assertEqual(size(runner.run_env(base, 48)) - size(runner.run_env(base, 32)), 16)

    def test_bad_pad(self):
        for bad in (-1, 1.5, "3"):
            with self.assertRaises(ValueError):
                runner.run_env({}, bad)

    def test_child_sees_exactly_the_env(self):
        with tempfile.TemporaryDirectory() as d:
            base = runner.base_env(os.environ.get("PATH", "/usr/bin:/bin"), d, d)
            out = os.path.join(d, "out")
            s = runner.spawn(["/usr/bin/env"], 32, d, out, runner.aslr_state(
                runner.load_personality()), env=base)
            self.assertEqual(s.rc, 0)
            with open(out) as fh:
                lines = fh.read().splitlines()
            want = ["%s=%s" % kv for kv in runner.run_env(base, 32).items()]
            self.assertEqual(sorted(lines), sorted(want))

    def test_tmpfs_lookup(self):
        with tempfile.TemporaryDirectory() as d:
            d = os.path.realpath(d)
            mounts = os.path.join(d, "mounts")
            with open(mounts, "w") as fh:
                fh.write("/dev/vda / ext4 rw 0 0\ntmpfs %s tmpfs rw 0 0\n" % d)
            self.assertEqual(runner.fs_type(os.path.join(d, "x"), mounts), "tmpfs")
            self.assertEqual(runner.fs_type("/usr", mounts), "ext4")
            self.assertEqual(runner.tmpfs_root(mounts, ("/usr", d)), d)
            self.assertIsNone(runner.tmpfs_root(mounts, ("/usr",)))

    def test_tmpfs_lookup_resolves_symlinks(self):
        # A link on tmpfs to a directory on disk is on disk.
        with tempfile.TemporaryDirectory() as d:
            d = os.path.realpath(d)
            shm, disk = os.path.join(d, "shm"), os.path.join(d, "disk")
            os.makedirs(shm)
            os.makedirs(disk)
            os.symlink(disk, os.path.join(shm, "link"))
            mounts = os.path.join(d, "mounts")
            with open(mounts, "w") as fh:
                fh.write("tmpfs %s tmpfs rw 0 0\n/dev/vdb %s ext4 rw 0 0\n" % (shm, disk))
            self.assertEqual(runner.fs_type(os.path.join(shm, "link"), mounts), "ext4")
            self.assertEqual(runner.fs_type(os.path.join(shm, "link", "x"), mounts), "ext4")
            self.assertEqual(runner.fs_type(shm, mounts), "tmpfs")


class StorePathTest(unittest.TestCase):
    def test_run_paths_have_equal_length(self):
        work = "/w/exp"
        paths = [st.bin_path(work, a, s, st.item_sub(kind, i))
                 for a in (0, 7, 99) for s in (0, 1, 42, 99999, None)
                 for kind, i in (("bench", 0), ("bench", 99))]
        self.assertEqual(len({len(p) for p in paths}), 1, paths[:3])
        selfp = [st.bin_path(work, a, s, st.item_sub("selfcompile", 0))
                 for a in (0, 12) for s in (3, 40000, None)]
        self.assertEqual(len({len(p) for p in selfp}), 1)
        self.assertTrue(selfp[0].endswith("store/a00/s00003/bin"))
        self.assertTrue(paths[0].endswith("store/a00/s00000/b00/bin"))

    def test_out_of_range(self):
        for bad in (lambda: st.seed_label(100000), lambda: st.arm_dir("/w", 100),
                    lambda: st.item_sub("bench", 100), lambda: st.seed_label(-1)):
            with self.assertRaises(ValueError):
                bad()


class SpawnTest(unittest.TestCase):
    def test_sample_fields_and_hash(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "o")
            s = runner.spawn(["/bin/sh", "-c", "echo hi; echo err >&2; exit 3"], 0, d, out,
                             runner.aslr_state(runner.load_personality()))
            self.assertEqual(s.rc, 3)
            self.assertEqual(s.out_hash, hashlib.sha256(b"hi\n").hexdigest())
            with open(out + ".err") as fh:
                self.assertEqual(fh.read(), "err\n")
            self.assertGreaterEqual(s.wall, 0)
            self.assertGreaterEqual(s.user, 0)
            self.assertGreater(s.maxrss, 0)
            self.assertIsNone(s.cycles)
            self.assertIsNotNone(s.load1)
            if LINUX:
                self.assertIsNotNone(s.steal)

    def test_hash_path_and_cwd(self):
        with tempfile.TemporaryDirectory() as d:
            s = runner.spawn(["/bin/sh", "-c", "pwd > made"], 0, d, os.path.join(d, "o"),
                             runner.aslr_state(runner.load_personality()),
                             hash_path=os.path.join(d, "made"))
            want = hashlib.sha256((os.path.realpath(d) + "\n").encode()).hexdigest()
            self.assertEqual(s.out_hash, want)

    def test_aslr_label_must_match(self):
        persona = runner.load_personality()
        if persona is None:
            self.skipTest("no personality(2)")
        other = "on" if runner.aslr_state(persona) == "off" else "off"
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(runner.AslrError):
                runner.spawn(["/bin/true"], 0, d, os.path.join(d, "o"), other)

    def test_time_l_counts_and_macos_rss(self):
        # A stand-in for macOS /usr/bin/time -l: runs the command, then
        # prints the counters the way time -l does.
        with tempfile.TemporaryDirectory() as d:
            fake = os.path.join(d, "time")
            with open(fake, "w") as fh:
                fh.write("#!/bin/sh\nshift\n\"$@\"\nrc=$?\n"
                         "echo '      1234567  instructions retired' >&2\n"
                         "echo '       765432  cycles elapsed' >&2\nexit $rc\n")
            os.chmod(fake, 0o755)
            out = os.path.join(d, "o")
            s = runner.spawn(["/bin/echo", "x"], 0, d, out, "on", persona=None,
                             time_l=fake, platform="darwin")
            self.assertEqual((s.cycles, s.insns), (765432, 1234567))
            self.assertEqual(s.rc, 0)

    def test_maxrss_units(self):
        # ru_maxrss is in KiB on Linux and in bytes on macOS; Sample has KiB.
        real = os.wait4

        def wait4(pid, opts):
            p, status, ru = real(pid, opts)
            fields = {k: getattr(ru, k) for k in dir(ru) if k.startswith("ru_")}
            fields["ru_maxrss"] = 4096 * 1024
            return p, status, type("RU", (), fields)()
        with tempfile.TemporaryDirectory() as d, mock.patch.object(runner.os, "wait4", wait4):
            out = os.path.join(d, "o")
            mac = runner.spawn(["/bin/true"], 0, d, out, "on", persona=None, time_l=None,
                               platform="darwin")
            lin = runner.spawn(["/bin/true"], 0, d, out, "on", persona=None, time_l=None,
                               platform="linux")
        self.assertEqual((mac.maxrss, lin.maxrss), (4096, 4096 * 1024))

    def test_parse_time_l(self):
        text = textwrap.dedent("""\
                    0.00 real         0.00 user         0.00 sys
                 1347584  maximum resident set size
                 2051463  instructions retired
                 1524331  cycles elapsed
            """)
        self.assertEqual(runner.parse_time_l(text), (1524331, 2051463))
        self.assertEqual(runner.parse_time_l("0.00 real\n"), (None, None))

    def test_default_time_l(self):
        self.assertEqual(runner.default_time_l("darwin", lambda p: True), runner.TIME_L)
        self.assertIsNone(runner.default_time_l("darwin", lambda p: False))
        self.assertIsNone(runner.default_time_l("linux", lambda p: True))

    def test_child_killed_by_sigint_or_sigterm_is_an_interrupt(self):
        with tempfile.TemporaryDirectory() as d:
            for sig in ("INT", "TERM"):
                with self.assertRaises(KeyboardInterrupt):
                    runner.spawn(["/bin/sh", "-c", "kill -%s $$" % sig], 0, d,
                                 os.path.join(d, "o"), "on", persona=None)
            s = runner.spawn(["/bin/sh", "-c", "kill -HUP $$"], 0, d, os.path.join(d, "o"),
                             "on", persona=None)
            self.assertEqual(s.rc, -signal.SIGHUP)

    def test_interrupt_when_the_child_is_already_dead(self):
        # A Ctrl-C reaches the child too: when the wait is interrupted the
        # child may be dead (a zombie) or even reaped, and the interrupt must
        # still come out as KeyboardInterrupt.
        real = os.wait4

        def dead(pid, opts):
            os.kill(pid, signal.SIGKILL)
            os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT)
            raise KeyboardInterrupt

        def reaped(pid, opts):
            os.kill(pid, signal.SIGKILL)
            real(pid, 0)
            raise KeyboardInterrupt
        with tempfile.TemporaryDirectory() as d:
            for fake in (dead, reaped):
                with self.subTest(fake=fake.__name__), \
                        mock.patch.object(runner.os, "wait4", fake):
                    with self.assertRaises(KeyboardInterrupt):
                        runner.spawn(["/bin/sleep", "30"], 0, d, os.path.join(d, "o"), "on",
                                     persona=None)

    @unittest.skipUnless(LINUX and os.path.exists("/proc/self/stat"), "needs Linux /proc")
    def test_sigint_to_the_process_group(self):
        code = textwrap.dedent("""\
            import os, sys
            sys.path.insert(0, %r)
            import runner
            d = sys.argv[1]
            print("ready", flush=True)
            try:
                runner.spawn(["/bin/sleep", "30"], 0, d, os.path.join(d, "o"), "on",
                             persona=None)
                print("returned", flush=True)
            except BaseException as e:
                print(type(e).__name__, flush=True)
            """ % HERE)
        with tempfile.TemporaryDirectory() as d:
            p = subprocess.Popen([sys.executable, "-c", code, d], start_new_session=True,
                                 stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(p.stdout.readline(), "ready\n")
                deadline = time.monotonic() + 20
                # Signal once the child runs sleep (after its exec).
                while not children(p.pid, "sleep") and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(children(p.pid, "sleep"))
                time.sleep(0.2)
                os.killpg(p.pid, signal.SIGINT)
                out = p.communicate(timeout=30)[0]
            finally:
                if p.poll() is None:
                    p.kill()
                    p.wait()
            self.assertEqual(out.strip(), "KeyboardInterrupt")

    def test_read_steal(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "stat")
            with open(p, "w") as fh:
                fh.write("cpu  1 2 3 4 5 6 7 504 0 0\ncpu0 1 2 3 4 5 6 7 8 0 0\n")
            self.assertEqual(runner.read_steal(p), 504)
            self.assertIsNone(runner.read_steal(os.path.join(d, "missing")))


def children(pid, comm):
    """The pids of the processes named comm whose parent is pid (Linux
    /proc)."""
    out = []
    for name in os.listdir("/proc"):
        if name.isdigit():
            try:
                with open("/proc/%s/stat" % name) as fh:
                    stat = fh.read()
            except OSError:
                continue
            fields = stat[stat.rindex(")") + 2:].split()
            if int(fields[1]) == pid and stat[stat.index("(") + 1:stat.rindex(")")] == comm:
                out.append(int(name))
    return out


class AslrTest(unittest.TestCase):
    def test_no_personality_falls_back_to_aslr_on(self):
        logs = []
        self.assertEqual(runner.set_aslr("off", persona=None, log=logs.append), "on")
        self.assertEqual(len(logs), 1)
        self.assertIn("personality", logs[0])
        self.assertEqual(runner.set_aslr("on", persona=None, log=logs.append), "on")
        self.assertEqual(len(logs), 1)

    def test_failing_personality_is_loud(self):
        def broken(x):
            return -1
        with self.assertRaises(runner.AslrError):
            runner.set_aslr("off", persona=broken)

    def test_personality_that_does_not_take(self):
        state = {"p": 0}

        def ignoring(x):
            return state["p"]  # accepts the call but never changes
        with self.assertRaises(runner.AslrError):
            runner.set_aslr("off", persona=ignoring)

    def test_persona_bits_leave_out_aslr(self):
        self.assertIsNone(runner.persona_bits(None))
        self.assertEqual(runner.persona_bits(lambda x: 0x8 | runner.ADDR_NO_RANDOMIZE), 0x8)

    def test_fake_personality(self):
        state = {"p": 0x8}

        def fake(x):
            if x == runner.QUERY_PERSONA:
                return state["p"]
            old, state["p"] = state["p"], x
            return old
        self.assertEqual(runner.set_aslr("off", persona=fake), "off")
        self.assertEqual(state["p"], 0x8 | runner.ADDR_NO_RANDOMIZE)
        self.assertEqual(runner.set_aslr("on", persona=fake), "on")
        self.assertEqual(state["p"], 0x8)

    @unittest.skipUnless(LINUX and os.path.exists("/proc/self/stat"), "needs Linux /proc")
    def test_startstack_fixed_and_shifted_by_pad_with_aslr_off(self):
        code = textwrap.dedent("""\
            import json, os, sys, tempfile
            sys.path.insert(0, %r)
            import runner
            try:
                runner.set_aslr("off")
            except runner.AslrError as e:
                print(json.dumps({"skip": str(e)})); sys.exit(0)
            env = runner.base_env(os.environ.get("PATH", "/bin"), "/", "/tmp")
            with tempfile.TemporaryDirectory() as d:
                a = runner.startstack(env, 160, d, "off")
                b = runner.startstack(env, 160, d, "off")
                c = runner.startstack(env, 160 + 48, d, "off")
                pre = runner.preflight(env, d, "off", pad=1440)
            print(json.dumps({"a": a, "b": b, "c": c, "pre": pre}))
            """ % HERE)
        p = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        import json
        got = json.loads(p.stdout)
        if "skip" in got:
            self.skipTest(got["skip"])
        self.assertEqual(got["a"], got["b"])
        self.assertEqual(got["a"] - got["c"], 48)
        self.assertTrue(got["pre"]["checked"])


class PreflightTest(unittest.TestCase):
    def fake_spawn(self, stacks):
        it = iter(stacks)

        def spawn(argv, pad, cwd, out, aslr, env=None):
            with open(out, "w") as fh:
                fh.write("1 (c a)t) R 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 0 0 0 "
                         "18446744073709551615 0 0 %d 0 0\n" % next(it))
            return runner.Sample(*([0] * 10 + ["", 0, None, None]))
        return spawn

    def test_parse_startstack(self):
        line = ("42 (a b) c)) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 "
                "24 777 1")
        self.assertEqual(runner.parse_startstack(line), 777)

    def test_pass_and_failures(self):
        env = runner.base_env("/bin", "/", "/tmp")
        with tempfile.TemporaryDirectory() as d:
            rec = runner.preflight(env, d, "off", spawn_fn=self.fake_spawn([1000, 1000, 984]),
                                   have_proc=True)
            self.assertEqual(rec["startstack"], [1000, 1000, 984])
            with self.assertRaisesRegex(runner.PreflightError, "ASLR is not off"):
                runner.preflight(env, d, "off", spawn_fn=self.fake_spawn([1000, 2000, 984]),
                                 have_proc=True)
            with self.assertRaisesRegex(runner.PreflightError, "by 32 bytes"):
                runner.preflight(env, d, "off", spawn_fn=self.fake_spawn([1000, 1000, 968]),
                                 have_proc=True)

    def test_skips(self):
        logs = []
        env = runner.base_env("/bin", "/", "/tmp")
        self.assertFalse(runner.preflight(env, "/", "on", have_proc=True,
                                          log=logs.append)["checked"])
        self.assertFalse(runner.preflight(env, "/", "off", have_proc=False,
                                          log=logs.append)["checked"])
        self.assertEqual(len(logs), 2)


if __name__ == "__main__":
    unittest.main()
