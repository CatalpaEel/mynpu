"""Inventory report scope and compare recorded source hashes; never rewrite evidence."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
REPORTS = ROOT / 'npu/reports'
CURRENT = {
    'rf1r1w-validation.json': 'Current RF functionality, MNIST and synthesis; PNR limitations inside are the original pre-PNR snapshot.',
    'rf1r1w_die1950_fullchip_validation.json': 'Final RF1R1W die1950 r3 PNR; not firstpass/r2.',
    'lab5_rf1r1w_die1950_validation.json': 'Final r3 course checks; ERC and strict PR limitations remain.',
    'ego1_preboard_validation.json': 'Current board functional preparation only; no Vivado implementation or board test.',
    'backend_source_audit.json': 'Source identity audit only; no new PPA measurement.',
}
CACHE = {}

def digest(p):
    p = p.resolve()
    if p not in CACHE:
        h = hashlib.sha256()
        with p.open('rb') as f:
            for chunk in iter(lambda: f.read(1024*1024), b''):
                h.update(chunk)
        CACHE[p] = h.hexdigest()
    return CACHE[p]


def resolve_source(name):
    """Only project/dependency sources, not generated netlists or measured outputs."""
    if Path(name).suffix not in {'.sv', '.svh', '.v', '.py', '.h', '.c'}:
        return None
    name = name.replace('\\', '/')
    if name.startswith(str(ROOT) + '/'):
        path = Path(name)
    elif '/external/' in name:
        path = ROOT / 'external' / name.split('/external/', 1)[1]
    elif '/npu/' in name and not '/eda-runs/' in name:
        path = ROOT / 'npu' / name.split('/npu/', 1)[1]
    elif name.startswith(('npu/', 'external/')):
        path = ROOT / name
    elif name.startswith(('rtl/', 'sw/', 'tb/', 'tests/', 'workloads/', 'scripts/', 'mnist/')):
        path = ROOT / 'npu' / name
    else:
        return None
    if '/build/' in str(path) or '/reports/' in str(path):
        return None
    if not path.exists() and path.parent == ROOT / 'npu/rtl':
        matches = list((ROOT / 'npu/rtl').rglob(path.name))
        if len(matches) == 1:
            path = matches[0]
    return path


def source_checks(obj):
    found = {}
    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value):
                    p = resolve_source(key)
                    if p is not None:
                        actual = digest(p) if p.is_file() else None
                        found[(str(p.relative_to(ROOT)), value)] = {
                            'source': str(p.relative_to(ROOT)), 'recorded_sha256': value,
                            'current_sha256': actual,
                            'status': 'missing' if actual is None else 'match' if actual == value else 'different'}
                elif isinstance(value, (dict, list)):
                    walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    walk(obj)
    return list(found.values())


def file_checks(mapping, base):
    result = []
    for name, want in mapping.items():
        if not isinstance(want, str) or not re.fullmatch('[0-9a-f]{64}', want):
            continue
        p = Path(name)
        if not p.is_absolute():
            p = base / p
        got = digest(p) if p.is_file() else None
        result.append({'file': str(p), 'status': 'missing' if got is None else 'match' if want == got else 'different'})
    return result

paths = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '--', 'npu/reports'],
    cwd=ROOT, text=True).splitlines()
entries = []
for name in sorted(set(paths)):
    p = ROOT / name
    if p.name in {'README.md', 'report_inventory.json'} or not p.is_file():
        continue
    entry = {'file': p.name, 'sha256': digest(p), 'classification':
             'current-scoped' if p.name in CURRENT else 'historical-snapshot',
             'note': CURRENT.get(p.name, 'Earlier experiment/baseline; not a current whole-design result.')}
    if p.suffix == '.json':
        try:
            obj = json.loads(p.read_text())
        except Exception as exc:
            entry.update(classification='invalid-json', error=str(exc))
        else:
            checks = source_checks(obj)
            entry['source_hash_observations'] = checks
            entry['source_hash_counts'] = dict(Counter(c['status'] for c in checks))
            if p.name in {'rf1r1w_die1950_fullchip_validation.json', 'lab5_rf1r1w_die1950_validation.json'}:
                base = Path(obj['run'])
                entry['frozen_files'] = file_checks(obj.get('report_sha256', {}), base)
                entry['frozen_files'] += file_checks(obj.get('artifacts_sha256', {}), base)
                entry['frozen_files'] += file_checks(obj.get('final_input_sha256', {}), base)
                for key in ['drc', 'lvs_strict', 'lvs_lab5_tolerance', 'erc', 'antenna', 'wire_bond']:
                    part = obj.get(key, {})
                    if isinstance(part, dict) and 'report' in part and 'sha256' in part:
                        entry['frozen_files'] += file_checks({part['report']: part['sha256']}, base)
                entry['frozen_file_counts'] = dict(Counter(c['status'] for c in entry['frozen_files']))
                if p.name.startswith('rf1r1w_die'):
                    manifest = json.loads((base/'manifest.json').read_text())
                    source = manifest['core_source_manifest']
                    entry['frozen_design_source_checks'] = file_checks(source['source_sha256'], ROOT)
                    entry['frozen_design_source_counts'] = dict(Counter(c['status'] for c in entry['frozen_design_source_checks']))
                    entry['configuration_matches'] = all(source[k] == v for k, v in json.loads((ROOT/'npu/build_config.json').read_text()).items())
            if p.name == 'ego1_preboard_validation.json':
                entry['preboard_manifest_check'] = file_checks({obj['source_manifest']:obj['source_manifest_sha256']}, ROOT)
                snapshot = json.loads((ROOT/obj['source_manifest']).read_text())
                mapping = {k.removeprefix('src/'): v for k, v in snapshot['sha256'].items() if k.startswith('src/')}
                entry['board_source_checks'] = file_checks(mapping, ROOT)
    else:
        text = p.read_text(errors='replace')[:2500]
        entry['report_header'] = text.splitlines()[:12]
        entry['note'] = 'Legacy Vivado 2025.2 OOC report from 2026-10-04; not current FPGA or ASIC implementation.'
    entries.append(entry)

inventory = {'checked_date': '2026-11-11', 'git_commit': subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
             'scope': 'Inventory and hash audit, no new simulation or PPA. Source observations can include historical baselines and partial maps; matches do not certify full design identity.',
             'counts': dict(Counter(e['classification'] for e in entries)), 'reports': entries}
(REPORTS/'report_inventory.json').write_text(json.dumps(inventory,indent=2)+'\n')
lines = ['# 报告索引与版本审计', '', '2026-11-11。报告是冻结证据，文件名不带日期也不表示当前版本；不修改原报告里的历史数值或当时结论。', '',
'## 当前采用的入口', '', '| 报告 | 适用范围 |', '| --- | --- |']
labels = {
 'rf1r1w-validation.json':'RF功能、21,008周期MNIST及综合2.569286mm²；内部“未跑PNR”是当时快照，后续见r3。',
 'rf1r1w_die1950_fullchip_validation.json':'最终r3布局布线；核心非filler 2.632349mm²、50MHz +0.468/+0.018ns。',
 'lab5_rf1r1w_die1950_validation.json':'最终r3课程检查；严格PR/ERC残项保留，非正式投片全部通过。',
 'ego1_preboard_validation.json':'EGo1功能仿真38项；尚无本版Vivado综合/实现/实体板结果。',
 'backend_source_audit.json':'70个ASIC输入、24个项目RTL与默认配置核对。'}
for name, label in labels.items():
    lines.append(f'| [{name}]({name}) | {label} |')
lines += ['', '## 版本判读', '',
'目录只保留当前版本报告；旧功能引入报告与旧Vivado测量已从工作树移除，历史可从Git查找。',
'原始当前报告中的对照字段与阶段追踪作为证据保留；首页指标只使用当前最终结果。',
'审计详细记录每份JSON的已记录源哈希比对，以及最终PNR/Lab5产物完整性。部分哈希一致不等于整份报告对应当前设计；缺少证据时不推断通过。',
'输入版本一致也不等于检查全部通过：最终Lab5仍保留ERC及严格PR限制。', '',
'完整机器清单：[report_inventory.json](report_inventory.json)。重新审计：`python3.12 npu/scripts/audit_reports.py`。', '',
'## 全量清单', '', '| 文件 | 定位 | 源哈希观察：一致/不同/缺失 |', '| --- | --- | --- |']
for e in entries:
    c=e.get('source_hash_counts',{})
    label='当前范围' if e['classification']=='current-scoped' else '历史快照' if e['classification']=='historical-snapshot' else '解析失败'
    observation='/'.join(str(c.get(k,0)) for k in ['match','different','missing']) if c else '无可直接比对的源哈希'
    lines.append(f"| [{e['file']}]({e['file']}) | {label} | {observation} |")
(REPORTS/'README.md').write_text('\n'.join(lines)+'\n')
print(json.dumps(inventory['counts']))
for e in entries:
    if e['classification']=='current-scoped':
        print(e['file'],e.get('frozen_design_source_counts',{}),e.get('frozen_file_counts',{}))
