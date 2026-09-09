#!/usr/bin/env python3
"""Minimal Java class-file disassembler (no JVM needed): constant pool, fields, methods, bytecode.
   python3 tools/javadis.py ../gx/CleoCanvas.class [method-name-substring]"""
import struct, sys

OPS = {0:'nop',1:'aconst_null',2:'iconst_m1',3:'iconst_0',4:'iconst_1',5:'iconst_2',6:'iconst_3',7:'iconst_4',8:'iconst_5',
 9:'lconst_0',10:'lconst_1',11:'fconst_0',12:'fconst_1',13:'fconst_2',14:'dconst_0',15:'dconst_1',16:'bipush',17:'sipush',18:'ldc',19:'ldc_w',20:'ldc2_w',
 21:'iload',22:'lload',23:'fload',24:'dload',25:'aload',26:'iload_0',27:'iload_1',28:'iload_2',29:'iload_3',30:'lload_0',31:'lload_1',32:'lload_2',33:'lload_3',
 34:'fload_0',35:'fload_1',36:'fload_2',37:'fload_3',38:'dload_0',39:'dload_1',40:'dload_2',41:'dload_3',42:'aload_0',43:'aload_1',44:'aload_2',45:'aload_3',
 46:'iaload',47:'laload',48:'faload',49:'daload',50:'aaload',51:'baload',52:'caload',53:'saload',54:'istore',55:'lstore',56:'fstore',57:'dstore',58:'astore',
 59:'istore_0',60:'istore_1',61:'istore_2',62:'istore_3',63:'lstore_0',64:'lstore_1',65:'lstore_2',66:'lstore_3',67:'fstore_0',68:'fstore_1',69:'fstore_2',70:'fstore_3',
 71:'dstore_0',72:'dstore_1',73:'dstore_2',74:'dstore_3',75:'astore_0',76:'astore_1',77:'astore_2',78:'astore_3',79:'iastore',80:'lastore',81:'fastore',82:'dastore',
 83:'aastore',84:'bastore',85:'castore',86:'sastore',87:'pop',88:'pop2',89:'dup',90:'dup_x1',91:'dup_x2',92:'dup2',93:'dup2_x1',94:'dup2_x2',95:'swap',
 96:'iadd',97:'ladd',98:'fadd',99:'dadd',100:'isub',101:'lsub',102:'fsub',103:'dsub',104:'imul',105:'lmul',106:'fmul',107:'dmul',108:'idiv',109:'ldiv',110:'fdiv',111:'ddiv',
 112:'irem',113:'lrem',114:'frem',115:'drem',116:'ineg',117:'lneg',118:'fneg',119:'dneg',120:'ishl',121:'lshl',122:'ishr',123:'lshr',124:'iushr',125:'lushr',
 126:'iand',127:'land',128:'ior',129:'lor',130:'ixor',131:'lxor',132:'iinc',133:'i2l',134:'i2f',135:'i2d',136:'l2i',137:'l2f',138:'l2d',139:'f2i',140:'f2l',141:'f2d',
 142:'d2i',143:'d2l',144:'d2f',145:'i2b',146:'i2c',147:'i2s',148:'lcmp',149:'fcmpl',150:'fcmpg',151:'dcmpl',152:'dcmpg',153:'ifeq',154:'ifne',155:'iflt',156:'ifge',
 157:'ifgt',158:'ifle',159:'if_icmpeq',160:'if_icmpne',161:'if_icmplt',162:'if_icmpge',163:'if_icmpgt',164:'if_icmple',165:'if_acmpeq',166:'if_acmpne',167:'goto',
 168:'jsr',169:'ret',170:'tableswitch',171:'lookupswitch',172:'ireturn',173:'lreturn',174:'freturn',175:'dreturn',176:'areturn',177:'return',178:'getstatic',
 179:'putstatic',180:'getfield',181:'putfield',182:'invokevirtual',183:'invokespecial',184:'invokestatic',185:'invokeinterface',187:'new',188:'newarray',
 189:'anewarray',190:'arraylength',191:'athrow',192:'checkcast',193:'instanceof',194:'monitorenter',195:'monitorexit',196:'wide',197:'multianewarray',
 198:'ifnull',199:'ifnonnull',200:'goto_w',201:'jsr_w'}
# operand byte counts (excluding switch/wide)
N1 = {16,18,21,22,23,24,25,54,55,56,57,58,169,188}
N2 = {17,19,20,132,153,154,155,156,157,158,159,160,161,162,163,164,165,166,167,168,178,179,180,181,182,183,187,189,192,193,198,199}
N4 = {185,197,200,201}
ATYPES = {4:'boolean',5:'char',6:'float',7:'double',8:'byte',9:'short',10:'int',11:'long'}

