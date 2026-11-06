"""Run the unmodified reference DecodeTests, capturing their actual packets, then
compare the firmware's real core.h compiled for this host against those results.
Also checks alternating-packet merge, malformed frames, and Taipei history buckets.
"""
import importlib.util
import os
import tempfile
import json
import random
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent / 'pc-gateway'))
import thermo_gateway as ref

spec = importlib.util.spec_from_file_location('reference_tests', ROOT.parent / 'pc-gateway/tests/test_thermo_gateway.py')
test = importlib.util.module_from_spec(spec)
spec.loader.exec_module(test)
cases = []
for name, uuid in [('decode_bthome', 0xFCD2), ('decode_env', 0x181A)]:
    original = getattr(ref, name)
    def capture(data, original=original, uuid=uuid):
        result = original(data)
        cases.append((uuid, bytes(data), result))
        return result
    setattr(ref, name, capture)
suite = unittest.defaultTestLoader.loadTestsFromTestCase(test.DecodeTests)
result = unittest.TextTestRunner(verbosity=2).run(suite)
assert result.wasSuccessful()
reference_count = len(cases)
rng = random.Random(20261106)
# Truncation at every offset, encrypted variants, and random unknown objects.
seeds = [c[:2] for c in cases]
for uuid, data in seeds:
    for size in range(len(data)+1):
        fn = ref.decode_bthome if uuid==0xFCD2 else ref.decode_env
        fn(data[:size])
for _ in range(2000):
    data = bytes([rng.choice([0x40, 0x41, 0x20, 0x44])]) + rng.randbytes(rng.randrange(0,30))
    ref.decode_bthome(data)
temporary = tempfile.TemporaryDirectory()
exe = Path(temporary.name) / ('core_cli.exe' if os.name == 'nt' else 'core_cli')
subprocess.run([os.environ.get('CXX', 'g++'), '-std=c++17', '-Wall', '-Wextra', '-O2',
                '-I'+str(ROOT/'include'), str(ROOT/'tests/core_cli.cpp'), '-o', str(exe)], check=True)

def run(lines):
    proc = subprocess.run([str(exe)], input=lines, text=True, capture_output=True, check=True)
    return [json.loads(s) for s in proc.stdout.splitlines()]

actual = run(''.join(f'D {uuid:x} {data.hex()}\n' for uuid,data,_ in cases))
assert len(actual)==len(cases)
for case, got in zip(cases, actual):
    assert got==case[2], (case, got)
merged = run('M fcd2 40000c015d02ac0903b51a\nM fcd2 40000d0c890b\n')[-1]
assert merged=={'format':'bthome','temperature':24.76,'humidity':68.37,'battery':93,'voltage':2.953}
mv = [0,2200,2204.5,2213.5,2650,2953,3100,3300]
assert run(''.join(f'B {v}\n' for v in mv))==[ref.battery_from_voltage(v) for v in mv]
midnight=20*86400-28800
now=midnight+10*3600
rows=[(midnight+9*3600,20.,40.,80),(midnight+9*3600+600,24.,60.,79),
      (midnight-3600,30.,70.,81),(midnight-6*86400+60,15.,30.,90),(midnight-7*86400+60,99.,99.,99)]
history=ref.History(clock=lambda:now,utc_offset=28800,keep_days=30)
mac='A4:C1:38:00:00:01'
history.add([(mac,*r) for r in rows])
for name,days in [('day',1),('week',7),('month',30)]:
    got=run(f'H {now} {days} {len(rows)}\n'+''.join(' '.join(map(str,r))+'\n' for r in rows))[0]
    assert got==history.query(mac,name)['points'], (name,got)
summary={'reference_decode_tests':result.testsRun,'reference_packet_calls':reference_count,
         'cpp_packet_comparisons':len(cases),'merge':'pass','voltage_estimation':'pass','history_ranges':'day/week/month pass'}
temporary.cleanup()
print(json.dumps(summary,indent=2))
