
"""最小 liftover：hg19 的单个碱基 → hg38。

chain 文件里的方向容易搞反，本文件用长度断言把方向钉死：
  hg19ToHg38.over.chain 中 t 链是 hg19（chr1=249250621），q 链是 hg38（chr1=248956422）。
  两边染色体同名，只能靠长度区分。因此：用 t 坐标查找，输出 q 坐标。

chain 格式（UCSC）：
  头行  chain score tName tSize tStrand tStart tEnd qName qSize qStrand qStart qEnd id
  块行  size dt dq
  末行  仅 size
只处理双链均为 + 的情形（主染色体即是），遇 - 链显式报错而非静默给错坐标。
"""
HG19_CHR1 = 249250621
HG38_CHR1 = 248956422

def load_chain(path):
    chains = {}
    with open(path) as f:
        cur = None
        for line in f:
            if line.startswith('chain'):
                p = line.split()
                cur = dict(tName=p[2], tSize=int(p[3]), tStrand=p[4], tStart=int(p[5]), tEnd=int(p[6]),
                           qName=p[7], qSize=int(p[8]), qStrand=p[9], qStart=int(p[10]), qEnd=int(p[11]),
                           blocks=[])
                chains.setdefault(cur['tName'], []).append(cur)
            elif cur is not None:
                p = line.split()
                if len(p) == 3:
                    cur['blocks'].append((int(p[0]), int(p[1]), int(p[2])))
                elif len(p) == 1:
                    cur['blocks'].append((int(p[0]), 0, 0))
                    cur = None
    for c in chains.get('chr1', []):
        if c['tSize'] == HG19_CHR1 and c['qSize'] == HG38_CHR1 and c['tStart'] < 20000:
            break
    else:
        raise SystemExit("方向断言失败：hg19ToHg38 的 t 应为 hg19(chr1=249250621)、q 为 hg38(chr1=248956422)")
    return chains

def lift_point(chains, chrom, pos1):
    """pos1 为 1-based hg19 坐标；返回 (hg38 chrom, 1-based pos) 或 None"""
    pos0 = pos1 - 1
    for c in chains.get(chrom, []):
        if not (c['tStart'] <= pos0 < c['tEnd']):
            continue
        if c['tStrand'] != '+' or c['qStrand'] != '+':
            raise NotImplementedError("本实现不支持 - 链")
        tp, qp = c['tStart'], c['qStart']
        for (size, dt, dq) in c['blocks']:
            if tp <= pos0 < tp + size:
                return (c['qName'], qp + (pos0 - tp) + 1)
            tp += size + dt
            qp += size + dq
    return None

if __name__ == '__main__':
    ch = load_chain('hg19ToHg38.over.chain')
    print("  载入 chain: %d 个源染色体" % len(ch))
    tests = [(1,11983391,'C'),(1,16060296,'A'),(1,34191098,'G'),
             (1,65348960,'G'),(1,112318873,'G'),(1,156100465,'G')]
    with open('lifted.txt','w') as f:
        for c,p,r in tests:
            res = lift_point(ch, 'chr%d'%c, p)
            print("  %-16s -> %-18s 他们REF=%s" % ("chr%d:%d"%(c,p), ("%s:%d"%res if res else "未映射"), r))
            if res: f.write("chr%d	%d	%s	%d	%s
" % (c,p,res[0],res[1],r))
    print("  已写出 lifted.txt")