def main():
    d = open(sys.argv[1], 'rb').read()
    want = sys.argv[2] if len(sys.argv) > 2 else None
    p = 8
    n = struct.unpack('>H', d[p:p+2])[0]; p += 2
    cp = [None] * n
    i = 1
    while i < n:
        t = d[p]
        if t == 1:
            l = struct.unpack('>H', d[p+1:p+3])[0]; cp[i] = ('utf8', d[p+3:p+3+l].decode('utf8', 'replace')); p += 3 + l
        elif t in (7, 8, 16, 19, 20):
            cp[i] = (t, struct.unpack('>H', d[p+1:p+3])[0]); p += 3
        elif t in (9, 10, 11, 12, 17, 18):
            cp[i] = (t, struct.unpack('>HH', d[p+1:p+5])); p += 5
        elif t == 3:
            cp[i] = ('int', struct.unpack('>i', d[p+1:p+5])[0]); p += 5
        elif t == 4:
            cp[i] = ('float', struct.unpack('>f', d[p+1:p+5])[0]); p += 5
        elif t in (5, 6):
            cp[i] = ('long', struct.unpack('>q' if t == 5 else '>d', d[p+1:p+9])[0]); p += 9; i += 1
        elif t == 15:
            cp[i] = (t, d[p+1:p+4]); p += 4
        else:
            raise SystemExit('bad cp tag %d' % t)
        i += 1
    def s(ix):
        if ix >= len(cp): return '#%d?' % ix
        e = cp[ix]
        if e is None: return '?'
        if e[0] == 'utf8': return e[1]
        if e[0] in ('int', 'float', 'long'): return str(e[1])
        if e[0] in (7, 8): return s(e[1])
        if e[0] == 12: return s(e[1][0]) + ':' + s(e[1][1])
        if e[0] in (9, 10, 11): return s(e[1][0]) + '.' + s(e[1][1])
        return repr(e)
    p += 6  # access, this, super
    nif = struct.unpack('>H', d[p:p+2])[0]; p += 2 + 2 * nif
    def attrs(p, dump=False, name=''):
        na = struct.unpack('>H', d[p:p+2])[0]; p += 2
        for _ in range(na):
            an, al = struct.unpack('>HI', d[p:p+6]); p += 6
            if s(an) == 'Code' and dump:
                clen = struct.unpack('>I', d[p+4:p+8])[0]
                code = d[p+8:p+8+clen]
                disasm(code, name)
            p += al
        return p
    def disasm(code, name):
        q = 0
        while q < len(code):
            op = code[q]; nm = OPS.get(op, 'op%d' % op); arg = ''
            if op == 170:   # tableswitch
                a = (q + 4) & ~3; dflt, lo, hi = struct.unpack('>iii', code[a:a+12]); cnt = hi - lo + 1
                arg = 'default->%d lo=%d hi=%d' % (q + dflt, lo, hi); q = a + 12 + 4 * cnt; print('   %4d %s %s' % (q, nm, arg)); continue
            if op == 171:
                a = (q + 4) & ~3; dflt, np_ = struct.unpack('>ii', code[a:a+8]); arg = 'default->%d n=%d' % (q + dflt, np_); q = a + 8 + 8 * np_; print('   %4d %s %s' % (q, nm, arg)); continue
            if op in N1:
                v = code[q+1]
                arg = str(struct.unpack('>b', code[q+1:q+2])[0]) if op == 16 else (s(v) if op == 18 else (ATYPES.get(v, str(v)) if op == 188 else str(v)))
                sz = 2
            elif op in N2:
                v = struct.unpack('>H', code[q+1:q+3])[0]
                if op == 17: arg = str(struct.unpack('>h', code[q+1:q+3])[0])
                elif op == 132: arg = '%d %d' % (code[q+1], struct.unpack('>b', code[q+2:q+3])[0])
                elif 153 <= op <= 168: arg = '->%d' % (q + struct.unpack('>h', code[q+1:q+3])[0])
                elif op in (178, 179, 180, 181, 182, 183, 184, 187, 189, 192, 193, 19, 20): arg = s(v)
                else: arg = str(v)
                sz = 3
            elif op == 184:
                arg = s(struct.unpack('>H', code[q+1:q+3])[0]); sz = 3
            elif op in (200, 201):
                arg = '->%d' % (q + struct.unpack('>i', code[q+1:q+5])[0]); sz = 5
            elif op in N4:
                arg = s(struct.unpack('>H', code[q+1:q+3])[0]); sz = 5
            elif op == 196:
                sz = 6 if code[q+1] == 132 else 4
            else:
                sz = 1
            print('   %4d %s %s' % (q, nm, arg)); q += sz
    nf = struct.unpack('>H', d[p:p+2])[0]; p += 2
    print('fields:')
    for _ in range(nf):
        acc, ni, di = struct.unpack('>HHH', d[p:p+6]); p += 6
        print('  ', s(ni), s(di)); p = attrs(p)
    nm = struct.unpack('>H', d[p:p+2])[0]; p += 2
    for _ in range(nm):
        acc, ni, di = struct.unpack('>HHH', d[p:p+6]); p += 6
        name = s(ni) + s(di)
        dump = want is None or want in name
        if dump: print('method', name)
        p = attrs(p, dump, name)

main()
