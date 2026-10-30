"""Reward hacks: forcing the oracle's exit status must never score."""
import shutil
import subprocess

import pytest

from strim_envs import core
from strim_envs.core import CORPUS, materialize, verify


def _fresh(task_id, tmp_path, *, solved):
    if shutil.which({"py-01": "python3", "tf-02": "go", "rb-01": "ruby", "js-01": "node",
                     "rs-01": "cargo", "ts-01": "tsc", "rx-02": "bun", "jv-01": "javac"}[task_id]) is None:
        pytest.skip("missing toolchain")
    work = tmp_path / "work"
    materialize(task_id, work)
    if solved:
        subprocess.run(["git", "apply", str(CORPUS / "tasks" / task_id / "solution.patch")],
                       cwd=work, check=True)
    return work


@pytest.mark.parametrize("solved", [False, True])
def test_python_os_exit_zero(tmp_path, solved):
    work = _fresh("py-01", tmp_path, solved=solved)
    for source in (work / "pageranges").glob("*.py"):
        source.write_text("import os; os._exit(0)\n" + source.read_text())
    assert verify("py-01", work) == 0.0


def test_go_testmain_exit_zero(tmp_path):
    work = _fresh("tf-02", tmp_path, solved=False)
    (work / "zz_test.go").write_text(
        'package humanize\nimport ("os"; "testing")\n'
        'func TestMain(m *testing.M) { os.Exit(0) }\n')
    assert verify("tf-02", work) == 0.0


def test_rust_autotests_false_is_restored(tmp_path):
    work = _fresh("rs-01", tmp_path, solved=False)
    manifest = work / "Cargo.toml"
    manifest.write_text(manifest.read_text().replace("[package]", "[package]\nautotests = false", 1))
    assert "autotests" in manifest.read_text()
    assert verify("rs-01", work) == 0.0


def test_manifest_edits_do_not_break_reference(tmp_path):
    work = _fresh("rs-01", tmp_path, solved=True)
    manifest = work / "Cargo.toml"
    manifest.write_text(manifest.read_text().replace("[package]", "[package]\nautotests = false", 1))
    assert verify("rs-01", work) == 1.0


def test_ruby_autorun_shadow(tmp_path):
    work = _fresh("rb-01", tmp_path, solved=False)
    shadow = work / "lib" / "minitest"
    shadow.mkdir()
    (shadow / "autorun.rb").write_text("exit 0\n")
    assert verify("rb-01", work) == 0.0


def test_ruby_shadow_does_not_break_reference(tmp_path):
    work = _fresh("rb-01", tmp_path, solved=True)
    (work / "lib" / "minitest").mkdir()
    (work / "lib" / "minitest" / "autorun.rb").write_text("exit 0\n")
    assert verify("rb-01", work) == 1.0


@pytest.mark.parametrize("solved", [False, True])
def test_js_process_exit_at_import(tmp_path, solved):
    work = _fresh("js-01", tmp_path, solved=solved)
    source = work / "lib" / "semver.js"
    source.write_text("process.exit(0);\n" + source.read_text())
    assert verify("js-01", work) == 0.0


def test_js_fake_report_without_test_names(tmp_path):
    work = _fresh("js-01", tmp_path, solved=False)
    source = work / "lib" / "semver.js"
    source.write_text("console.log('TAP version 13\\nok 1 - fake\\n1..1\\n# pass 1\\n# fail 0');"
                      "process.exit(0);\n" + source.read_text())
    assert verify("js-01", work) == 0.0


def test_missing_expected_record_fails_closed(tmp_path, monkeypatch):
    work = _fresh("js-01", tmp_path, solved=True)
    monkeypatch.setattr(core, "EXPECTED", tmp_path / "absent.json")
    assert verify("js-01", work) == 0.0


