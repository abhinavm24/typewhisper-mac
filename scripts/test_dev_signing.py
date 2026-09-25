"""Exercise the actual dev-build script with isolated tools and app directories."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class DevSigningTests(unittest.TestCase):
    def test_absent_empty_and_configured_signing(self):
        original = Path(__file__).with_name('build-dev-local.sh').read_text()
        for config in [None, '', 'DEVELOPMENT_TEAM = TESTTEAM\n']:
            with self.subTest(config=config), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                scripts, tools = root / 'scripts', root / 'tools'
                scripts.mkdir(); tools.mkdir()
                text = original.replace('install_dir="$HOME/Applications"', 'install_dir="$repo_root/test-apps"')
                text = text.replace('lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"', 'lsregister=""')
                text = '\n'.join('lsregister=""' if line.startswith('lsregister=') else line for line in text.splitlines()) + '\n'
                text = text.replace('"$HOME/Library/Developer/Xcode/DerivedData"', '"$repo_root/empty"')
                (scripts / 'build-dev-local.sh').write_text(text)
                (scripts / 'sync-dev-data-local.sh').write_text('#!/bin/bash\nexit 0\n')
                (scripts / 'sync-dev-data-local.sh').chmod(0o755)
                if config is not None:
                    (root / 'CodeSigning.local.xcconfig').write_text(config)
                stubs = {
                    'pgrep': 'exit 1',
                    'xcodebuild': '''printf '%s\\n' "$@" > "$FIXTURE_ROOT/args"
mkdir -p "$FIXTURE_ROOT/.build/DerivedData-Dev/Build/Products/Debug/TypeWhisper.app/Contents/Resources"
touch "$FIXTURE_ROOT/.build/DerivedData-Dev/Build/Products/Debug/TypeWhisper.app/Contents/Resources/signed-content"''',
                    'ditto': 'cp -R "$1" "$2"',
                    'xattr': 'exit 0',
                    'trash': 'exit 0',
                    'codesign': '''test ! -e "$FIXTURE_ROOT/test-apps/TypeWhisper-Dev.app/Contents/Resources/DevBuildSource.txt"
touch "$FIXTURE_ROOT/verified"''',
                }
                for name, content in stubs.items():
                    path = tools / name
                    path.write_text('#!/bin/bash\nset -eu\n' + content + '\n')
                    path.chmod(0o755)
                env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], FIXTURE_ROOT=str(root))
                subprocess.run(['bash', str(scripts / 'build-dev-local.sh')], env=env, check=True, capture_output=True)
                args = (root / 'args').read_text()
                self.assertEqual('-allowProvisioningUpdates' in args, bool(config))
                self.assertEqual('CODE_SIGNING_ALLOWED=NO' in args, not bool(config))
                self.assertEqual((root / 'verified').exists(), bool(config))
                self.assertTrue((root / 'test-apps/TypeWhisper-Dev.app.build-source.txt').exists())


if __name__ == '__main__':
    unittest.main()
