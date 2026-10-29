"""Rebuild the explanatory SVG figures. These are diagrams, not EDA screenshots."""
from pathlib import Path
from html import escape

OUT = Path(__file__).resolve().parent
BLUE, TEAL, ORANGE = '#235ba8', '#087e8b', '#c57523'

class SVG:
    def __init__(self, w, h):
        self.p = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}"><defs><marker id="a" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto-start-reverse"><path d="M0,0 L8,4 L0,8" fill="#65758b"/></marker></defs><rect width="100%" height="100%" fill="white"/><g font-family="Noto Sans CJK SC, sans-serif">']
    def text(self,x,y,t,size=18,color='#243248',anchor='middle'):
        self.p.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" text-anchor="{anchor}">{escape(t)}</text>')
    def box(self,x,y,w,h,title,sub='',color=BLUE):
        self.p.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{color}" fill-opacity=".07" stroke="{color}" stroke-width="2"/>')
        self.text(x+w/2,y+h/2-(6 if sub else -6),title,20,color)
        if sub:self.text(x+w/2,y+h/2+24,sub,15)
    def line(self,x,y,xx,yy,both=False):
        self.p.append(f'<path d="M{x},{y} L{xx},{yy}" stroke="#65758b" stroke-width="2" fill="none" marker-end="url(#a)" '+('marker-start="url(#a)"' if both else '')+'/>')
    def save(self,name):
        (OUT/name).write_text(''.join(self.p)+ '</g></svg>')

s=SVG(1100,370)
s.box(30,55,230,100,'RISC-V CPU','SRAM 中的软件循环 / 32bit 发令')
s.box(430,30,270,100,'4 × 4 PE torus','4 × RF32 / PE；算术与量化',TEAL)
s.box(430,210,270,100,'流输入输出','shape / stride / 预取 / 打包',BLUE)
s.box(850,125,220,130,'共享 SRAM','2 × 8KB 单端口宏',ORANGE)
s.line(260,95,425,80);s.text(340,61,'32bit MMIO',16)
s.line(260,125,425,245);s.text(315,208,'配置 / 发令',15)
s.line(520,135,520,205,True);s.text(615,175,'本地寄存器数据',15)
s.line(705,265,845,210,True);s.text(792,280,'仲裁与缓存',15)
s.p.append('<path d="M145,55 V10 H960 V120" stroke="#65758b" stroke-width="2" fill="none" marker-start="url(#a)" marker-end="url(#a)"/>')
s.text(805,75,'CPU 取指 / 数据访问',15)
s.text(550,350,'软件决定循环、依赖与算子组合；硬件保留握手、仲裁和地址发生控制。',18)
s.save('architecture.svg')

s=SVG(1100,420)
for r in range(4):
    for c in range(4):
        x,y=65+c*105,55+r*80
        if c<3:s.line(x+70,y+25,x+100,y+25,True)
        if r<3:s.line(x+35,y+50,x+35,y+75,True)
        s.box(x,y,70,50,f'{r},{c}',color=TEAL)
for r in range(4):
    y=80+r*80
    s.p.append(f'<path d="M65,{y} H{35-r*6} V{y-36} H{470+r*6} V{y} H450" fill="none" stroke="#bd7a34" stroke-dasharray="4 3"/>')
for c in range(4):
    x=100+c*105
    s.p.append(f'<path d="M{x},55 V{20-c*4} H{x+43} V380 H{x} V345" fill="none" stroke="#9aa8b9" stroke-dasharray="4 3"/>')
s.text(270,408,'边界回绕：N / S / W / E 邻居',17)
s.box(580,40,460,75,'每 PE：R0 / R1 / R2 / R3','每个寄存器 32bit；算术仅写本 PE',TEAL)
s.box(560,165,225,70,'操作数 A','方向 3bit + 寄存器 2bit')
s.box(815,165,225,70,'操作数 B','独立选择方向与寄存器')
s.line(670,240,760,280);s.line(925,240,855,280)
s.box(690,285,240,65,'多精度 ALU / MUL',color=TEAL)
s.text(805,380,'LOCAL / N / S / W / E；目的寄存器可指定',17)
s.save('torus-registers.svg')

s=SVG(1100,390)
s.text(200,30,'输入 2 × 14 × 14',21,BLUE)
s.text(200,70,'3 × 3 卷积，stride = 1，padding = 1',16)
s.text(200,110,'每个输出：2 × 3 × 3 = 18 项 MAC',17)
s.box(45,165,300,100,'激活 → R2','每行一个空间位置，沿列广播',BLUE)
s.line(350,215,435,215)
s.text(687,27,'列 = 4 个输出通道',20,TEAL)
for r in range(4):
    for c in range(4):
        s.box(445+c*130,55+r*65,120,55,f'p{r} / c{c}',color=TEAL)
s.text(690,340,'行 = 同一输出行中相邻的 4 个位置',18)
s.text(200,320,'权重 → R3：每列一个输出通道',16)
s.text(200,351,'沿行广播；R0 累加，R1 存倍率',16)
s.text(550,383,'全层输出 4 × 14 × 14 = 784B；56 个 tile，行尾 mask 屏蔽无效位置。',18)
s.save('layer-mapping.svg')

s=SVG(1100,370)
labels=['启动','准备','稳态命令 k','排空','后处理 / 写回']
for i,l in enumerate(labels):s.text(110+i*220,30,l,18,BLUE)
for x,t,sub,c in [(10,'NEXT(0)','首项 → R2 / R3',BLUE),(230,'PREFETCH(1)','下一项 → 输入缓冲',BLUE),(450,'MAC(k)','旧 R2 × R3 → R0',TEAL),(670,'最后一次 MAC','关闭末尾 advance',TEAL),(890,'MULHR / MAX / MIN','量化与裁剪在 PE',ORANGE)]:
    s.box(x,65,200,80,t,sub,c)
s.box(450,170,200,65,'COMMIT(k+1)','',BLUE)
s.box(450,260,200,65,'PREFETCH(k+2)','',BLUE)
s.line(210,105,225,105);s.line(430,105,445,105);s.line(650,105,665,105);s.line(870,105,885,105)
s.text(790,207,'同一条 32bit 命令',20,TEAL)
s.text(790,242,'计算旧值，同时换入新值并启动搬运',15)
s.text(790,282,'数据未就绪则 ready 反压',16)
s.text(790,313,'不是每项都只需一个 CPU 周期',15)
s.text(550,358,'最终 NEXT(store) 将 PE 结果打包写回 SRAM；流单元不承担量化计算。',18)
s.save('software-pipeline.svg')

s=SVG(1100,280)
data=[('64 words / 快速映射',4.479290,BLUE),('32 words / 快速映射',4.288349,BLUE),('32 words / 完整优化',3.320404,TEAL)]
for i,(label,value,color) in enumerate(data):
    y=40+i*75;s.text(290,y+25,label,18,anchor='end')
    s.p.append(f'<rect x="315" y="{y}" width="{value*140}" height="40" rx="5" fill="{color}"/>')
    s.text(330+value*140,y+27,f'{value:.3f} mm²',19,anchor='start')
s.text(550,270,'Cell Area 含两块 SRAM；总降幅 25.9%，包含 RTL 与综合策略的共同收益。',17)
s.save('area-iterations.svg')