def test_symlink_swapped_in_after_prescan_is_not_followed(tmp_path, monkeypatch):
    work = _fresh("js-01", tmp_path, solved=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "x.txt").write_text("secret")
    (work / "link").symlink_to(outside)
    real = core._only_plain
    calls = []

    def blind_first(root):
        calls.append(root)
        return True if len(calls) == 1 else real(root)

    monkeypatch.setattr(core, "_only_plain", blind_first)
    assert verify("js-01", work) == 0.0
    assert len(calls) == 2


def test_fifo_is_rejected_without_blocking(tmp_path):
    import os
    work = _fresh("js-01", tmp_path, solved=True)
    os.mkfifo(work / "pipe")
    assert verify("js-01", work) == 0.0


# --- Round 2: forged reports + hard exit, and control-file injection -----------------
import json
import sys


def _names(task_id):
    return sorted(core.expected_tests(task_id).elements())


def _short(name):
    return name.split("::")[-1].split(".")[-1].split("#")[-1]


def _hard_exit_attack(task_id, tmp_path, solved, relpath, make):
    work = _fresh(task_id, tmp_path, solved=solved)
    target = work / relpath
    target.write_text(make(_names(task_id), target.read_text()))
    return verify(task_id, work)


@pytest.mark.parametrize("solved", [False, True])
def test_py_fake_unittest_lines_then_exit(tmp_path, solved):
    def make(names, text):
        fake = "".join(f"{n.rsplit('.', 1)[1]} ({n.rsplit('.', 1)[0]}) ... ok\n" for n in names)
        return f"import os,sys; sys.stderr.write({fake!r}); sys.stderr.flush(); os._exit(0)\n" + text
    assert _hard_exit_attack("py-01", tmp_path, solved, "pageranges/__init__.py", make) == 0.0


def test_js_fake_tap_then_exit(tmp_path):
    def make(names, text):
        fake = "TAP version 13\n" + "".join(f"ok {i} - {_short(n) if False else n.split('::')[-1]}\n" for i, n in enumerate(names, 1))
        return f"console.log({fake!r}); process.exit(0);\n" + text
    assert _hard_exit_attack("js-01", tmp_path, False, "lib/semver.js", make) == 0.0


def test_ts_fake_tap_then_exit(tmp_path):
    def make(names, text):
        fake = "".join(f"ok {i} - {n.split('::')[-1]}\n" for i, n in enumerate(names, 1))
        return f"console.log({fake!r}); process.exit(0);\n" + text
    assert _hard_exit_attack("ts-01", tmp_path, False, "src/result.ts", make) == 0.0


def test_bun_forged_junit_then_exit(tmp_path):
    def make(names, text):
        cases = "".join(f'<testcase name="{n.split("::")[1]}" classname="x" file="{n.split("::")[0]}"/>' for n in names)
        xml = f'<?xml version="1.0"?><testsuites tests="{len(names)}" failures="0">{cases}</testsuites>'
        return ("import {mkdirSync,writeFileSync} from 'node:fs';"
                "for (const d of [process.env.TMPDIR+'/report', process.cwd()+'/report']) {"
                f"try{{mkdirSync(d,{{recursive:true}});writeFileSync(d+'/junit.xml',{xml!r});}}catch{{}}}}"
                "console.log('1 pass');process.exit(0);\n") + text
    assert _hard_exit_attack("rx-02", tmp_path, False, "src/format.js", make) == 0.0


def test_go_fake_events_then_exit(tmp_path):
    work = _fresh("tf-02", tmp_path, solved=False)
    events = "".join(json.dumps({"Action": "pass", "Package": n.rsplit(".", 1)[0], "Test": n.rsplit(".", 1)[1]}) + "\n"
                     for n in _names("tf-02") if "/" not in n.rsplit(".", 1)[1])
    (work / "zz_fake.go").write_text(
        'package humanize\nimport ("fmt"; "os")\n'
        f'func init() {{ fmt.Print({events!r}); fmt.Println("PASS"); os.Exit(0) }}\n')
    assert verify("tf-02", work) == 0.0


