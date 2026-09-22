"""Exercise script boundaries without building apps or using release credentials."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from xml.sax.saxutils import quoteattr


SCRIPTS = Path(__file__).resolve().parents[1]


class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="siniulator-script-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        for source in SCRIPTS.glob("*.sh"):
            shutil.copy2(source, self.scripts)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.log"
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": str(self.root),
            "TEST_COMMAND_LOG": str(self.log),
        }
        self.write_tool(self.scripts / "build-app.sh", 'mkdir -p build/Siniulator.app\necho build >> "$TEST_COMMAND_LOG"')
        self.write_tool(self.bin / "swift", 'printf "swift %s\\n" "$*" >> "$TEST_COMMAND_LOG"')
        self.write_tool(self.bin / "open", '''
printf 'open %s\\n' "$*" >> "$TEST_COMMAND_LOG"
while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == --output-dir ]]; then
        output="$2"
        break
    fi
    shift
done
for name in fullscreen-chrome toolbar rotation duo; do echo PASS > "$output/$name-results.txt"; done
touch "$output/fullscreen-idle.png"
''')

    def write_tool(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o755)

    def run_script(self, name, *arguments):
        return subprocess.run(
            ["/bin/bash", str(self.scripts / name), *arguments],
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=10,
        )

    def test_invalid_test_arguments_do_not_build_or_launch(self):
        cases = [
            ("check-fullscreen-chrome.sh", "-1"),
            ("check-fullscreen-chrome.sh", "0", "--expect-backdrop-variaton"),
            ("check-fullscreen-chrome.sh", "0", "dark", "extra"),
            ("check-toolbar.sh", "unexpected"),
            ("check-rotation.sh", "unexpected"),
            ("check-duo.sh", "unexpected"),
            ("build-fixture.sh", "unexpected"),
            ("test-integration.sh",),
            ("test-integration.sh", "runtime"),
            ("test-integration.sh", "", "device"),
            ("test-integration.sh", "runtime", "device", "output", "extra"),
        ]
        for name, *arguments in cases:
            with self.subTest(script=name, arguments=arguments):
                result = self.run_script(name, *arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Usage:", result.stderr)
                self.assertFalse(self.log.exists(), "Invalid input must be rejected before external tools run")

    def test_fullscreen_options_reach_the_app_and_image_check(self):
        cases = [
            ([], "0", "system", False),
            (["1", "light"], "1", "light", False),
            (["dark"], "0", "dark", False),
            (["2", "--expect-backdrop-variation", "dark"], "2", "dark", True),
            (["--expect-backdrop-variation"], "0", "system", True),
        ]
        for arguments, screen, appearance, variation in cases:
            with self.subTest(arguments=arguments):
                self.log.unlink(missing_ok=True)
                result = self.run_script("check-fullscreen-chrome.sh", *arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                commands = self.log.read_text().splitlines()
                launch = next(line for line in commands if line.startswith("open "))
                self.assertIn("--args -ApplePersistenceIgnoreState YES ", launch)
                self.assertIn(f"--screen-index {screen} ", launch)
                self.assertIn(f"--test-appearance {appearance}", launch)
                image_check = next(line for line in commands if "FullscreenAppearance.swift" in line)
                self.assertEqual("--expect-backdrop-variation" in image_check, variation)

    def test_toolbar_and_rotation_ignore_crash_restoration(self):
        for script in ["check-toolbar.sh", "check-rotation.sh", "check-duo.sh"]:
            with self.subTest(script=script):
                self.log.unlink(missing_ok=True)
                result = self.run_script(script)
                self.assertEqual(result.returncode, 0, result.stderr)
                launch = next(line for line in self.log.read_text().splitlines() if line.startswith("open "))
                self.assertIn("--args -ApplePersistenceIgnoreState YES ", launch)

    def test_duo_preserves_the_explicit_xcode_in_the_launched_app(self):
        self.env["DEVELOPER_DIR"] = "/Custom Xcode.app/Contents/Developer"
        result = self.run_script("check-duo.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        launch = next(line for line in self.log.read_text().splitlines() if line.startswith("open "))
        self.assertIn("--env DEVELOPER_DIR=/Custom Xcode.app/Contents/Developer", launch)
        self.assertIn("--duo-smoke", launch)

    def test_fixture_targets_the_host_architecture(self):
        self.write_tool(self.bin / "codesign", ":")
        self.write_tool(self.bin / "xcrun", '''
printf 'xcrun %s\\n' "$*" >> "$TEST_COMMAND_LOG"
if [[ "$*" == *--show-sdk-path* ]]; then echo /mock-sdk; fi
''')
        for architecture in ["arm64", "x86_64"]:
            with self.subTest(architecture=architecture):
                self.write_tool(self.bin / "uname", f"echo {architecture}")
                self.log.unlink(missing_ok=True)
                result = self.run_script("build-fixture.sh")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"-target {architecture}-apple-ios17.0-simulator", self.log.read_text())

    def test_integration_cleans_up_its_device_and_requires_fresh_success(self):
        self.write_tool(self.scripts / "build-fixture.sh", "mkdir -p build/InteractionQA.app")
        self.write_tool(self.bin / "xcrun", '''
printf 'xcrun %s\\n' "$*" >> "$TEST_COMMAND_LOG"
if [[ "$2" == create ]]; then echo temporary-test-device; fi
''')
        self.write_tool(self.bin / "open", '''
printf 'open %s\\n' "$*" >> "$TEST_COMMAND_LOG"
while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == --output-dir ]]; then
        if [[ "$TEST_SUCCEEDS" == yes ]]; then echo PASS > "$2/exercise-success.txt"; fi
        break
    fi
    shift
done
''')
        output = self.root / "integration results"
        output.mkdir()
        for succeeds in ["no", "yes"]:
            with self.subTest(succeeds=succeeds):
                self.env["TEST_SUCCEEDS"] = succeeds
                self.log.unlink(missing_ok=True)
                # An earlier pass must not hide a failed or interrupted app run.
                (output / "exercise-success.txt").write_text("stale success")
                result = self.run_script("test-integration.sh", "runtime", "device-type", str(output))
                self.assertEqual(result.returncode == 0, succeeds == "yes", result.stderr)
                commands = self.log.read_text().splitlines()
                launch = next(line for line in commands if line.startswith("open "))
                self.assertIn("--args -ApplePersistenceIgnoreState YES ", launch)
                self.assertIn("xcrun simctl shutdown temporary-test-device", commands)
                self.assertIn("xcrun simctl delete temporary-test-device", commands)
                self.assertEqual((output / "exercise-success.txt").exists(), succeeds == "yes")
                if succeeds == "no":
                    self.assertIn("exited without writing exercise-success.txt", result.stderr)
                    self.assertIn(str(output / "stdout.log"), result.stderr)
                    self.assertIn(str(output / "stderr.log"), result.stderr)

    @unittest.skipUnless(shutil.which("xmllint") and os.uname().sysname == "Darwin", "Requires macOS stat and xmllint")
    def test_appcast_rejects_invalid_feed_without_replacing_previous_output(self):
        archive = self.root / "Siniulator-0.1.0-2.dmg"
        archive.write_bytes(b"mock DMG")
        output = self.root / "published" / "appcast.xml"
        output.parent.mkdir()
        generated = self.root / "generated.xml"
        self.env["TEST_FEED"] = str(generated)
        self.write_tool(self.root / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast", '''
directory="${!#}"
cp "$TEST_FEED" "$directory/appcast.xml"
''')

        def item(length=archive.stat().st_size, signature="signature", name=archive.name, prefix="https://updates.siniulator.app/"):
            return (
                '<item><sparkle:version>2</sparkle:version><enclosure '
                f'url={quoteattr(prefix + name)} '
                f'length="{length}" sparkle:edSignature={quoteattr(signature)}/></item>'
            )

        cases = {
            "missing update": "",
            "multiple updates": item() + item(),
            "unsigned archive": item(signature=""),
            "wrong length": item(length=99),
            "wrong archive": item(name="other.dmg"),
            "delta update": item() + "<sparkle:deltas/>",
        }
        for label, items in cases.items():
            with self.subTest(feed=label):
                output.write_text("previous published feed")
                generated.write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>{items}</channel></rss>')
                result = self.run_script("generate-appcast.sh", str(archive), str(output))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output.read_text(), "previous published feed")
                self.assertEqual(archive.read_bytes(), b"mock DMG")

        generated.write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>{item()}</channel></rss>')
        result = self.run_script("generate-appcast.sh", str(archive), str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(), generated.read_text())

        github_prefix = "https://github.com/kmagiera/Siniulator/releases/download/v0.1.0/"
        self.env["APPCAST_DOWNLOAD_URL_PREFIX"] = github_prefix
        generated.write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>{item(prefix=github_prefix)}</channel></rss>')
        result = self.run_script("generate-appcast.sh", str(archive), str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(), generated.read_text())


if __name__ == "__main__":
    unittest.main()
