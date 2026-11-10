"""Release entry regression with fake builders in a clean, isolated checkout."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'build-release.sh'


class ReleaseScriptTests(unittest.TestCase):
    def test_real_builder_does_not_seed_counter_for_explicit_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'VERSION').write_text('1.2.3\n')
            shutil.copy2(SCRIPT.with_name('build-app.sh'), root / 'scripts/build-app.sh')
            # Stop at the real pre-build icon gate, before invoking Swift/AppKit.
            gate = root / 'scripts/sync-icon-assets.sh'
            gate.write_text('#!/bin/bash\nexit 1\n')
            gate.chmod(0o755)
            result = subprocess.run(['bash', 'scripts/build-app.sh', '1.2.3', '1'],
                                    cwd=root, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('图标资产与源不同步', result.stderr)
            self.assertFalse((root / '.build_number').exists(), '显式构建不得创建本地计数器')

    def test_build_number_precedence_and_fresh_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'docs/releases').mkdir(parents=True)
            shutil.copy2(SCRIPT, root / 'scripts/build-release.sh')
            (root / 'VERSION').write_text('1.2.3\n')
            (root / 'CHANGELOG.md').write_text('## [1.2.3]\n')
            (root / 'docs/releases/1.2.3.md').write_text('fixture\n')
            for name in ('README.md', 'README.en.md'):
                (root / name).write_text('**1.2.3** LLM-monitor-1.2.3.dmg build-release.sh 1.2.3\n')
            (root / '.gitignore').write_text('build/\n.build_number\n')
            (root / 'scripts/build-app.sh').write_text(
                '#!/bin/bash\nmkdir -p build\nprintf "%s %s\\n" "$1" "$2" > build/args\n')
            (root / 'scripts/build-dmg.sh').write_text(
                '#!/bin/bash\nprintf fixture > build/LLM-monitor-1.2.3.dmg\n')
            for name in ('build-app.sh', 'build-dmg.sh'):
                (root / 'scripts' / name).chmod(0o755)
            def git(*args):
                subprocess.run(['git', '-C', directory, *args], check=True, capture_output=True)
            git('init', '-q')
            git('add', '.')
            git('-c', 'user.name=Regression Fixture', '-c', 'user.email=fixture@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
            for stored, explicit, expected in ((None, None, '1'), ('323', None, '323'), ('323', '456', '456')):
                if stored is not None:
                    (root / '.build_number').write_text(stored + '\n')
                args = ['bash', 'scripts/build-release.sh']
                if explicit:
                    args.extend(['1.2.3', explicit])
                result = subprocess.run(args, cwd=root, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((root / 'build/args').read_text().strip(), '1.2.3 ' + expected)
                self.assertTrue((root / 'build/SHA256SUMS.txt').is_file())
                if stored is None:
                    self.assertFalse((root / '.build_number').exists())
                else:
                    self.assertEqual((root / '.build_number').read_text().strip(), stored)


if __name__ == '__main__':
    unittest.main()
