#!/usr/bin/env python3
"""Build the release zip in MiSTer's SD card structure from the repository (from the owner's ohmygod-mister/mister/tools/package.py):

  _Arcade/<title>.mra                              the MRAs, with their _alternatives/ folders   (mra/**/*.mra)
  _Arcade/cores/crospang_<YYYYMMDD>.rbf            the core                                      (releases/crospang_<YYYYMMDD>.rbf)

  python tools/package.py [YYYYMMDD]        (default: the newest RBF in releases/)

Writes dist/CrossPang_MiSTer_<YYYYMMDD>.zip (dist/ is not in the repository: attach the zip to the GitHub release).  Unzip it over
the root of the SD card.  No ROMs are in it: the MAME 0.289 romsets (crospang.zip, heuksun.zip, bestri.zip, pitapat.zip, and the
clones' bestria.zip / pitapata.zip with a split set) go to /media/fat/games/mame/.
"""
import glob
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DIST = os.path.join(REPO, 'dist')


def main(argv):
    rbfs = sorted(glob.glob(os.path.join(REPO, 'releases', 'crospang_*.rbf')))
    rbfs = [r for r in rbfs if re.search(r'crospang_\d{8}[a-z]?\.rbf$', r)]
    if argv:
        rbfs = [r for r in rbfs if r.endswith('crospang_%s.rbf' % argv[0])]
    if not rbfs:
        print('no releases/crospang_YYYYMMDD.rbf')
        return 1
    rbf = rbfs[-1]
    date = re.search(r'crospang_(\d{8}[a-z]?)\.rbf$', rbf).group(1)
    mra_root = os.path.join(REPO, 'mra')
    mras = sorted(glob.glob(os.path.join(mra_root, '**', '*.mra'), recursive=True),
                  key=lambda p: (os.path.dirname(p).lower(), os.path.basename(p).lower()))
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, 'CrossPang_MiSTer_%s.zip' % date)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for full in mras:
            z.write(full, '_Arcade/' + os.path.relpath(full, mra_root).replace(os.sep, '/'))
        z.write(rbf, '_Arcade/cores/' + os.path.basename(rbf))
    print('%s: %d MRAs + %s' % (out, len(mras), os.path.basename(rbf)))
    with zipfile.ZipFile(out) as z:
        for n in z.namelist():
            print('  ' + n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
