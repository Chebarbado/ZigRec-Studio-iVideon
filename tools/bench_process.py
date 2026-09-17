# -*- coding: utf-8 -*-
"""Замер чужой программы записи (#30): загрузка процессора и память по имени процесса.

Только stdlib: раз в секунду спрашивает у PowerShell `Get-Process` время
процессора и рабочий набор, считает среднюю загрузку в процентах одного
ядра и всей машины, пик памяти. Так меряются OBS и CamStudio, у которых
нет своего отчёта; наш `zigrec bench-run` меряет себя сам тем же способом
(GetProcessTimes), поэтому числа сравнимы.

    python tools/bench_process.py obs64 20
    python tools/bench_process.py Recorder 20
"""
import os
import subprocess
import sys
import time


def sample(name):
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "$p = Get-Process -Name '%s' -ErrorAction SilentlyContinue | Select-Object -First 1; "
         "if ($p) { '{0} {1}' -f $p.TotalProcessorTime.TotalSeconds, $p.WorkingSet64 }" % name],
        capture_output=True, text=True)
    line = out.stdout.strip()
    if not line:
        return None
    cpu, ws = line.split()
    return float(cpu.replace(",", ".")), int(ws)


def main(argv):
    if len(argv) < 3:
        print("[bench-py] нужны: имя процесса (без .exe) и секунды")
        return 2
    name = argv[1]
    seconds = int(argv[2])
    cores = os.cpu_count() or 1
    first = sample(name)
    if first is None:
        print("[bench-py] процесс «%s» не найден — запустите программу и начните запись" % name)
        return 1
    peak_ws = first[1]
    t0 = time.time()
    time.sleep(seconds)
    last = sample(name)
    if last is None:
        print("[bench-py] процесс «%s» пропал во время замера" % name)
        return 1
    wall = time.time() - t0
    cpu_s = last[0] - first[0]
    peak_ws = max(peak_ws, last[1])
    one_core = cpu_s / wall * 100.0
    print("[bench-py] %s: %.1f с процессора за %.1f с стены — %.1f%% одного ядра, %.1f%% машины (%d ядер); память до %.0f МБ" % (
        name, cpu_s, wall, one_core, one_core / cores, cores, peak_ws / 1048576.0))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
