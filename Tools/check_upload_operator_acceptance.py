"""Run synthetic local upload monitoring/freeze acceptance; never loads live paths."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
MODULES=('Tools.test_upload_storage_health','Backend.test_upload_operator_acceptance',
         'Backend.test_document_upload_storage','Backend.test_document_upload_idempotency','Backend.test_rotation_gate')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=False)
    with (args.output/'tests.log').open('w') as log:
        result=subprocess.run([sys.executable,'-m','unittest',*MODULES,'-v'],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=180)
    log=(args.output/'tests.log').read_text()
    counts=re.findall(r'Ran (\d+) tests? in',log)
    passed=result.returncode==0 and len(counts)==1 and int(counts[0])>=1 and '\nOK\n' in log
    report={'sourceSHA':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            'workingTreeClean':not subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True).strip(),
            'syntheticOnly':True,'modules':MODULES,'tests':int(counts[0]) if counts else 0,'passed':passed}
    (args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
    return 0 if passed else 1

if __name__=='__main__':raise SystemExit(main())
