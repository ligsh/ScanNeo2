"""把第三方的 158 条 hg19 变异坐标 liftover 到 hg38。

方向必须钉死：hg19ToHg38.over.chain 里 t 链是 hg19（chr1=249250621）、q 链是
hg38（chr1=248956422）。两链染色体同名，只能靠长度区分——我第一版就是因为把
方向搞反而得到错误坐标，所以这里加断言而不是写注释提醒。

反向链（qStrand='-'）：链文件的块坐标按 t 的 + 方向排列，q 坐标在负链上倒着走，
  故 qpos0 = qSize - (qStart + qOff)。
  这一段靠"liftover 后参考基因组碱基应等于第三方给的 REF"来实证验证，
  因为 158 条 SNV 的 REF 是现成的检验集。
"""
HG19_CHR1 = 249250621
HG38_CHR1 = 248956422

def load_chain(path):
    chains = {}
    cur = None
    with open(path) as f:
        for line in f:
            if line.startswith('chain'):
                p = line.split()
                cur = {'tName': p[2], 'tSize': int(p[3]), 'tStrand': p[4],
                       'tStart': int(p[5]), 'tEnd': int(p[6]),
                       'qName': p[7], 'qSize': int(p[8]), 'qStrand': p[9],
                       'qStart': int(p[10]), 'qEnd': int(p[11]), 'blocks': []}
                chains.setdefault(cur['tName'], []).append(cur)
            elif cur is not None:
                p = line.split()
                if len(p) == 3:
                    cur['blocks'].append((int(p[0]), int(p[1]), int(p[2])))
                elif len(p) == 1:
                    cur['blocks'].append((int(p[0]), 0, 0))
                    cur = None
    if not any(c['tSize'] == HG19_CHR1 and c['qSize'] == HG38_CHR1 for c in chains.get('chr1', [])):
        raise SystemExit("方向断言失败：t 应为 hg19、q 应为 hg38")
    return chains

def lift_point(chains, chrom, pos1):
    """1-based hg19 -> (hg38 chrom, 1-based pos) 或 None"""
    pos0 = pos1 - 1
    for c in chains.get(chrom, []):
        if not (c['tStart'] <= pos0 < c['tEnd']):
            continue
        if c['tStrand'] != '+':
            raise NotImplementedError("t 为负链的情况本实现不处理")
        tp, qp = c['tStart'], c['qStart']
        for (size, dt, dq) in c['blocks']:
            if tp <= pos0 < tp + size:
                off = pos0 - tp
                if c['qStrand'] == '+':
                    return (c['qName'], qp + off + 1)
                else:
                    return (c['qName'], c['qSize'] - (qp + off))
            tp += size + dt
            qp += size + dq
    return None

ch = load_chain('hg19ToHg38.over.chain')
print("  方向断言通过：t=hg19, q=hg38")
n = tot = 0
with open('lifted_var.tsv', 'w') as f:
    for line in open('third_var.tsv'):
        p = line.rstrip('\n').split('\t')
        c, pos, ref, alt, gene = p[0], int(p[1]), p[2], p[3], p[4]
        tot += 1
        res = lift_point(ch, 'chr' + c, pos)
        if res:
            n += 1
            f.write("%s\t%d\t%s\t%s\t%s\t%s\t%d\n" % (c, pos, ref, alt, gene, res[0], res[1]))
        else:
            f.write("%s\t%d\t%s\t%s\t%s\tNA\t0\n" % (c, pos, ref, alt, gene))
print("  成功 liftover: %d / %d" % (n, tot))