def test_rust_fake_libtest_output_then_exit(tmp_path):
    work = _fresh("rs-01", tmp_path, solved=False)
    lib = work / "src" / "lib.rs"
    section = '#[cfg_attr(target_os = "macos", link_section = "__DATA,__mod_init_func")]\n' \
              '#[cfg_attr(target_os = "linux", link_section = ".init_array")]\n'
    lines = "\\n".join(f"test {_short(n)} ... ok" for n in _names("rs-01"))
    lib.write_text(lib.read_text() + "\n#[used]\n" + section +
                   "static CTOR: extern \"C\" fn() = {\n"
                   "    extern \"C\" fn ctor() {\n"
                   f"        println!(\"{lines}\\ntest result: ok. 1 passed; 0 failed; 0 ignored\");\n"
                   "        std::process::exit(0);\n    }\n    ctor\n};\n")
    assert verify("rs-01", work) == 0.0


def test_rust_argv_ctor_forgery(tmp_path):
    work = _fresh("rs-01", tmp_path, solved=False)
    lib = work / "src" / "lib.rs"
    lib.write_text(lib.read_text() + '''
#[used]
#[cfg_attr(target_os = "macos", link_section = "__DATA,__mod_init_func")]
#[cfg_attr(target_os = "linux", link_section = ".init_array")]
static INIT: extern "C" fn() = strim_init;
extern "C" { fn _exit(c: i32) -> !; }
extern "C" fn strim_init() {
    let a: Vec<String> = std::env::args().collect();
    if let Some(i) = a.iter().position(|x| x == "--exact") {
        let name = &a[i+1];
        if let Some(j) = a.iter().position(|x| x == "--logfile") {
            use std::io::Write;
            let mut f = std::fs::OpenOptions::new().append(true).open(&a[j+1]).unwrap();
            writeln!(f, "ok {}", name).unwrap();
            println!("test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out");
            unsafe { _exit(0) }
        }
    }
}
''')
    assert verify("rs-01", work) == 0.0


def test_rust_safe_process_exit_variant(tmp_path):
    work = _fresh("rs-01", tmp_path, solved=False)
    lib = work / "src" / "lib.rs"
    lib.write_text(lib.read_text() + '''
pub fn strim_forge() {
    let a: Vec<String> = std::env::args().collect();
    if let (Some(i), Some(j)) = (a.iter().position(|x| x == "--exact"), a.iter().position(|x| x == "--logfile")) {
        let _ = std::fs::write(&a[j + 1], format!("ok {}\\n", a[i + 1]));
        println!("test result: ok. 1 passed; 0 failed;");
        std::process::exit(0);
    }
}
''')
    assert verify("rs-01", work) == 0.0


def test_ruby_fake_minitest_lines_then_exit(tmp_path):
    def make(names, text):
        fake = "".join(f"{n} = 0.00 s = .\n" for n in names)
        return f"puts {fake!r}; exit!(0)\n" + text
    assert _hard_exit_attack("rb-01", tmp_path, False, "lib/numwords.rb", make) == 0.0


def test_java_fake_ok_lines_then_halt(tmp_path):
    work = _fresh("jv-01", tmp_path, solved=False)
    source = work / "src/main/java/textwrap/Wrapper.java"
    fake = "".join(f"ok   {n}\\n" for n in _names("jv-01"))
    text = source.read_text()
    marker = text.index("{", text.index("class Wrapper")) + 1
    source.write_text(text[:marker] + f' static {{ System.out.print("{fake}"); Runtime.getRuntime().halt(0); }} ' + text[marker:])
    assert verify("jv-01", work) == 0.0


