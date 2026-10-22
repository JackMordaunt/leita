"""The ABI gate fails an ELF above its floor, per architecture.

The fixtures are linked here against a stub libc.so.6 that defines symbols
under GLIBC_2.5 and GLIBC_9.99, so the result does not depend on the host
glibc. Needs gcc; the arm64 case needs aarch64-linux-gnu-gcc and is skipped
without it.
"""
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "abi_gate.py")
VERSIONS = "GLIBC_2.5 { global: old_sym; };\nGLIBC_9.99 { global: new_sym; } GLIBC_2.5;\n"


def build(cc, tmp, name):
    d = os.path.join(tmp, name)
    os.mkdir(d)
    with open(os.path.join(d, "v.map"), "w") as f:
        f.write(VERSIONS)
    with open(os.path.join(d, "stub.c"), "w") as f:
        f.write("void old_sym(void){}\nvoid new_sym(void){}\n")
    stub = [cc, "-shared", "-nostdlib", "-Wl,-soname,libc.so.6",
            "-Wl,--version-script=" + os.path.join(d, "v.map"),
            "-o", os.path.join(d, "libc.so.6"), os.path.join(d, "stub.c")]
    out = {}
    for tag, body in (("low", "old_sym();"), ("high", "old_sym(); new_sym();")):
        src = os.path.join(d, tag + ".c")
        with open(src, "w") as f:
            f.write("void old_sym(void); void new_sym(void);\n"
                    "int main(void){" + body + "return 0;}\n")
        exe = os.path.join(d, tag)
        subprocess.run(stub, check=True)
        subprocess.run([cc, "-nostdlib", "-Wl,-e,main", "-o", exe, src,
                        "-L" + d, "-l:libc.so.6", "-Wl,--no-as-needed"], check=True)
        out[tag] = exe
    return out


def run_gate(arch, floor, *files, extra=()):
    r = subprocess.run(["python3", "-I", GATE, "--kind", "cli", "--arch", arch,
                        "--floor", floor, *extra, *files],
                       capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


class Gate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.fix = {}
        for arch, cc in (("amd64", "gcc"), ("arm64", "aarch64-linux-gnu-gcc")):
            if shutil.which(cc):
                cls.fix[arch] = build(cc, cls.tmp, arch)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def each(self):
        if "amd64" not in self.fix:
            self.skipTest("no gcc")
        return self.fix.items()

    def test_above_floor_fails(self):
        for arch, fx in self.each():
            code, out = run_gate(arch, "2.38", fx["high"])
            self.assertEqual(code, 1, out)
            self.assertIn("GLIBC_9.99 above floor 2.38", out)
            self.assertIn("new_sym", out)

    def test_at_or_under_floor_passes(self):
        for arch, fx in self.each():
            self.assertEqual(run_gate(arch, "2.5", fx["low"])[0], 0)
            self.assertEqual(run_gate(arch, "9.99", fx["high"])[0], 0)

    def test_version_compare_is_numeric(self):
        for arch, fx in self.each():
            self.assertEqual(run_gate(arch, "2.17", fx["low"])[0], 0)  # 2.5 < 2.17, not lexically
            self.assertEqual(run_gate(arch, "2.4", fx["low"])[0], 1)
            self.assertEqual(run_gate(arch, "2.5", fx["low"], fx["high"])[0], 1)

    def test_wrong_arch_fails(self):
        for arch, fx in self.each():
            other = "arm64" if arch == "amd64" else "amd64"
            code, out = run_gate(other, "99.0", fx["low"])
            self.assertEqual(code, 1, out)

    def test_undeclared_floor(self):
        for arch, fx in self.each():
            conf = os.path.join(self.tmp, "none.conf")
            with open(conf, "w") as f:
                f.write("cli amd64 -\ncli arm64 -\n")
            run = lambda *x: subprocess.run(
                ["python3", "-I", GATE, "--kind", "cli", "--arch", arch,
                 "--floors", conf, *x, fx["high"]], capture_output=True, text=True)
            self.assertEqual(run().returncode, 0)
            self.assertEqual(run("--require-floor").returncode, 1)

    def test_shipped_floors_parse(self):
        for arch, fx in self.each():
            r = subprocess.run(["python3", "-I", GATE, "--kind", "gui", "--arch",
                                arch, fx["high"]], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
