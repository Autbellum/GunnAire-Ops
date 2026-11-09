"""Synthetic crash recovery under unchanged cgroup quota; no production inputs."""
import argparse,json,os,platform,subprocess,sys,time,uuid
from pathlib import Path
TREE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(TREE))
from Tools.quota_runtime import MEMORY_MAX,HEADROOM_MAX,read_cgroup,validate_ci_environment,launch_command
from Tools.upload_recovery_checks import crash_verdict
def run(output):
    validate_ci_environment(os.environ,platform.system())
    if os.getuid()==0 or sys.version_info[:3]!=(3,14,3):raise RuntimeError('Requires unprivileged production-compatible Python')
    output=output.resolve();output.mkdir(parents=True,exist_ok=False)
    unit='gunnaire-upload-crash-quota-'+uuid.uuid4().hex+'.service'
    env={'PATH':os.environ['PATH'],'PYTHONDONTWRITEBYTECODE':'1','LD_LIBRARY_PATH':str(Path(sys.base_prefix)/'lib')}
    expected=[sys.executable,str(Path(__file__).resolve()),'--worker',str(output)]
    command=launch_command(unit,TREE,env,os.getuid())[:-2]+expected
    samples=[];errors=[];process=None;report=None
    with (output/'worker.log').open('w') as log:
        try:
            process=subprocess.Popen(command,stdout=log,stderr=log)
            group=Path('/sys/fs/cgroup/system.slice')/unit
            for _ in range(200):
                if (group/'memory.current').is_file():break
                if process.poll() is not None:raise RuntimeError('Worker failed before cgroup attachment')
                time.sleep(.05)
            read_cgroup(group)
            pid=int(subprocess.check_output(['systemctl','show',unit,'--property=MainPID','--value'],text=True))
            if (pid<=0 or (Path('/proc')/str(pid)/'cmdline').read_bytes().split(b'\0')[:-1] != [v.encode() for v in expected]
                    or f'0::/system.slice/{unit}' not in (Path('/proc')/str(pid)/'cgroup').read_text().splitlines()):
                raise RuntimeError('Unexpected worker process identity')
            started=time.monotonic()
            while process.poll() is None and not (output/'done.json').exists():
                samples.append(read_cgroup(group))
                if time.monotonic()-started>600:raise RuntimeError('Crash workload timed out')
                time.sleep(.05)
            if not (output/'done.json').exists():raise RuntimeError('Crash workload did not complete')
            samples.append(read_cgroup(group))
            completion=json.loads((output/'done.json').read_text())
            (output/'release').touch()
            code=process.wait(timeout=20)
            peak=max(s['peak'] for s in samples)
            checks=crash_verdict(samples,completion,code)
            report={'sourceSHA':subprocess.check_output(['git','rev-parse','HEAD'],cwd=TREE,text=True).strip(),
                    'kind':'injected-precommit-crash-aggregate-worker-and-HTTP-children','budgetBytes':MEMORY_MAX,'headroomTargetBytes':HEADROOM_MAX,
                    'peakBytes':peak,'checks':checks,'passed':all(checks.values()),'workload':completion,'samples':samples}
            (output/'report.json').write_text(json.dumps(report,indent=2))
            print(json.dumps({k:v for k,v in report.items() if k!='samples'}))
            return report['passed']
        except Exception as error:
            (output/'failure.json').write_text(json.dumps({'passed':False,'errorType':type(error).__name__,'samples':samples}))
            raise
        finally:
            subprocess.run(['sudo','-n','systemctl','stop',unit],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
            if process is not None:process.wait(timeout=20)
            subprocess.run(['sudo','-n','systemctl','reset-failed',unit],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--worker',type=Path);parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    if args.worker:
        from Tools.upload_crash_workload import workload
        result=workload()
        (args.worker/'done.tmp').write_text(json.dumps(result))
        (args.worker/'done.tmp').replace(args.worker/'done.json')
        for _ in range(600):
            if (args.worker/'release').exists():break
            time.sleep(.05)
        else:raise SystemExit('Controller did not release worker')
    elif args.output:raise SystemExit(0 if run(args.output) else 1)
    else:parser.error('Specify output')