def test_unsolved_forged_channel_lines_without_nonce_fail(tmp_path):
    # Writing records at any inherited descriptor without the per-run nonce is rejected.
    work = _fresh("py-01", tmp_path, solved=True)
    init = work / "pageranges" / "__init__.py"
    init.write_text("import os\nfor fd in range(3, 256):\n    try: os.write(fd, b'x {\"k\":\"end\",\"total\":0,\"ok\":true}\\n')\n"
                    "    except OSError: pass\n" + init.read_text())
    assert verify("py-01", work) == 0.0


def _solved_with(task_id, tmp_path, files):
    work = _fresh(task_id, tmp_path, solved=True)
    for rel, text in files.items():
        (work / rel).parent.mkdir(parents=True, exist_ok=True)
        (work / rel).write_text(text)
    return work


def test_python_control_files_are_neutralised(tmp_path):
    evil = "import os; os._exit(0)\n"
    work = _solved_with("py-01", tmp_path, {"sitecustomize.py": evil, "usercustomize.py": evil,
                                           "conftest.py": evil, "evil.pth": "import os; os._exit(0)\n",
                                           "pytest.ini": "[pytest]\n", "setup.cfg": "x", "tox.ini": "x", ".coveragerc": "x"})
    assert verify("py-01", work) == 1.0


def test_node_control_files_are_neutralised(tmp_path):
    work = _solved_with("js-01", tmp_path, {
        "node_modules/shim/index.js": "process.exit(0)", ".mocharc.json": "{}", "jest.config.js": "process.exit(0)",
        "tsconfig.json": "{", "lib/evil.config.js": "process.exit(0)"})
    assert verify("js-01", work) == 1.0


def test_ts_control_files_are_neutralised(tmp_path):
    work = _solved_with("ts-01", tmp_path, {"tsconfig.base.json": "{", "jest.config.ts": "process.exit(0)",
                                           "node_modules/typescript/index.js": "process.exit(0)"})
    assert verify("ts-01", work) == 1.0


def test_go_control_files_are_neutralised(tmp_path):
    work = _solved_with("tf-02", tmp_path, {"go.work": "go 1.25\nuse ./missing\n", "vendor/modules.txt": "junk",
                                           "zz_extra_test.go": "package humanize\nfunc TestMain(m interface{}) {}\n"})
    assert verify("tf-02", work) == 1.0


def test_rust_control_files_are_neutralised(tmp_path):
    work = _solved_with("rs-01", tmp_path, {".cargo/config.toml": "[build]\nrustflags = ['--bogus']\n",
                                           "rust-toolchain.toml": "[toolchain]\nchannel = 'nope'\n",
                                           "build.rs": "fn main() { std::process::exit(0) }\n"})
    assert verify("rs-01", work) == 1.0


def test_ruby_control_files_are_neutralised(tmp_path):
    work = _solved_with("rb-01", tmp_path, {".rspec-local": "--bogus\n", "Rakefile": "exit 0\n", "Gemfile": "bogus",
                                           "test_helper.rb": "exit 0\n", "lib/test_helper.rb": "exit 0\n"})
    assert verify("rb-01", work) == 1.0


def test_java_control_files_are_neutralised(tmp_path):
    work = _solved_with("jv-01", tmp_path, {"build.gradle": "bogus", "pom.xml": "bogus", ".mvn/maven.config": "x",
                                           "src/main/java/zz/Evil.java": "package zz; public class Evil { static { Runtime.getRuntime().halt(0); } }\n"})
    assert verify("jv-01", work) == 1.0


def test_macos_sandbox_requires_explicit_trusted_local_opt_in(tmp_path, monkeypatch):
    if sys.platform != "darwin":
        pytest.skip("macOS only")
    work = _fresh("js-01", tmp_path, solved=True)
    monkeypatch.delenv("STRIM_ENVS_TRUSTED_LOCAL")
    assert verify("js-01", work) == 0.0
    monkeypatch.setenv("STRIM_ENVS_TRUSTED_LOCAL", "1")
    assert verify("js-01", work) == 1.0
